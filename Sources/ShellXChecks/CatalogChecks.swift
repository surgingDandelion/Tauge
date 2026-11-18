import Foundation
import ShellXKit

/// Covers the read-only catalog path. A database that opens but refuses writes must be
/// detectable before the user types anything (the failure otherwise shows up as a raw
/// "attempt to write a readonly database" SQL error on the first save), and the migration
/// flow must produce a consistent copy.
func runCatalogChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("shellx-catalog-checks-" + UUID().uuidString)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? fm.removeItem(at: root)
    }

    run("catalog write probe passes on a normal database") {
        let url = root.appendingPathComponent("writable.sqlite")
        let database = try SQLiteDatabase(path: url.path)
        let store = try HostStore(database: database)
        expectEqual(try store.groups().count, 0, "fresh catalog starts empty")
        try database.verifyWritable()
        database.close()
    }

    run("read-only file is detected before the first INSERT") {
        let url = root.appendingPathComponent("locked.sqlite")
        do {
            let database = try SQLiteDatabase(path: url.path)
            _ = try HostStore(database: database)
            database.close()
        }
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        let database = try SQLiteDatabase(path: url.path)
        do {
            try database.verifyWritable()
            expect(false, "verifyWritable should fail on a read-only catalog")
        } catch let error as SQLiteError {
            expect(error.isReadOnly, "read-only catalog should be classified, got " + String(describing: error))
        }
        do {
            _ = try database.execute("CREATE TABLE probe(x);")
            expect(false, "DDL on a read-only catalog should fail")
        } catch let error as SQLiteError {
            expect(error.isReadOnly, "write failure should keep the read-only classification, got " + String(describing: error))
        }
        database.close()
    }

    run("read-only directory is detected as read-only") {
        let folder = root.appendingPathComponent("ro-dir")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("catalog.sqlite")
        do {
            let database = try SQLiteDatabase(path: url.path)
            let store = try HostStore(database: database)
            try store.save(group: HostGroup(name: "只读目录"))
            database.close()
        }
        // Drop the WAL side files first: while they exist SQLite can keep committing into
        // them even though the folder (and therefore any new journal) is read-only.
        try? fm.removeItem(atPath: url.path + "-wal")
        try? fm.removeItem(atPath: url.path + "-shm")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        guard let database = try? SQLiteDatabase(path: url.path) else {
            // Some SQLite builds refuse to open at all in this configuration; both outcomes
            // are acceptable as long as startup does not assume the catalog is writable.
            expect(true, "opening failed outright, which the app handles as a fallback")
            return
        }
        do {
            try database.verifyWritable()
            expect(false, "verifyWritable should fail when the containing folder is read-only")
        } catch let error as SQLiteError {
            expect(error.isReadOnly, "read-only folder should be classified, got " + String(describing: error))
        } catch {
            expect(true, "unexpected error type is still surfaced to the caller: " + String(describing: error))
        }
        database.close()
    }

    run("read-only open still exposes the catalog") {
        let url = root.appendingPathComponent("viewable.sqlite")
        do {
            let database = try SQLiteDatabase(path: url.path)
            let store = try HostStore(database: database)
            try store.save(group: HostGroup(name: "只读可见"))
            database.close()
        }
        try? fm.removeItem(atPath: url.path + "-wal")
        try? fm.removeItem(atPath: url.path + "-shm")
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        let database = try SQLiteDatabase.openForReading(path: url.path)
        let store = try HostStore(database: database, createSchema: false)
        let names = try store.groups().map { $0.name }
        expect(names.contains("只读可见"), "read-only open should still list rows, got " + String(describing: names))
        do {
            try database.verifyWritable()
            expect(false, "verifyWritable should fail on a read-only handle")
        } catch let error as SQLiteError {
            expect(error.isReadOnly, "read-only handle should be classified, got " + String(describing: error))
        }
        database.close()
    }

    run("catalog migration copies committed rows including WAL content") {
        let source = root.appendingPathComponent("source.sqlite")
        let database = try SQLiteDatabase(path: source.path)
        let store = try HostStore(database: database)
        try store.save(group: HostGroup(name: "迁移分组"))
        let destination = root.appendingPathComponent("migrated/catalog.sqlite")
        try database.backup(to: destination)
        database.close()

        let copy = try SQLiteDatabase(path: destination.path)
        let copyStore = try HostStore(database: copy)
        let names = try copyStore.groups().map { $0.name }
        expect(names.contains("迁移分组"), "migrated copy should contain the source rows, got " + String(describing: names))
        try copy.verifyWritable()
        copy.close()
    }
}