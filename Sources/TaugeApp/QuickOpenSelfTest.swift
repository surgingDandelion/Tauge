import AppKit
import SwiftUI
import TaugeKit

/// Exercises the real panel and AppKit event dispatch against a scratch catalog.
/// Run with `Tauge --verify-quick-open`; no SSH connections or user data are used.
@MainActor
enum QuickOpenSelfTest {
    static func run() -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                let passed = try await check()
                exit(passed ? 0 : 1)
            } catch {
                print("FAIL quick open: \(error)")
                exit(1)
            }
        }
        application.run()
        exit(1)
    }

    private static func check() async throws -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("catalog.sqlite")
        let store = try HostStore(url: catalog)
        let first = SSHHost(name: "fixture-a-14", hostname: "127.0.0.1", authMethod: .agent)
        let second = SSHHost(name: "fixture-b-14", hostname: "127.0.0.1", authMethod: .agent)
        let other = SSHHost(name: "fixture-other", hostname: "127.0.0.1", authMethod: .agent)
        for host in [first, second, other] { try store.save(host: host) }
        let workspace = BoardDefinition(name: "Local fixture-a")
        try store.save(board: workspace)
        var settings = AppSettings()
        settings.autoReconnect = false
        try store.save(settings: settings)
        // A real empty fixture vault also prevents legacy migration to this folder.
        try LocalVaultStore(directory: root).setSecret(nil, for: .hostPassword(first.id))
        setenv(CatalogLocation.overrideEnvironmentKey, catalog.path, 1)
        let app = AppState.shared
        let back = makeWindow(app: app)
        let front = makeWindow(app: app)
        defer { back.contentView = nil; front.contentView = nil }

        var passed = true
        func expect(_ condition: Bool, _ description: String) {
            print("\(condition ? "ok" : "FAIL") quick open: \(description)")
            if !condition { passed = false }
        }

        app.showingCommandPalette = true
        guard let backField = await field(in: back), let frontField = await field(in: front) else {
            expect(false, "search fields mounted")
            return false
        }
        expect(backField.currentEditor() != nil && frontField.currentEditor() != nil,
               "each panel focuses its own search field when mounted")
        edit(backField, in: back, with: "other")
        // Move past the initially visible rows before changing the list.
        for _ in 0..<9 {
            send(125, "\u{f701}", to: front)
            await settle(front)
        }
        send(126, "\u{f700}", to: front)
        await settle(front)
        guard let editor = frontField.currentEditor() as? NSTextView else {
            expect(false, "navigation leaves the search field ready for typing")
            return false
        }
        editor.insertText("fixture", replacementRange: NSRange(location: NSNotFound, length: 0))
        await settle(front)
        expect(highlightedRow(in: front) == 0, "filtering from a scrolled list reveals the first result")
        send(125, "\u{f701}", to: front)
        await settle(front)
        expect(highlightedRow(in: front) == 1, "Down moves the painted highlight after filtering")

        editor.insertText("-a", replacementRange: NSRange(location: NSNotFound, length: 0))
        await settle(front)
        expect(app.commandPaletteResults(query: frontField.stringValue).map(\.id)
               == ["host-" + first.id.uuidString, "board-" + workspace.id.uuidString],
               "narrowed query displays a host before the matching workspace")
        expect(highlightedRow(in: front) == 0, "narrowing the query paints the host result")
        send(125, "\u{f701}", to: front)
        await settle(front)
        expect(highlightedRow(in: front) == 1, "Down moves the painted highlight to the workspace")
        send(126, "\u{f700}", to: front)
        await settle(front)
        expect(highlightedRow(in: front) == 0, "Up moves the painted highlight back to the host")

        editor.insertText("", replacementRange: NSRange(location: 7, length: 2))
        await settle(front)
        expect(frontField.stringValue == "fixture" && highlightedRow(in: front) == 0,
               "broadening the query restores the highlight on the first result")
        expect(frontField.currentEditor() === editor,
               "filtering and arrow navigation keep the current editor active")
        editor.insertText("14", replacementRange: NSRange(location: 0, length: 7))
        await settle(back, front)
        expect(backField.stringValue == "other" && frontField.stringValue == "14", "search in both windows")
        send(125, "\u{f701}", to: front)
        await settle(front)
        send(36, "\r", to: front)
        expect(app.selectedTab?.hostID == second.id, "Down and Return use the results in the receiving window")
        await settle(back, front)
        app.alert = nil
        app.showingCommandPalette = false
        back.contentView = nil
        await settle(front)

        guard let board = app.currentBoard else { return false }
        app.openBoardTab(board.id, connect: false)
        expect(app.isWorkspaceSelected, "start from a workspace tab")
        app.showingCommandPalette = true
        guard let search = await field(in: front) else { return false }
        edit(search, in: front, with: "b-14")
        let beforeReturn = app.tabs.count
        send(36, "\r", to: front)
        expect(app.tabs.count == beforeReturn + 1 && app.selectedTab?.hostID == second.id,
               "Return immediately after typing opens the filtered host")
        expect(!app.isWorkspaceSelected, "the new terminal takes precedence over the current workspace")
        expect(try store.setting(key: "board.selected") == "", "the visible tab selection survives a restart")
        await settle(front)

        app.alert = nil
        app.showingCommandPalette = true
        guard let keyboardField = await field(in: front) else { return false }
        edit(keyboardField, in: front, with: "14")
        send(125, "\u{f701}", to: front)
        send(126, "\u{f700}", to: front)
        send(76, "\u{3}", to: front, modifiers: [.command, .numericPad])
        expect(app.selectedTab?.hostID == first.id && app.selectedTab?.kind == .sftp && !app.showingCommandPalette,
               "Up moves back one result and Command–keypad Enter opens SFTP for it")
        await settle(front)

        app.alert = nil
        app.showingCommandPalette = true
        guard let multiField = await field(in: front) else { return false }
        edit(multiField, in: front, with: "14")
        send(125, "\u{f701}", to: front, modifiers: .shift)
        send(126, "\u{f700}", to: front, modifiers: .control)
        let beforeToggle = app.tabs.count
        send(36, "\r", to: front)
        expect(app.tabs.count == beforeToggle + 1 && app.selectedTab?.hostID == second.id,
               "Return does not open a host just removed from the multi-selection")
        await settle(front)

        app.alert = nil
        app.showingCommandPalette = true
        guard let emptyField = await field(in: front) else { return false }
        expect(emptyField.stringValue.isEmpty, "reopening starts with a fresh search")
        edit(emptyField, in: front, with: "no-such-quick-open-result")
        send(36, "\r", to: front)
        expect(app.showingCommandPalette, "Return does not activate anything with no matches")
        send(53, "\u{1b}", to: front)
        expect(!app.showingCommandPalette, "Escape dismisses the panel")
        return passed
    }

    private struct Surface: View {
        @ObservedObject var app: AppState

        var body: some View {
            Color.clear.overlay {
                if app.showingCommandPalette { QuickOpenView().environmentObject(app) }
            }
        }
    }

    private static func makeWindow(app: AppState) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: Surface(app: app))
        return window
    }

    /// Sample the blank middle of the first two filtered rows.
    /// This checks the painted fill separately from Return.
    private static func highlightedRow(in window: NSWindow) -> Int? {
        guard let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsHigh) / view.bounds.height
        let x = bitmap.pixelsWide / 2
        func color(y: Int) -> NSColor? {
            bitmap.colorAt(x: x, y: Int(CGFloat(y) * scale))?.usingColorSpace(.sRGB)
        }
        guard let first = color(y: 165), let second = color(y: 203) else { return nil }
        // The light selection fill is blue-gray. A mouse hover is neutral gray.
        func hasFill(_ sample: NSColor) -> Bool {
            sample.blueComponent - sample.redComponent > 0.025
        }
        switch (hasFill(first), hasFill(second)) {
        case (true, false): return 0
        case (false, true): return 1
        default: return nil
        }
    }

    private static func field(in window: NSWindow) async -> NSTextField? {
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap(find).first
        }
        for _ in 0..<50 {
            if let root = window.contentView {
                root.layoutSubtreeIfNeeded()
                if let field = find(root) { return field }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private static func edit(_ field: NSTextField, in window: NSWindow, with text: String) {
        window.makeFirstResponder(field)
        (field.currentEditor() as? NSTextView)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private static func settle(_ windows: NSWindow...) async {
        for window in windows { window.contentView?.layoutSubtreeIfNeeded() }
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    private static func send(_ keyCode: UInt16, _ characters: String, to window: NSWindow,
                             modifiers: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                           modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: keyCode) else { return }
        NSApp.sendEvent(event)
    }
}
