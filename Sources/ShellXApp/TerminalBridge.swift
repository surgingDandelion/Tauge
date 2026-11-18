import AppKit
import SwiftUI
import SwiftTerm
import ShellXKit

/// Bridges the SwiftTerm view and the SSH channel.
///
/// Data arrives from NIO threads long before SwiftUI has mounted the view, and
/// it must survive tab switches, so the bridge buffers output until a view
/// attaches and keeps a bounded replay buffer for re-attach.
@MainActor
final class TerminalBridge {
    weak var view: ShellXTerminalView?
    private var pending: [Data] = []
    private var replay: [Data] = []
    private var replayBytes = 0
    private let replayLimit = 512 * 1024

    func attach(_ view: ShellXTerminalView) {
        self.view = view
        let backlog = replay + pending
        pending.removeAll()
        for chunk in backlog {
            view.feed(byteArray: ArraySlice(chunk))
        }
    }

    func detach(_ view: ShellXTerminalView) {
        if self.view === view { self.view = nil }
    }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        replay.append(data)
        replayBytes += data.count
        while replayBytes > replayLimit, replay.count > 1 {
            replayBytes -= replay.removeFirst().count
        }
        if let view {
            view.feed(byteArray: ArraySlice(data))
        } else if pending.count < 512 {
            pending.append(data)
        }
    }

    func clear() {
        replay.removeAll()
        pending.removeAll()
        replayBytes = 0
    }
}

/// TerminalView subclass that adds copy-on-select, a multiline-paste guard and
/// Finder drag-and-drop upload support.
final class ShellXTerminalView: TerminalView {
    var copyOnSelect = true
    var confirmMultilinePaste = true
    private var lastCopiedSelection: String?
    /// Called with files dropped from Finder. The container is responsible for
    /// uploading them and echoing the remote paths back (without a newline).
    var onFilesDropped: (([URL]) -> Void)?
    /// Called whenever the terminal gains focus (click or keyboard), so the board
    /// can highlight the pane the user is actually working in.
    var onFocus: (() -> Void)?

    // SwiftTerm declares becomeFirstResponder as public (not open), so it cannot
    // be overridden from another module; the mouse-down hook is enough to tell the
    // board which pane the user just clicked.
    override func mouseDown(with event: NSEvent) {
        // SwiftTerm never makes itself first responder on click (see
        // MacTerminalView.mouseDown), so a click after touching the sidebar, the
        // tab strip or the find bar left the terminal unable to receive keys —
        // the classic "sometimes I can't type" report. Take focus explicitly.
        takeFocus()
        onFocus?()
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
            super.paste(sender)
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
            super.paste(sender)
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
           let handler = onFilesDropped {
            handler(urls)
            takeFocus()
            return true
        }
        return super.performDragOperation(sender)
    }
}

/// SwiftUI wrapper around SwiftTerm's macOS view.
struct TerminalContainer: NSViewRepresentable {
    let bridge: TerminalBridge
    let settings: AppSettings
    let onSend: (Data) -> Void
    let onResize: (Int, Int) -> Void
    let onDirectoryChange: (String?) -> Void
    var onFilesDropped: (([URL]) -> Void)? = nil
    var onFocus: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ShellXTerminalView {
        var options = TerminalOptions(cols: 100, rows: 30, termName: "xterm-256color", scrollback: settings.scrollbackLines)
        options.enableOsc8Hyperlinks = true
        options.kittyClipboardPolicy = []
        let view = ShellXTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 560), font: font, options: options)
        view.optionAsMetaKey = settings.optionAsMeta
        view.copyOnSelect = settings.copyOnSelect
        view.confirmMultilinePaste = settings.confirmMultilinePaste
        view.onFilesDropped = onFilesDropped
        view.onFocus = onFocus
        view.terminalDelegate = context.coordinator
        view.registerForDraggedTypes([.fileURL])
        applyTheme(to: view)
        context.coordinator.view = view
        bridge.attach(view)
        return view
    }

    func updateNSView(_ view: ShellXTerminalView, context: Context) {
        context.coordinator.parent = self
        view.optionAsMetaKey = settings.optionAsMeta
        view.copyOnSelect = settings.copyOnSelect
        view.confirmMultilinePaste = settings.confirmMultilinePaste
        view.onFilesDropped = onFilesDropped
        view.onFocus = onFocus
        let theme = TerminalThemeCatalog.theme(named: settings.terminalThemeName)
        if view.nativeBackgroundColor != theme.background
            || view.font.pointSize != settings.terminalFontSize
            || view.lineSpacing != CGFloat(settings.terminalLineHeight)
            || view.backgroundOpacity != CGFloat(settings.terminalBackgroundOpacity) {
            view.font = font
            applyTheme(to: view)
        }
        if bridge.view !== view { bridge.attach(view) }
    }

    static func dismantleNSView(_ view: ShellXTerminalView, coordinator: Coordinator) {
        coordinator.parent.bridge.detach(view)
    }

    private var font: NSFont {
        NSFont(name: settings.terminalFontFamily, size: settings.terminalFontSize)
            ?? NSFont.monospacedSystemFont(ofSize: settings.terminalFontSize, weight: .regular)
    }

    private func applyTheme(to view: ShellXTerminalView) {
        let theme = TerminalThemeCatalog.theme(named: settings.terminalThemeName)
        view.nativeForegroundColor = theme.foreground
        view.nativeBackgroundColor = theme.background
        view.caretColor = theme.caret
        view.installColors(theme.ansi)
        view.backgroundOpacity = CGFloat(max(0.5, min(1.0, settings.terminalBackgroundOpacity)))
        view.lineSpacing = CGFloat(max(0.9, min(1.6, settings.terminalLineHeight)))
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var parent: TerminalContainer
        weak var view: ShellXTerminalView?

        init(parent: TerminalContainer) {
            self.parent = parent
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            parent.onResize(newCols, newRows)
        }

        // Remote shells emit OSC 0/2 titles ("user@host: ~") through this
        // delegate call. Tabs stay labelled with the host's own name, so the
        // title is deliberately dropped instead of renaming the tab.
        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            parent.onDirectoryChange(directory)
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            parent.onSend(Data(data))
        }

        func scrolled(source: TerminalView, position: Double) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(content, forType: .string)
        }

        func clipboardRead(source: TerminalView) -> Data? {
            NSPasteboard.general.string(forType: .string).map { Data($0.utf8) }
        }

        func bell(source: TerminalView) {
            NSSound.beep()
        }
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
