import Foundation
import ShellXKit

/// Resolves where the catalog database lives and remembers a user-chosen override.
///
/// The default location is ~/Library/Application Support/ShellX/shellx.sqlite. When ShellX runs
/// inside a restricted sandbox (an agent harness, a locked-down terminal) that directory may be
/// readable but not writable: SQLite then opens the file fine and only fails on the first INSERT
/// with "attempt to write a readonly database". The override lets the user move the catalog to a
/// writable folder without losing the existing data.
enum CatalogLocation {
    static let overrideDefaultsKey = "ShellXCatalogPath"
    static let overrideEnvironmentKey = "SHELLX_CATALOG_PATH"

    static var defaultURL: URL { HostStore.defaultDatabaseURL() }

    static var overrideURL: URL? {
        if let raw = ProcessInfo.processInfo.environment[overrideEnvironmentKey], !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        if let raw = UserDefaults.standard.string(forKey: overrideDefaultsKey), !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        return nil
    }

    static var currentURL: URL { overrideURL ?? defaultURL }

    static func setOverride(_ url: URL?) {
        if let url {
            UserDefaults.standard.set(url.path, forKey: overrideDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: overrideDefaultsKey)
        }
    }

    /// Copies the live catalog to `directory/shellx.sqlite` through VACUUM INTO, so rows that
    /// only exist in the WAL file are included. An existing file at the destination is moved
    /// aside instead of being overwritten.
    static func migrate(store: HostStore, to directory: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("shellx.sqlite")
        if fm.fileExists(atPath: target.path) {
            let stamp = Self.timestampFormatter.string(from: Date())
            let backup = directory.appendingPathComponent("shellx-backup-" + stamp + ".sqlite")
            try? fm.removeItem(at: backup)
            try fm.moveItem(at: target, to: backup)
        }
        try store.database.backup(to: target)
        return target
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}