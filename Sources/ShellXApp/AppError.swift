import Foundation
import NIOCore
import NIOPosix
import ShellXKit

/// A user-facing error carrying enough context to render a useful alert.
struct AppError: LocalizedError, Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
    var suggestion: String?

    var errorDescription: String? { message }
    var recoverySuggestion: String? { suggestion }

    init(title: String, message: String, suggestion: String? = nil) {
        self.title = title
        self.message = message
        self.suggestion = suggestion
    }

    init(_ error: Error, title: String = L("操作失败")) {
        if let ssh = error as? SSHConnectionError {
            self.init(title: title,
                      message: ssh.errorDescription ?? ssh.detail,
                      suggestion: ssh.recoverySuggestion)
        } else if let app = error as? AppError {
            self.init(title: app.title, message: app.message, suggestion: app.suggestion)
        } else if let sqlite = error as? SQLiteError, sqlite.isReadOnly {
            self.init(title: L("数据库不可写"),
                      message: L("Tauge 无法写入本地数据库，刚才的修改没有被保存。"),
                      suggestion: L("常见原因是应用运行在受限沙盒中，或数据库文件与目录没有写权限。请从 Finder 直接启动 Tauge.app 后重试；也可以在“设置 → 高级”中把数据库迁移到可写位置。"))
        } else if let sqlite = error as? SQLiteError, sqlite.isDiskFull {
            self.init(title: L("磁盘空间不足"),
                      message: L("写入本地数据库失败：磁盘已满。"),
                      suggestion: L("请清理磁盘空间后重试。数据库位于“设置 → 高级”显示的位置。"))
        } else if let sqlite = error as? SQLiteError, sqlite.isUnopenable {
            self.init(title: L("无法打开数据库"),
                      message: error.localizedDescription,
                      suggestion: L("请检查数据库文件是否被占用或损坏，可在“设置 → 高级”中导出或迁移数据库。"))
        } else {
            self.init(title: title, message: error.localizedDescription)
        }
    }
}

/// Shared, long-lived services. Everything the UI touches on the main thread
/// lives behind AppState; this object only owns storage and networking
/// singletons so they are created once per process.
@MainActor
final class AppEnvironment {
    let store: HostStore
    let secrets: SecretStore
    let localFiles: LocalFileService
    let transferEngine: TransferEngine
    let eventLoopGroup: MultiThreadedEventLoopGroup
    let databaseURL: URL
    let isEphemeralDatabase: Bool
    /// Human readable reason when the configured catalog could not be opened at all.
    let catalogOpenFailure: String?
    /// True when the catalog opened but rejected writes (read-only file, directory or sandbox).
    let isReadOnlyCatalog: Bool

    init(store: HostStore, databaseURL: URL, isEphemeralDatabase: Bool, isReadOnlyCatalog: Bool = false,
         catalogOpenFailure: String? = nil) {
        self.store = store
        self.databaseURL = databaseURL
        self.isEphemeralDatabase = isEphemeralDatabase
        self.catalogOpenFailure = catalogOpenFailure
        self.isReadOnlyCatalog = isReadOnlyCatalog
        // Credentials live in the app's own folder, next to the catalog, so a new
        // build never re-asks for the login-keychain password. The keychain is
        // still read once per credential written by an older build and its value
        // is migrated; after that it is never touched again.
        let support = HostStore.defaultDatabaseURL().deletingLastPathComponent()
        let vaultDirectory = isEphemeralDatabase ? support : databaseURL.deletingLastPathComponent()
        self.secrets = CachingSecretStore(upstream: MigratingSecretStore(local: LocalVaultStore(directory: vaultDirectory),
                                                                        fallback: KeychainVaultStore()) { message in
            FileHandle.standardError.write(Data(("Tauge: " + message + "\n").utf8))
        })
        self.localFiles = LocalFileService()
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let defaults = (try? store.settings()) ?? AppSettings()
        self.transferEngine = TransferEngine(configuration: .init(maxConcurrent: defaults.defaultTransferConcurrency,
                                                                 maxRetries: defaults.transferRetryCount))
    }

    static func make() -> AppEnvironment {
        let fm = FileManager.default
        let preferred = CatalogLocation.currentURL
        try? fm.createDirectory(at: preferred.deletingLastPathComponent(), withIntermediateDirectories: true)

        var openFailure: String?
        do {
            let database = try SQLiteDatabase(path: preferred.path)
            let store = try HostStore(database: database)
            // Opening a read-only file succeeds; only a write round-trip tells us whether the
            // catalog can actually be saved. Detect that now so the UI can explain it.
            var readOnly = false
            do {
                try database.verifyWritable()
            } catch {
                readOnly = true
                FileHandle.standardError.write(Data(("Tauge: catalog is not writable at "
                    + preferred.path + ": " + error.localizedDescription + "\n").utf8))
            }
            return AppEnvironment(store: store, databaseURL: preferred,
                                  isEphemeralDatabase: false, isReadOnlyCatalog: readOnly)
        } catch {
            openFailure = error.localizedDescription
            FileHandle.standardError.write(Data(("Tauge: cannot open catalog at "
                + preferred.path + ": " + error.localizedDescription + "\n").utf8))
        }

        // A read-only open still shows the user's hosts, groups and keys; an empty scratch
        // database would look like data loss.
        if let database = try? SQLiteDatabase.openForReading(path: preferred.path),
           let store = try? HostStore(database: database, createSchema: false) {
            FileHandle.standardError.write(Data(("Tauge: catalog opened read-only at "
                + preferred.path + ": " + (openFailure ?? "write access denied") + "\n").utf8))
            return AppEnvironment(store: store, databaseURL: preferred, isEphemeralDatabase: false,
                                  isReadOnlyCatalog: true, catalogOpenFailure: openFailure)
        }

        // Never block startup on a corrupt catalog: fall back to a scratch database so the
        // user can still export, import or repair their catalog from a backup.
        let fallback = fm.temporaryDirectory.appendingPathComponent("shellx-fallback.sqlite")
        try? fm.removeItem(at: fallback)
        if let database = try? SQLiteDatabase(path: fallback.path), let store = try? HostStore(database: database) {
            var readOnly = false
            do { try database.verifyWritable() } catch { readOnly = true }
            return AppEnvironment(store: store, databaseURL: fallback,
                                  isEphemeralDatabase: true, isReadOnlyCatalog: readOnly,
                                  catalogOpenFailure: openFailure)
        }
        fatalError("Unable to open the Tauge catalog at " + preferred.path + ": " + (openFailure ?? "unknown error"))
    }

    /// Copies the current catalog to a writable folder and remembers the new location.
    func relocateCatalog(to directory: URL) throws -> URL {
        let target = try CatalogLocation.migrate(store: store, to: directory)
        CatalogLocation.setOverride(target)
        return target
    }
}
