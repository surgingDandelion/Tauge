import AppKit
import SwiftUI
import SwiftTerm
import TaugeKit

/// Owns a tab's emulator independently of its SwiftUI host. Replaying raw
/// output on reattach isn't equivalent to restoring a terminal: the original
/// stream can depend on earlier grid sizes, modes and cursor positions.
@MainActor
final class TerminalBridge: TerminalViewDelegate {
    private var terminal: TaugeTerminalView?
    private var appliedSettings: AppSettings?
    var onResize: ((Int, Int) -> Void)?
    var onDirectoryChange: ((String) -> Void)?
    var onBackgroundReply: ((Data) -> Void)?

    /// Focus and search only target a mounted view, not an offscreen emulator.
    var view: TaugeTerminalView? {
        guard let terminal, terminal.superview is TerminalViewHost else { return nil }
        return terminal
    }

    /// Also called before opening an SSH channel, so tabs that connect in the
    /// background can parse output immediately even before their first mount.
    @discardableResult
    func prepare(settings: AppSettings, columns: Int, rows: Int) -> TaugeTerminalView {
        if let terminal, appliedSettings == settings { return terminal }

        let font = NSFont(name: settings.terminalFontFamily, size: settings.terminalFontSize)
            ?? NSFont.monospacedSystemFont(ofSize: settings.terminalFontSize, weight: .regular)
        let view: TaugeTerminalView
        if let terminal {
            view = terminal
            if view.font != font { view.font = font }
            if appliedSettings?.scrollbackLines != settings.scrollbackLines {
                view.changeScrollback(settings.scrollbackLines)
            }
        } else {
            var options = TerminalOptions(cols: columns, rows: rows, termName: "xterm-256color",
                                          scrollback: settings.scrollbackLines)
            options.enableOsc8Hyperlinks = true
            options.kittyClipboardPolicy = []
            // SwiftTerm uses the options' grid only for a zero-sized frame.
            view = TaugeTerminalView(frame: .zero, font: font, options: options)
            terminal = view
            view.terminalDelegate = self
            view.registerForDraggedTypes([.fileURL])
        }
        view.optionAsMetaKey = settings.optionAsMeta
        view.copyOnSelect = settings.copyOnSelect
        view.confirmMultilinePaste = settings.confirmMultilinePaste
        if appliedSettings?.terminalThemeName != settings.terminalThemeName {
            let theme = TerminalThemeCatalog.theme(named: settings.terminalThemeName)
            view.nativeForegroundColor = theme.foreground
            view.nativeBackgroundColor = theme.background
            view.caretColor = theme.caret
            view.installColors(theme.ansi)
        }
        let opacity = CGFloat(max(0.5, min(1.0, settings.terminalBackgroundOpacity)))
        if view.backgroundOpacity != opacity { view.backgroundOpacity = opacity }
        let spacing = CGFloat(max(0.9, min(1.6, settings.terminalLineHeight)))
        if view.lineSpacing != spacing { view.lineSpacing = spacing }
        appliedSettings = settings
        return view
    }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        terminal?.feed(byteArray: ArraySlice(data))
    }

    func close() {
        terminal?.terminalDelegate = nil
        terminal?.removeFromSuperview()
        terminal?.updateUiClosed()
        terminal = nil
        appliedSettings = nil
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        onResize?(newCols, newRows)
    }

    // The tab label stays the host's name, regardless of the remote shell title.
    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        let path: String
        if directory.hasPrefix("/") {
            path = directory
        } else {
            guard let uri = URLComponents(string: directory), uri.scheme?.lowercased() == "file",
                  uri.user == nil, uri.password == nil, uri.port == nil,
                  uri.query == nil, uri.fragment == nil,
                  let decoded = uri.percentEncodedPath.removingPercentEncoding else { return }
            path = decoded
        }
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return }
        onDirectoryChange?(path)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        if let send = (source.superview as? TerminalViewHost)?.onSend, source.window != nil {
            send(bytes)
        } else {
            // A background shell may still ask the emulator for cursor/mode
            // information. Reply to its own channel without broadcasting.
            onBackgroundReply?(bytes)
        }
    }

    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        guard source.window != nil else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(content, forType: .string)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        guard source.window != nil else { return nil }
        return NSPasteboard.general.string(forType: .string).map { Data($0.utf8) }
    }

    func bell(source: TerminalView) {
        if source.window != nil { NSSound.beep() }
    }
}

/// TerminalView subclass that adds copy-on-select, a multiline-paste guard and
/// Finder drag-and-drop upload support.
final class TaugeTerminalView: TerminalView {
    var copyOnSelect = true
    var confirmMultilinePaste = true
    private var lastCopiedSelection: String?
    private var host: TerminalViewHost? { superview as? TerminalViewHost }

    // SwiftTerm declares becomeFirstResponder as public (not open), so it cannot
    // be overridden from another module; the mouse-down hook is enough to tell the
    // board which pane the user just clicked.
    override func mouseDown(with event: NSEvent) {
        // SwiftTerm never makes itself first responder on click (see
        // MacTerminalView.mouseDown), so a click after touching the sidebar, the
        // tab strip or the find bar left the terminal unable to receive keys —
        // the classic "sometimes I can't type" report. Take focus explicitly.
        takeFocus()
        host?.onFocus?()
        super.mouseDown(with: event)
    }

    /// Gives the terminal the keyboard unless a sheet, another window or another
    /// app currently owns it.
    func takeFocus() {
        guard let window, window.attachedSheet == nil else { return }
        // A freshly restored window is not key yet when the connect callback
        // runs; make it key first, but never steal key status from another app.
        if !window.isKeyWindow {
            guard NSApp.isActive else { return }
            window.makeKey()
        }
        if window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        copySelectionIfNeeded()
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        copySelectionIfNeeded()
    }

    override func rightMouseDown(with event: NSEvent) {
        // A full-screen program (vim, tmux, htop) owns the mouse: the right
        // button belongs to it. Everywhere else the right button pastes, which
        // is what a terminal with a three-button mouse is expected to do;
        // copying is already covered by copy-on-select.
        guard !isReportingMouseEvents else {
            super.rightMouseDown(with: event)
            return
        }
        paste(nil)
        takeFocus()
    }

    /// Copies the active selection once per distinct text.
    ///
    /// Copy-on-select used to run only from `mouseUp`, which is unreliable: a
    /// drag that ends outside the view never delivers mouse-up, and SwiftTerm
    /// settles the selection inside its own drag tracking. Running the copy at
    /// the end of every drag event makes the clipboard follow the highlight.
    private func copySelectionIfNeeded() {
        guard copyOnSelect else { return }
        guard let text = getSelection(), !text.isEmpty else {
            lastCopiedSelection = nil
            return
        }
        guard text != lastCopiedSelection else { return }
        lastCopiedSelection = text
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    override func paste(_ sender: Any?) {
        guard confirmMultilinePaste,
              let text = NSPasteboard.general.string(forType: .string),
              text.contains("\n") || text.contains("\r") else {
            super.paste(sender as Any)
            return
        }
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).filter { !$0.isEmpty }.count
        let alert = NSAlert()
        alert.messageText = L("粘贴 %d 行内容？", lines)
        alert.informativeText = L("内容包含换行，粘贴后可能立即执行多条命令。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("粘贴"))
        alert.addButton(withTitle: L("取消"))
        if alert.runModal() == .alertFirstButtonReturn {
            super.paste(sender as Any)
        }
        // The modal alert took the keyboard away; hand it back so the next
        // keystroke is not swallowed.
        takeFocus()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) != nil {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return .copy
        }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                            options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty,
           let handler = host?.onFilesDropped {
            handler(urls)
            takeFocus()
            return true
        }
        return super.performDragOperation(sender)
    }
}

/// SwiftUI owns this wrapper, not the terminal subview. Mounting elsewhere
/// transfers the same view; tearing down the old host cannot detach it again.
final class TerminalViewHost: NSView {
    var onSend: ((Data) -> Void)?
    var onFilesDropped: (([URL]) -> Void)?
    var onFocus: (() -> Void)?

    private var terminal: TaugeTerminalView? { subviews.first as? TaugeTerminalView }

    func mount(_ view: TaugeTerminalView) {
        guard view.superview !== self else { return }
        unmount()
        view.removeFromSuperview()
        addSubview(view)
        fitTerminal()
    }

    func unmount() {
        terminal?.removeFromSuperview()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        fitTerminal()
    }

    private func fitTerminal() {
        // A freshly mounted host has no layout yet. Keep the terminal's last
        // grid instead of sending a transient size to the shell.
        guard let terminal, bounds.width > 0, bounds.height > 0, terminal.frame != bounds else { return }
        terminal.frame = bounds
    }
}

struct TerminalContainer: NSViewRepresentable {
    let bridge: TerminalBridge
    let settings: AppSettings
    let initialColumns: Int
    let initialRows: Int
    let onSend: (Data) -> Void
    var onFilesDropped: (([URL]) -> Void)? = nil
    var onFocus: (() -> Void)? = nil

    func makeNSView(context: Context) -> TerminalViewHost {
        TerminalViewHost(frame: .zero)
    }

    func updateNSView(_ host: TerminalViewHost, context: Context) {
        host.onSend = onSend
        host.onFilesDropped = onFilesDropped
        host.onFocus = onFocus
        host.mount(bridge.prepare(settings: settings, columns: initialColumns, rows: initialRows))
    }

    static func dismantleNSView(_ host: TerminalViewHost, coordinator: Void) {
        host.unmount()
    }
}

/// The palette of the active theme, kept for chrome that surrounds the
/// terminal (pane backgrounds, status bar). It follows the selected theme so the
/// card behind the terminal never contradicts it.
@MainActor
enum TerminalPalette {
    static var theme: TerminalTheme { TerminalThemeCatalog.theme(named: AppState.shared.settings.terminalThemeName) }
    static var background: NSColor { theme.background }
    static var foreground: NSColor { theme.foreground }
    static var caret: NSColor { theme.caret }
}
