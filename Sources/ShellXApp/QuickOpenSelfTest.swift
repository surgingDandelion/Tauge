import AppKit

/// Developer hook that proves quick open takes the keyboard without a human at
/// the keys: `SHELLX_QUICKOPEN_SELFTEST=1` opens the panel, walks the highlight
/// down to the "打开设置" row with real ↓ key events, and presses ↩.
///
/// The result is the assertion itself: if the arrows did not move the
/// selection, ↩ activates the first row and the settings window never opens.
@MainActor
enum QuickOpenSelfTest {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SHELLX_QUICKOPEN_SELFTEST"] == "1"
    }

    static func runIfRequested() {
        guard isEnabled else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await run()
        }
    }

    private static func run() async {
        let app = AppState.shared
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) else {
            report("no main window"); exit(1)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 400_000_000)

        app.showQuickOpen()
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard app.showingCommandPalette else { report("panel did not open"); exit(1) }

        let rows = app.commandPaletteResults(query: "")
        guard let target = rows.firstIndex(where: { $0.id == "action-3" }) else {
            report("no settings row in \(rows.count) rows"); exit(1)
        }
        report("rows=\(rows.count) settingsRow=\(target)")

        for _ in 0..<target {
            send(125, window: window)                     // ↓
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        send(36, window: window)                          // ↩
        try? await Task.sleep(nanoseconds: 600_000_000)

        let opened = app.showingSettings
        report("settings-open=\(opened)")
        exit(opened ? 0 : 1)
    }

    private static func send(_ keyCode: UInt16, window: NSWindow) {
        let characters: String
        switch keyCode {
        case 125: characters = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case 126: characters = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case 36: characters = "\r"
        default: characters = ""
        }
        guard let event = NSEvent.keyEvent(with: .keyDown,
                                           location: .zero,
                                           modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber,
                                           context: nil,
                                           characters: characters,
                                           charactersIgnoringModifiers: characters,
                                           isARepeat: false,
                                           keyCode: keyCode) else {
            report("cannot build event \(keyCode)"); return
        }
        NSApp.sendEvent(event)
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data("[quickopen-selftest] \(message)\n".utf8))
    }
}
