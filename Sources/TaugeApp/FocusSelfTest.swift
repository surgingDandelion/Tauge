import AppKit
import SwiftTerm
import TaugeKit

/// Developer hook that reproduces the "terminal sometimes stops accepting
/// keystrokes" report without a human at the keyboard.
///
/// Run with `TAUGE_FOCUS_SELFTEST=1`. After the restored tab connects it
/// takes the keyboard away from the terminal exactly the way SwiftUI chrome
/// does (first responder = window), dispatches a synthetic key down, and checks
/// that the window key monitor handed the terminal back and that the byte
/// reached the shell.
@MainActor
enum FocusSelfTest {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["TAUGE_FOCUS_SELFTEST"] == "1"
    }

    static func runIfRequested() {
        guard isEnabled else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await run()
        }
    }

    private static func run() async {
        let app = AppState.shared
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }) else {
            report("no main window"); return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 500_000_000)

        guard let terminal = app.activeTerminalView else { report("no terminal view"); return }
        report("terminal present, window key=\(window.isKeyWindow)")

        // 1. Chrome steals the keyboard (what clicking a tab chip / the sidebar
        //    leaves behind: the window or the SwiftUI host becomes responder).
        window.makeFirstResponder(nil)
        let stolen = window.firstResponder
        report("stolen responder=\(describe(stolen))")

        // 2. A key arrives while the terminal is not first responder.
        guard let event = NSEvent.keyEvent(with: .keyDown,
                                           location: .zero,
                                           modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber,
                                           context: nil,
                                           characters: "z",
                                           charactersIgnoringModifiers: "z",
                                           isARepeat: false,
                                           keyCode: 6) else {
            report("cannot build event"); return
        }
        NSApp.sendEvent(event)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let after = window.firstResponder
        let handoff = after === terminal
        report("after keydown responder=\(describe(after)) handoff=\(handoff)")

        // 3. Proof the byte reached the shell: type a marker through the same
        //    channel the keyboard uses, then look for its echo in the buffer.
        if let tab = app.selectedTab ?? app.focusedBoardSession {
            terminal.insertText("echo focus-selftest-ok\n", replacementRange: NSRange(location: NSNotFound, length: 0))
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let buffer = String(data: terminal.getBufferAsData(kind: .active, encoding: .utf8), encoding: .utf8) ?? ""
            report("echo visible=\(buffer.contains("focus-selftest-ok")) tab=\(tab.host.name)")
        }
        report("done")
    }

    private static func describe(_ responder: NSResponder?) -> String {
        guard let responder else { return "nil" }
        return String(describing: type(of: responder))
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data(("[selftest] " + message + "\n").utf8))
    }
}
