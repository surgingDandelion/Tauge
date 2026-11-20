import Foundation
import TaugeKit

/// Covers the SFTP folder memory (sftp_history) and the new navigation settings.
/// The UI relies on both: reopening a host should land in the folder the user last
/// browsed, and the board mode should survive a relaunch.
func runBoardChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("tauge-board-checks-" + UUID().uuidString)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    func makeStore(_ name: String) throws -> (SQLiteDatabase, HostStore) {
        let database = try SQLiteDatabase(path: root.appendingPathComponent(name).path)
        return (database, try HostStore(database: database))
    }

    run("sftp history remembers the last folder per host") {
        let (database, store) = try makeStore("history.sqlite")
        defer { database.close() }
        let host = SSHHost(name: "history", hostname: "example.com")
        try store.save(host: host)
        let other = SSHHost(name: "other", hostname: "example.org")
        try store.save(host: other)

        expectEqual(try store.lastSFTPPath(hostID: host.id), nil, "no history yet")
        try store.recordSFTPPath(hostID: host.id, path: "/var/log")
        expectEqual(try store.lastSFTPPath(hostID: host.id), "/var/log", "first folder is remembered")
        try store.recordSFTPPath(hostID: other.id, path: "/srv")
        expectEqual(try store.lastSFTPPath(hostID: host.id), "/var/log", "other hosts keep their own folder")

        try store.recordSFTPPath(hostID: host.id, path: "/etc/nginx")
        expectEqual(try store.lastSFTPPath(hostID: host.id), "/etc/nginx", "newest folder wins")
        let entries = try store.sftpHistory(hostID: host.id)
        expectEqual(entries.count, 2, "both folders are listed")
        expectEqual(entries.first?.path, "/etc/nginx", "history is ordered newest first")

        // Re-recording an old path must move it to the front instead of duplicating it.
        try store.recordSFTPPath(hostID: host.id, path: "/var/log")
        expectEqual(try store.sftpHistory(hostID: host.id).count, 2, "re-recording does not duplicate")
        expectEqual(try store.lastSFTPPath(hostID: host.id), "/var/log", "re-recorded folder becomes newest")
    }

    run("sftp history keeps at most fifty folders per host") {
        let (database, store) = try makeStore("history-limit.sqlite")
        defer { database.close() }
        let host = SSHHost(name: "limit", hostname: "example.com")
        try store.save(host: host)
        for index in 0..<60 {
            try store.recordSFTPPath(hostID: host.id, path: "/data/" + String(index))
        }
        let entries = try store.sftpHistory(hostID: host.id, limit: 100)
        expectEqual(entries.count, 50, "older folders are pruned")
        expectEqual(try store.lastSFTPPath(hostID: host.id), "/data/59", "newest folder survived pruning")
        expect(!entries.contains { $0.path == "/data/0" }, "oldest folder was pruned")

        try store.clearSFTPHistory(hostID: host.id)
        expectEqual(try store.sftpHistory(hostID: host.id).count, 0, "clear removes the history")
        expectEqual(try store.lastSFTPPath(hostID: host.id), nil, "no folder left after clear")
    }

    run("sftp history is dropped together with the host") {
        let (database, store) = try makeStore("history-delete.sqlite")
        defer { database.close() }
        let host = SSHHost(name: "doomed", hostname: "example.com")
        try store.save(host: host)
        try store.recordSFTPPath(hostID: host.id, path: "/tmp")
        try store.deleteHost(id: host.id)
        expectEqual(try store.lastSFTPPath(hostID: host.id), nil, "history rows are removed with the host")
    }

    run("navigation settings round-trip and stay backward compatible") {
        let (database, store) = try makeStore("settings.sqlite")
        defer { database.close() }
        var settings = try store.settings()
        expectEqual(settings.navigationMode, "tabs", "tabs is the default view")
        expectEqual(settings.lastLocalDirectory, nil, "no local folder recorded initially")
        expectEqual(settings.mcpEnabled, false, "MCP starts disabled")

        settings.navigationMode = "board"
        settings.lastLocalDirectory = "/Users/example/Downloads"
        settings.mcpEnabled = true
        try store.save(settings: settings)
        let reloaded = try store.settings()
        expectEqual(reloaded.navigationMode, "board", "board mode persists")
        expectEqual(reloaded.lastLocalDirectory, "/Users/example/Downloads", "local folder persists")
        expectEqual(reloaded.mcpEnabled, true, "MCP setting persists")

        // An old settings blob (no navigationMode / lastLocalDirectory keys) must still decode.
        let encoded = try JSONEncoder().encode(AppSettings())
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            expect(false, "settings JSON should be an object")
            return
        }
        object.removeValue(forKey: "navigationMode")
        object.removeValue(forKey: "lastLocalDirectory")
        object.removeValue(forKey: "sidebarVisible")
        object.removeValue(forKey: "mcpEnabled")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        expectEqual(decoded.navigationMode, "tabs", "legacy settings fall back to tabs")
        expectEqual(decoded.lastLocalDirectory, nil, "legacy settings have no local folder")
        // The start page lists every host, so the sidebar starts hidden.
        expectEqual(decoded.sidebarVisible, false, "legacy settings hide the sidebar")
        expectEqual(decoded.mcpEnabled, false, "legacy settings keep MCP disabled")

        var visible = decoded
        visible.sidebarVisible = true
        try store.save(settings: visible)
        expectEqual(try store.settings().sidebarVisible, true, "sidebar visibility persists")
    }
}
