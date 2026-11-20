import Foundation
import TaugeKit
import SwiftTerm

/// Guards the two width-sensitive paths behind "pasted Chinese text corrupts
/// the terminal": the pty window size the system ssh transport reports, and
/// SwiftTerm's cell accounting for wide characters. Both are easy to regress
/// and neither shows up in an ordinary build.
func runTerminalWidthChecks() {
    run("system ssh pty reports and forwards window size") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tauge-pty-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let fakeSSH = root.appendingPathComponent("fake-ssh")
        let script = """
        #!/bin/sh
        trap 'printf "WINCH\\n"' WINCH
        while :; do
            printf 'SIZE %s\\n' "$(stty size)"
            sleep 0.2
        done
        """
        try script.write(to: fakeSSH, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSSH.path)

        let options = SystemSSHOptions(host: "127.0.0.1", port: 22, username: "check", credential: .none)
        let workspace = try SystemSSHWorkspace(options: options, sshExecutable: fakeSSH.path)
        defer { workspace.cleanup() }
        let process = try SystemSSHTerminalProcess(options: options, workspace: workspace, columns: 100, rows: 30)
        defer { process.terminate() }

        let output = PTYOutput()
        process.onData = { data in output.append(data) }

        expect(waitFor(5) { output.text.contains("SIZE 30 100") },
               "the child starts with the size passed to openpty: \(output.text)")

        process.resize(columns: 137, rows: 41)
        expect(waitFor(5) { output.text.contains("SIZE 41 137") },
               "resize reaches the pty: \(output.text)")
        expect(waitFor(2) { output.text.contains("WINCH") },
               "resize also pokes the ssh child so it forwards a window-change: \(output.text)")
    }

    run("CJK glyphs occupy two cells and wrap on cell boundaries") {
        let terminal = Terminal(delegate: NullTerminalDelegate(), options: TerminalOptions(cols: 20, rows: 5))
        // The cursor rests past the last column at the end of a row, so one
        // extra glyph is what forces the observed wrap.
        terminal.feed(text: String(repeating: "中", count: 31))
        expectEqual(terminal.getCursorLocation().x, 2, "the 31st glyph wraps to column 2")
        expectEqual(terminal.getCursorLocation().y, 3, "cursor advances one row per ten CJK glyphs")
        let first = terminal.getLine(row: 0)?.translateToString(trimRight: true) ?? ""
        expectEqual(first.filter { $0 == "中" }.count, 10,
                    "a 20-column row holds ten double-width glyphs")
    }
}

private final class NullTerminalDelegate: TerminalDelegate {
    func showCursor(source: Terminal) {}
    func hideCursor(source: Terminal) {}
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

/// Collects pty output from the reader queue.
private final class PTYOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        storage += String(decoding: data, as: UTF8.self)
        lock.unlock()
    }
}

private func waitFor(_ seconds: Double, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
}
