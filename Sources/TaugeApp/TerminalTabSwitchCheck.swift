import AppKit
import SwiftUI
import SwiftTerm
import TaugeKit

/// Offscreen regression check, with no catalog, network, or user preferences.
/// Run with `Tauge --verify-terminal-tab-switch`.
@MainActor
enum TerminalTabSwitchCheck {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let failure = await check()
            print(failure.map { "FAIL terminal tab switch: \($0)" } ?? "ok terminal tab switch")
            exit(failure == nil ? 0 : 1)
        }
        app.run()
        exit(1)
    }

    private static func check() async -> String? {
        let fixture = Fixture()
        let bridge = fixture.bridge
        let terminal = bridge.prepare(settings: fixture.settings, columns: 100, rows: 30)
        defer { bridge.close() }
        bridge.feed(Data("before first mount\r\n".utf8))

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1240, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Pane(fixture: fixture))
        guard await settle(window, until: { bridge.view === terminal && terminal.terminalDimensions.cols > 100 }) else {
            return "terminal did not lay out in the wide window"
        }

        // zsh tentatively writes a reverse-video EOL marker and pads to the
        // PTY width. When the preceding line ended normally, CR lets the
        // prompt overwrite the marker — unless the terminal wrapped early.
        let columns = terminal.terminalDimensions.cols
        let prompt = "\u{1b}[1;7m%\u{1b}[0m" + String(repeating: " ", count: columns - 1)
            + "\r \r\r\u{1b}[Jfixture % \u{1b}[K\u{1b}[?2004h"
        bridge.feed(Data(prompt.utf8))
        let initialGrid = terminal.terminalDimensions
        let initialResizeCount = fixture.resizeCount

        fixture.isSelected = false
        guard await settle(window, until: { bridge.view == nil }) else { return "terminal did not unmount" }
        bridge.feed(Data("\r\nwhile hidden\r\n".utf8))
        fixture.isSelected = true
        guard await settle(window, until: { bridge.view === terminal }) else { return "terminal was rebuilt" }
        guard terminal.terminalDimensions == initialGrid, fixture.resizeCount == initialResizeCount else {
            return "switching tabs sent a size change at unchanged window size"
        }

        fixture.isSelected = false
        guard await settle(window, until: { bridge.view == nil }) else { return "terminal did not unmount again" }
        window.setContentSize(CGSize(width: 900, height: 500))
        fixture.isSelected = true
        guard await settle(window, until: {
            bridge.view === terminal && terminal.terminalDimensions.cols < initialGrid.cols
        }), fixture.resizeCount > initialResizeCount else { return "real resize did not reach the terminal" }

        let lines = String(decoding: terminal.getBufferAsData(), as: UTF8.self)
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.filter({ $0 == "before first mount" }).count == 1,
              lines.filter({ $0 == "while hidden" }).count == 1,
              lines.filter({ $0 == "fixture %" }).count == 1,
              !lines.contains("%"), terminal.terminalInputStateSnapshot()?.bracketedPasteMode == true else {
            return "the prompt, hidden output, or terminal mode changed across remounts"
        }
        return nil
    }

    private static func settle(_ window: NSWindow, until condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            window.contentView?.layoutSubtreeIfNeeded()
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    @MainActor
    private final class Fixture: ObservableObject {
        let bridge = TerminalBridge()
        let settings = AppSettings()
        @Published var isSelected = true
        var resizeCount = 0

        init() {
            bridge.onResize = { [weak self] _, _ in self?.resizeCount += 1 }
        }
    }

    private struct Pane: View {
        @ObservedObject var fixture: Fixture

        var body: some View {
            if fixture.isSelected {
                TerminalContainer(bridge: fixture.bridge, settings: fixture.settings,
                                  initialColumns: 100, initialRows: 30, onSend: { _ in })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
