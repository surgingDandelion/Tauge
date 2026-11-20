import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public init(_ value: Int) { self = .int(Int64(value)) }
    public init(_ value: Int64) { self = .int(value) }
    public init(_ value: Int?) { self = value.map { .int(Int64($0)) } ?? .null }
    public init(_ value: Int64?) { self = value.map { .int($0) } ?? .null }
    public init(_ value: Double) { self = .double(value) }
    public init(_ value: Double?) { self = value.map { .double($0) } ?? .null }
    public init(_ value: Bool) { self = .int(value ? 1 : 0) }
    public init(_ value: String) { self = .text(value) }
    public init(_ value: Data) { self = .blob(value) }
    public init(_ value: String?) {
        if let value { self = .text(value) } else { self = .null }
    }
    public init(_ value: UUID?) {
        if let value { self = .text(value.uuidString) } else { self = .null }
    }

    public var string: String? {
        if case .text(let v) = self { return v }
        return nil
    }

    public var int64: Int64? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int64(v)
        case .text(let v): return Int64(v)
        default: return nil
        }
    }

    public var int: Int? { int64.map(Int.init) }

    public var double: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        case .text(let v): return Double(v)
        default: return nil
        }
    }

    public var bool: Bool? { int64.map { $0 != 0 } }

    public var data: Data? {
        if case .blob(let v) = self { return v }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

public typealias SQLRow = [String: SQLValue]

public enum SQLiteError: LocalizedError {
    case openFailed(String, String, Int32)
    case prepareFailed(String, String)
    case stepFailed(String, String, Int32)
    case bindFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path, let message, _): return "Cannot open database at \(path): \(message)"
        case .prepareFailed(let sql, let message): return "SQL prepare failed (\(message)) for: \(sql)"
        case .stepFailed(let sql, let message, _): return "SQL execution failed (\(message)) for: \(sql)"
        case .bindFailed(let sql, let message): return "SQL bind failed (\(message)) for: \(sql)"
        }
    }

    /// Raw SQLite result code (sqlite3_extended_errcode) when SQLite itself reported the failure.
    public var sqliteCode: Int32? {
        switch self {
        case .openFailed(_, _, let code): return code
        case .stepFailed(_, _, let code): return code
        case .prepareFailed, .bindFailed: return nil
        }
    }

    /// SQLite refused the write because the database file, its directory or the surrounding
    /// sandbox is read-only. This is not a bug in the statement, so callers should not retry it.
    public var isReadOnly: Bool {
        guard let code = sqliteCode else { return false }
        // Extended result codes for SQLITE_READONLY: base 8 plus the READONLY_* variants.
        return code == SQLITE_READONLY
            || code == 264   // SQLITE_READONLY_RECOVERY
            || code == 520   // SQLITE_READONLY_CANTLOCK
            || code == 776   // SQLITE_READONLY_ROLLBACK
            || code == 1032  // SQLITE_READONLY_DBMOVED
            || code == 1288  // SQLITE_READONLY_CANTINIT
            || code == 1544  // SQLITE_READONLY_DIRECTORY
    }

    /// The file could not be opened at all (missing directory, permissions, not a database).
    public var isUnopenable: Bool {
        guard let code = sqliteCode else { return false }
        return code == SQLITE_CANTOPEN || code == SQLITE_PERM || code == SQLITE_NOTADB || code == 23 // SQLITE_ACCESS (legacy)
    }

    /// The volume backing the database is full.
    public var isDiskFull: Bool {
        sqliteCode == SQLITE_FULL
    }
}

/// A very small, dependency free SQLite wrapper. All access is serialized by a recursive lock so the
/// store may be used from several isolation domains (UI, transfer queue, connection pool).
public final class SQLiteDatabase: @unchecked Sendable {
    public let path: String
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

    /// Opens the database. A read-only open lets Tauge show a catalog it cannot write
    /// (restricted sandbox, read-only volume) instead of falling back to an empty one.
    public init(path: String, readOnly: Bool = false, immutable: Bool = false) throws {
        self.path = path
        var h: OpaquePointer?
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var openPath = path
        if readOnly && immutable {
            // A read-only connection cannot create the WAL side files (-shm), so a plain
            // SQLITE_OPEN_READONLY handle fails every statement with "unable to open database
            // file". "immutable=1" tells SQLite the file cannot change and skips locking/WAL.
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
            openPath = URL(fileURLWithPath: path).absoluteString + "?immutable=1"
        } else if readOnly {
            // A plain read-only handle can still read a WAL left behind by another process,
            // as long as the -shm/-wal side files are writable.
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        }
        let status = sqlite3_open_v2(openPath, &h, flags, nil)
        guard status == SQLITE_OK, let opened = h else {
            let message = h.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let h { sqlite3_close_v2(h) }
            throw SQLiteError.openFailed(path, message, status)
        }
        handle = opened
        sqlite3_busy_timeout(opened, 5_000)
        if readOnly {
            // WAL switching and synchronous settings need a writable file; skip them.
            _ = try? execute("PRAGMA query_only=ON;")
        } else {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=NORMAL;")
            try execute("PRAGMA foreign_keys=ON;")
        }
    }

    /// Opens an existing catalog for reading. Prefers a regular read-only handle (which sees
    /// a WAL another process left behind) and falls back to "immutable" mode, where SQLite
    /// skips locking and side files entirely; the latter can ignore uncheckpointed WAL data,
    /// so it is only the fallback.
    public static func openForReading(path: String) throws -> SQLiteDatabase {
        if let database = try? SQLiteDatabase(path: path, readOnly: true), database.isUsable() {
            return database
        }
        return try SQLiteDatabase(path: path, readOnly: true, immutable: true)
    }

    /// True when a trivial statement can read the schema; opening a WAL database read-only
    /// can succeed while every statement fails with "unable to open database file".
    public func isUsable() -> Bool {
        ((try? scalarInt("SELECT count(*) FROM sqlite_master;")) ?? nil) != nil
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    public var userVersion: Int {
        (try? scalarInt("PRAGMA user_version;")) ?? 0
    }

    public func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version=\(version);")
    }

    @discardableResult
    public func execute(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteError.stepFailed(sql, errorMessage(), extendedCode())
        }
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLRow] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }

        var rows: [SQLRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw SQLiteError.stepFailed(sql, errorMessage(), extendedCode())
            }
            var row: SQLRow = [:]
            let columnCount = sqlite3_column_count(statement)
            for index in 0..<columnCount {
                guard let namePointer = sqlite3_column_name(statement, index) else { continue }
                let name = String(cString: namePointer)
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    row[name] = .int(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    row[name] = .double(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, index) {
                        row[name] = .text(String(cString: text))
                    } else {
                        row[name] = .null
                    }
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(statement, index) {
                        let count = Int(sqlite3_column_bytes(statement, index))
                        row[name] = .blob(Data(bytes: bytes, count: count))
                    } else {
                        row[name] = .blob(Data())
                    }
                default:
                    row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func scalarInt(_ sql: String, _ params: [SQLValue] = []) throws -> Int? {
        try query(sql, params).first?.values.compactMap { $0.int64 }.first.map(Int.init)
    }

    public func scalarString(_ sql: String, _ params: [SQLValue] = []) throws -> String? {
        try query(sql, params).first?.values.compactMap { $0.string }.first
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try execute("COMMIT;")
            return value
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Round-trips an empty write transaction so callers can tell a writable catalog from a
    /// read-only one before the user has typed anything. Opening a read-only file succeeds, so
    /// without this probe the failure only surfaces on the first INSERT.
    public func verifyWritable() throws {
        lock.lock()
        defer { lock.unlock() }
        // BEGIN IMMEDIATE alone is not enough: in WAL mode it only takes the writer lock
        // through the -shm file, so a read-only database passes and the failure only shows
        // up on the actual INSERT. The probe writes a scratch row and rolls it back.
        try execute("BEGIN IMMEDIATE;")
        do {
            _ = try execute("CREATE TABLE IF NOT EXISTS tauge_write_probe(value INTEGER);")
            _ = try execute("INSERT INTO tauge_write_probe(value) VALUES (1);")
            try execute("ROLLBACK;")
        } catch {
            _ = try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Writes a consistent snapshot of the database to `destination`, including committed rows
    /// that still live in the WAL file. Used by the "move catalog" recovery flow.
    public func backup(to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let escaped = destination.path.replacingOccurrences(of: "'", with: "''")
        try execute("VACUUM INTO '" + escaped + "';")
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer {
        guard let handle else {
            throw SQLiteError.openFailed(path, "database is closed", 0)
        }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw SQLiteError.prepareFailed(sql, errorMessage())
        }
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            let bindResult: Int32
            switch value {
            case .null:
                bindResult = sqlite3_bind_null(statement, index)
            case .int(let v):
                bindResult = sqlite3_bind_int64(statement, index, v)
            case .double(let v):
                bindResult = sqlite3_bind_double(statement, index, v)
            case .text(let v):
                bindResult = sqlite3_bind_text(statement, index, v, -1, sqliteTransient)
            case .blob(let data):
                bindResult = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), sqliteTransient)
                }
            }
            if bindResult != SQLITE_OK {
                sqlite3_finalize(statement)
                throw SQLiteError.bindFailed(sql, errorMessage())
            }
        }
        return statement
    }

    private func errorMessage() -> String {
        guard let handle else { return "database is closed" }
        return String(cString: sqlite3_errmsg(handle))
    }

    private func extendedCode() -> Int32 {
        guard let handle else { return 0 }
        return sqlite3_extended_errcode(handle)
    }
}
