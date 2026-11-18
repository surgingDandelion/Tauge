import Foundation

/// Persistence layer for groups, hosts, proxies, keys, transfers, settings and the workspace snapshot.
/// The schema follows PRD §9 with JSON columns for list-like fields so migrations stay cheap.
public final class HostStore: @unchecked Sendable {
    public let database: SQLiteDatabase
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    private static let schemaVersion = 3

    public init(database: SQLiteDatabase, createSchema: Bool = true) throws {
        self.database = database
        if createSchema {
            try migrate()
        }
    }

    public convenience init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try self.init(database: SQLiteDatabase(path: url.path))
    }

    public static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ShellX/shellx.sqlite")
    }

    // MARK: - Schema

    private func migrate() throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS groups (
            id TEXT PRIMARY KEY,
            parent_id TEXT,
            name TEXT NOT NULL,
            sort INTEGER NOT NULL DEFAULT 0,
            is_expanded INTEGER NOT NULL DEFAULT 1,
            defaults_json TEXT NOT NULL DEFAULT '{}'
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS hosts (
            id TEXT PRIMARY KEY,
            group_id TEXT,
            name TEXT NOT NULL,
            hostname TEXT NOT NULL DEFAULT '',
            port INTEGER NOT NULL DEFAULT 22,
            username TEXT NOT NULL DEFAULT '',
            auth_type TEXT NOT NULL DEFAULT 'password',
            key_id TEXT,
            identity_path TEXT,
            saves_password INTEGER NOT NULL DEFAULT 1,
            proxy_policy TEXT NOT NULL DEFAULT '{"kind":"inherit"}',
            jump_policy TEXT NOT NULL DEFAULT '{"kind":"inherit"}',
            term_type TEXT,
            encoding TEXT,
            start_dir TEXT,
            startup_command TEXT,
            keepalive INTEGER,
            reuse_conn INTEGER NOT NULL DEFAULT 1,
            tags TEXT NOT NULL DEFAULT '[]',
            color TEXT,
            notes TEXT NOT NULL DEFAULT '',
            default_upload_dir TEXT,
            logging INTEGER,
            sort INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            last_used_at REAL,
            use_count INTEGER NOT NULL DEFAULT 0,
            transport TEXT
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS proxies (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            type TEXT NOT NULL,
            host TEXT NOT NULL DEFAULT '',
            port INTEGER NOT NULL DEFAULT 8080,
            username TEXT NOT NULL DEFAULT '',
            saves_password INTEGER NOT NULL DEFAULT 1
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS private_keys (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            public_key TEXT NOT NULL DEFAULT '',
            fingerprint TEXT NOT NULL DEFAULT '',
            has_passphrase INTEGER NOT NULL DEFAULT 0,
            storage_ref TEXT
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS host_keys (
            host_port TEXT NOT NULL,
            key_type TEXT NOT NULL,
            fingerprint TEXT NOT NULL,
            public_key TEXT NOT NULL,
            first_seen REAL NOT NULL,
            PRIMARY KEY (host_port, key_type)
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS transfers (
            id TEXT PRIMARY KEY,
            host_id TEXT NOT NULL,
            direction TEXT NOT NULL,
            src TEXT NOT NULL,
            dst TEXT NOT NULL,
            size INTEGER NOT NULL DEFAULT 0,
            state TEXT NOT NULL,
            bytes_done INTEGER NOT NULL DEFAULT 0,
            error TEXT,
            updated_at REAL NOT NULL
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
        // Remembered SFTP folders per host: the most recent path is where the
        // pane reopens, the rest feed the "recent folders" menu.
        try database.execute("""
        CREATE TABLE IF NOT EXISTS sftp_history (
            host_id TEXT NOT NULL,
            path TEXT NOT NULL,
            last_used REAL NOT NULL,
            PRIMARY KEY (host_id, path)
        );
        """)
        // Terminal boards: named split workspaces, stored as JSON so the tree
        // shape can evolve without a migration.
        try database.execute("""
        CREATE TABLE IF NOT EXISTS boards (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            json TEXT NOT NULL,
            sort INTEGER NOT NULL DEFAULT 0
        );
        """)
        // Detected operating system per host, cached so the sidebar can draw the
        // right logo before the next login. Kept in its own table (instead of an
        // ALTER on hosts) so existing databases migrate with no column rewrites.
        try database.execute("""
        CREATE TABLE IF NOT EXISTS host_platform (
            host_id TEXT PRIMARY KEY,
            platform TEXT NOT NULL,
            detail TEXT NOT NULL DEFAULT '',
            detected_at REAL NOT NULL
        );
        """)
        // Hosts saved before the compatibility transport existed default to the
        // built-in stack; the ALTER keeps existing databases readable.
        try ensureColumn(table: "hosts", column: "transport", definition: "TEXT")
        try database.execute("CREATE INDEX IF NOT EXISTS idx_hosts_group ON hosts(group_id);")
        try database.execute("CREATE INDEX IF NOT EXISTS idx_transfers_host ON transfers(host_id);")
        if database.userVersion < Self.schemaVersion {
            try database.setUserVersion(Self.schemaVersion)
        }
    }

    /// Adds a column to an existing table when it is missing, so databases
    /// created by older builds pick up new fields without a full migration.
    private func ensureColumn(table: String, column: String, definition: String) throws {
        let rows = try database.query("PRAGMA table_info(\(table));")
        let names = Set(rows.compactMap { $0["name"]?.string })
        guard !names.contains(column) else { return }
        try database.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
    }

    // MARK: - Groups

    public func groups() throws -> [HostGroup] {
        let rows = try database.query("SELECT * FROM groups ORDER BY sort ASC, name ASC;")
        return rows.compactMap { row -> HostGroup? in
            guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
                  let name = row["name"]?.string else { return nil }
            let defaults: GroupDefaults = decode(row["defaults_json"]?.string, as: GroupDefaults.self) ?? .empty
            return HostGroup(
                id: id,
                parentID: row["parent_id"]?.string.flatMap(UUID.init(uuidString:)),
                name: name,
                sortIndex: row["sort"]?.int ?? 0,
                isExpanded: row["is_expanded"]?.bool ?? true,
                defaults: defaults
            )
        }
    }

    public func save(group: HostGroup) throws {
        let defaultsJSON = encodeToString(group.defaults) ?? "{}"
        try database.execute("""
        INSERT INTO groups (id, parent_id, name, sort, is_expanded, defaults_json)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            parent_id = excluded.parent_id,
            name = excluded.name,
            sort = excluded.sort,
            is_expanded = excluded.is_expanded,
            defaults_json = excluded.defaults_json;
        """, [
            .text(group.id.uuidString),
            SQLValue(group.parentID),
            .text(group.name),
            .int(Int64(group.sortIndex)),
            .int(group.isExpanded ? 1 : 0),
            .text(defaultsJSON),
        ])
    }

    public func setGroupExpanded(id: UUID, expanded: Bool) throws {
        try database.execute("UPDATE groups SET is_expanded = ? WHERE id = ?;", [.int(expanded ? 1 : 0), .text(id.uuidString)])
    }

    /// Deletes a group, all descendant groups, and every host contained in them. Returns the host ids that were removed.
    @discardableResult
    public func deleteGroup(id: UUID) throws -> [UUID] {
        let rows = try database.query("""
        WITH RECURSIVE sub(id) AS (
            SELECT id FROM groups WHERE id = ?
            UNION ALL
            SELECT g.id FROM groups g JOIN sub ON g.parent_id = sub.id
        )
        SELECT id FROM sub;
        """, [.text(id.uuidString)])
        let groupIDs = rows.compactMap { $0["id"]?.string }
        guard !groupIDs.isEmpty else { return [] }

        var removedHosts: [UUID] = []
        try database.transaction {
            let placeholders = Array(repeating: "?", count: groupIDs.count).joined(separator: ",")
            let params: [SQLValue] = groupIDs.map { .text($0) }
            let hostRows = try database.query("SELECT id FROM hosts WHERE group_id IN (\(placeholders));", params)
            removedHosts = hostRows.compactMap { $0["id"]?.string.flatMap(UUID.init(uuidString:)) }
            try database.execute("DELETE FROM hosts WHERE group_id IN (\(placeholders));", params)
            try database.execute("DELETE FROM groups WHERE id IN (\(placeholders));", params)
        }
        return removedHosts
    }

    // MARK: - Hosts

    public func hosts() throws -> [SSHHost] {
        let rows = try database.query("SELECT * FROM hosts ORDER BY sort ASC, name ASC;")
        return rows.compactMap(mapHost)
    }

    public func host(id: UUID) throws -> SSHHost? {
        let rows = try database.query("SELECT * FROM hosts WHERE id = ?;", [.text(id.uuidString)])
        return rows.first.flatMap(mapHost)
    }

    public func save(host: SSHHost) throws {
        var updated = host
        updated.updatedAt = Date()
        let proxyPolicy = encodeToString(updated.proxyPolicy) ?? "{\"kind\":\"inherit\"}"
        let jumpPolicy = encodeToString(updated.jumpPolicy) ?? "{\"kind\":\"inherit\"}"
        let tags = encodeToString(updated.tags) ?? "[]"
        try database.execute("""
        INSERT INTO hosts (id, group_id, name, hostname, port, username, auth_type, key_id, identity_path,
            saves_password, proxy_policy, jump_policy, term_type, encoding, start_dir, startup_command,
            keepalive, reuse_conn, tags, color, notes, default_upload_dir, logging, sort, created_at,
            updated_at, last_used_at, use_count, transport)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            group_id = excluded.group_id,
            name = excluded.name,
            hostname = excluded.hostname,
            port = excluded.port,
            username = excluded.username,
            auth_type = excluded.auth_type,
            key_id = excluded.key_id,
            identity_path = excluded.identity_path,
            saves_password = excluded.saves_password,
            proxy_policy = excluded.proxy_policy,
            jump_policy = excluded.jump_policy,
            term_type = excluded.term_type,
            encoding = excluded.encoding,
            start_dir = excluded.start_dir,
            startup_command = excluded.startup_command,
            keepalive = excluded.keepalive,
            reuse_conn = excluded.reuse_conn,
            tags = excluded.tags,
            color = excluded.color,
            notes = excluded.notes,
            default_upload_dir = excluded.default_upload_dir,
            logging = excluded.logging,
            sort = excluded.sort,
            updated_at = excluded.updated_at,
            use_count = excluded.use_count,
            transport = excluded.transport;
        """, hostValues(updated, proxyPolicy: proxyPolicy, jumpPolicy: jumpPolicy, tags: tags))
    }

    private func hostValues(_ host: SSHHost, proxyPolicy: String, jumpPolicy: String, tags: String) -> [SQLValue] {
        var values: [SQLValue] = []
        values.append(.text(host.id.uuidString))
        values.append(SQLValue(host.groupID))
        values.append(.text(host.name))
        values.append(.text(host.hostname))
        values.append(.int(Int64(host.port)))
        values.append(.text(host.username))
        values.append(.text(host.authMethod.rawValue))
        values.append(SQLValue(host.keyID))
        values.append(SQLValue(host.identityFilePath))
        values.append(.int(host.savesPassword ? 1 : 0))
        values.append(.text(proxyPolicy))
        values.append(.text(jumpPolicy))
        values.append(SQLValue(host.terminalType))
        values.append(SQLValue(host.encoding?.rawValue))
        values.append(SQLValue(host.startDirectory))
        values.append(SQLValue(host.startupCommand))
        values.append(SQLValue(host.keepaliveSeconds))
        values.append(.int(host.reuseConnection ? 1 : 0))
        values.append(.text(tags))
        values.append(SQLValue(host.colorHex))
        values.append(SQLValue(host.notes))
        values.append(SQLValue(host.defaultUploadDirectory))
        values.append(SQLValue(host.sessionLoggingEnabled.map { $0 ? 1 : 0 }))
        values.append(.int(Int64(host.sortIndex)))
        values.append(.double(host.createdAt.timeIntervalSince1970))
        values.append(.double(host.updatedAt.timeIntervalSince1970))
        values.append(SQLValue(host.lastUsedAt?.timeIntervalSince1970))
        values.append(.int(Int64(host.useCount)))
        values.append(SQLValue(host.transport?.rawValue))
        return values
    }

    public func deleteHost(id: UUID) throws {
        try database.execute("DELETE FROM hosts WHERE id = ?;", [.text(id.uuidString)])
        try database.execute("DELETE FROM sftp_history WHERE host_id = ?;", [.text(id.uuidString)])
        try database.execute("DELETE FROM host_platform WHERE host_id = ?;", [.text(id.uuidString)])
    }

    // MARK: - Detected platform

    /// Every cached detection, keyed by host so the UI can look one up per row.
    public func hostPlatforms() throws -> [UUID: HostPlatformInfo] {
        let rows = try database.query("SELECT * FROM host_platform;")
        var result: [UUID: HostPlatformInfo] = [:]
        for row in rows {
            guard let id = row["host_id"]?.string.flatMap(UUID.init(uuidString:)),
                  let platform = row["platform"]?.string.flatMap(HostPlatform.init(rawValue:)) else { continue }
            result[id] = HostPlatformInfo(
                platform: platform,
                detail: row["detail"]?.string ?? "",
                detectedAt: Date(timeIntervalSince1970: row["detected_at"]?.double ?? 0)
            )
        }
        return result
    }

    public func setHostPlatform(_ info: HostPlatformInfo, for hostID: UUID) throws {
        try database.execute("""
        INSERT INTO host_platform (host_id, platform, detail, detected_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(host_id) DO UPDATE SET
            platform = excluded.platform,
            detail = excluded.detail,
            detected_at = excluded.detected_at;
        """, [
            .text(hostID.uuidString),
            .text(info.platform.rawValue),
            .text(info.detail),
            .double(info.detectedAt.timeIntervalSince1970),
        ])
    }

    /// Forgets a detection so the next login probes the host again.
    public func clearHostPlatform(for hostID: UUID) throws {
        try database.execute("DELETE FROM host_platform WHERE host_id = ?;", [.text(hostID.uuidString)])
    }

    public func recordConnection(hostID: UUID) throws {
        try database.execute("""
        UPDATE hosts SET last_used_at = ?, use_count = use_count + 1 WHERE id = ?;
        """, [.double(Date().timeIntervalSince1970), .text(hostID.uuidString)])
    }

    public func recentHosts(limit: Int = 20) throws -> [SSHHost] {
        let rows = try database.query("""
        SELECT * FROM hosts WHERE last_used_at IS NOT NULL ORDER BY last_used_at DESC LIMIT ?;
        """, [.int(Int64(limit))])
        return rows.compactMap(mapHost)
    }

    private func mapHost(_ row: SQLRow) -> SSHHost? {
        guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
              let name = row["name"]?.string else { return nil }
        let auth = row["auth_type"]?.string.flatMap(AuthMethod.init(rawValue:)) ?? .password
        let proxyPolicy: ProxyPolicy = decode(row["proxy_policy"]?.string, as: ProxyPolicy.self) ?? .inherit
        let jumpPolicy: JumpPolicy = decode(row["jump_policy"]?.string, as: JumpPolicy.self) ?? .inherit
        let tags: [String] = decode(row["tags"]?.string, as: [String].self) ?? []
        let createdAt = Date(timeIntervalSince1970: row["created_at"]?.double ?? 0)
        let updatedAt = Date(timeIntervalSince1970: row["updated_at"]?.double ?? 0)
        let lastUsed = row["last_used_at"]?.double.map { Date(timeIntervalSince1970: $0) }
        return SSHHost(
            id: id,
            groupID: row["group_id"]?.string.flatMap(UUID.init(uuidString:)),
            name: name,
            hostname: row["hostname"]?.string ?? "",
            port: row["port"]?.int ?? 22,
            username: row["username"]?.string ?? "",
            authMethod: auth,
            keyID: row["key_id"]?.string.flatMap(UUID.init(uuidString:)),
            identityFilePath: nilIfEmpty(row["identity_path"]?.string),
            savesPassword: row["saves_password"]?.bool ?? true,
            proxyPolicy: proxyPolicy,
            jumpPolicy: jumpPolicy,
            terminalType: nilIfEmpty(row["term_type"]?.string),
            encoding: row["encoding"]?.string.flatMap(TextEncodingKind.init(rawValue:)),
            startDirectory: nilIfEmpty(row["start_dir"]?.string),
            startupCommand: nilIfEmpty(row["startup_command"]?.string),
            keepaliveSeconds: row["keepalive"]?.int,
            reuseConnection: row["reuse_conn"]?.bool ?? true,
            tags: tags,
            colorHex: nilIfEmpty(row["color"]?.string),
            notes: row["notes"]?.string ?? "",
            defaultUploadDirectory: nilIfEmpty(row["default_upload_dir"]?.string),
            sessionLoggingEnabled: row["logging"]?.bool,
            sortIndex: row["sort"]?.int ?? 0,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastUsedAt: lastUsed,
            useCount: row["use_count"]?.int ?? 0,
            transport: row["transport"]?.string.flatMap(HostTransport.init(rawValue:))
        )
    }

    // MARK: - Proxies

    public func proxies() throws -> [ProxyConfig] {
        let rows = try database.query("SELECT * FROM proxies ORDER BY name ASC;")
        return rows.compactMap { row in
            guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
                  let name = row["name"]?.string,
                  let type = row["type"]?.string.flatMap(ProxyType.init(rawValue:)) else { return nil }
            return ProxyConfig(
                id: id,
                name: name,
                type: type,
                host: row["host"]?.string ?? "",
                port: row["port"]?.int ?? type.defaultPort,
                username: row["username"]?.string ?? "",
                savesPassword: row["saves_password"]?.bool ?? true
            )
        }
    }

    public func save(proxy: ProxyConfig) throws {
        try database.execute("""
        INSERT INTO proxies (id, name, type, host, port, username, saves_password)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            type = excluded.type,
            host = excluded.host,
            port = excluded.port,
            username = excluded.username,
            saves_password = excluded.saves_password;
        """, [
            .text(proxy.id.uuidString),
            .text(proxy.name),
            .text(proxy.type.rawValue),
            .text(proxy.host),
            .int(Int64(proxy.port)),
            .text(proxy.username),
            .int(proxy.savesPassword ? 1 : 0),
        ])
    }

    /// Removes the proxy and rewrites every host/group that referenced it to inherit.
    public func deleteProxy(id: UUID) throws {
        try database.transaction {
            try database.execute("DELETE FROM proxies WHERE id = ?;", [.text(id.uuidString)])
            let hosts = try self.hosts()
            for var host in hosts {
                if host.proxyPolicy.proxyID == id {
                    host.proxyPolicy = .inherit
                    try self.save(host: host)
                }
            }
            let groups = try self.groups()
            for var group in groups {
                if group.defaults.proxyPolicy.proxyID == id {
                    group.defaults.proxyPolicy = .inherit
                    try self.save(group: group)
                }
            }
        }
    }

    // MARK: - Private keys

    public func privateKeys() throws -> [PrivateKeyRecord] {
        let rows = try database.query("SELECT * FROM private_keys ORDER BY name ASC;")
        return rows.compactMap { row in
            guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
                  let name = row["name"]?.string else { return nil }
            return PrivateKeyRecord(
                id: id,
                name: name,
                publicKeyOpenSSH: row["public_key"]?.string ?? "",
                fingerprintSHA256: row["fingerprint"]?.string ?? "",
                hasPassphrase: row["has_passphrase"]?.bool ?? false,
                storageRef: row["storage_ref"]?.string
            )
        }
    }

    public func save(privateKey: PrivateKeyRecord) throws {
        try database.execute("""
        INSERT INTO private_keys (id, name, public_key, fingerprint, has_passphrase, storage_ref)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            public_key = excluded.public_key,
            fingerprint = excluded.fingerprint,
            has_passphrase = excluded.has_passphrase,
            storage_ref = excluded.storage_ref;
        """, [
            .text(privateKey.id.uuidString),
            .text(privateKey.name),
            .text(privateKey.publicKeyOpenSSH),
            .text(privateKey.fingerprintSHA256),
            .int(privateKey.hasPassphrase ? 1 : 0),
            SQLValue(privateKey.storageRef),
        ])
    }

    public func deletePrivateKey(id: UUID) throws {
        try database.execute("DELETE FROM private_keys WHERE id = ?;", [.text(id.uuidString)])
        try database.execute("UPDATE hosts SET key_id = NULL WHERE key_id = ?;", [.text(id.uuidString)])
    }

    // MARK: - Known hosts

    public func hostKeys() throws -> [KnownHostEntry] {
        let rows = try database.query("SELECT * FROM host_keys ORDER BY host_port ASC;")
        return rows.compactMap { row in
            guard let hostPort = row["host_port"]?.string,
                  let keyType = row["key_type"]?.string,
                  let fingerprint = row["fingerprint"]?.string,
                  let publicKey = row["public_key"]?.string else { return nil }
            return KnownHostEntry(
                hostPort: hostPort,
                keyType: keyType,
                fingerprintSHA256: fingerprint,
                publicKeyBase64: publicKey,
                firstSeen: Date(timeIntervalSince1970: row["first_seen"]?.double ?? 0)
            )
        }
    }

    public func hostKey(hostPort: String, keyType: String) throws -> KnownHostEntry? {
        let rows = try database.query("SELECT * FROM host_keys WHERE host_port = ? AND key_type = ?;", [.text(hostPort), .text(keyType)])
        return rows.first.flatMap { row in
            guard let fingerprint = row["fingerprint"]?.string, let publicKey = row["public_key"]?.string else { return nil }
            return KnownHostEntry(
                hostPort: hostPort,
                keyType: keyType,
                fingerprintSHA256: fingerprint,
                publicKeyBase64: publicKey,
                firstSeen: Date(timeIntervalSince1970: row["first_seen"]?.double ?? 0)
            )
        }
    }

    public func save(hostKey: KnownHostEntry) throws {
        try database.execute("""
        INSERT INTO host_keys (host_port, key_type, fingerprint, public_key, first_seen)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(host_port, key_type) DO UPDATE SET
            fingerprint = excluded.fingerprint,
            public_key = excluded.public_key;
        """, [
            .text(hostKey.hostPort),
            .text(hostKey.keyType),
            .text(hostKey.fingerprintSHA256),
            .text(hostKey.publicKeyBase64),
            .double(hostKey.firstSeen.timeIntervalSince1970),
        ])
    }

    public func deleteHostKey(hostPort: String, keyType: String) throws {
        try database.execute("DELETE FROM host_keys WHERE host_port = ? AND key_type = ?;", [.text(hostPort), .text(keyType)])
    }

    public func deleteHostKeys(hostPort: String) throws {
        try database.execute("DELETE FROM host_keys WHERE host_port = ?;", [.text(hostPort)])
    }

    // MARK: - Transfers

    public func transfers() throws -> [TransferRecord] {
        let rows = try database.query("SELECT * FROM transfers ORDER BY updated_at DESC;")
        return rows.compactMap { row in
            guard let id = row["id"]?.string.flatMap(UUID.init(uuidString:)),
                  let hostID = row["host_id"]?.string.flatMap(UUID.init(uuidString:)),
                  let direction = row["direction"]?.string.flatMap(TransferDirection.init(rawValue:)),
                  let state = row["state"]?.string.flatMap(TransferState.init(rawValue:)),
                  let src = row["src"]?.string, let dst = row["dst"]?.string else { return nil }
            return TransferRecord(
                id: id,
                hostID: hostID,
                direction: direction,
                sourcePath: src,
                destinationPath: dst,
                totalBytes: row["size"]?.int64 ?? 0,
                completedBytes: row["bytes_done"]?.int64 ?? 0,
                state: state,
                errorMessage: row["error"]?.string,
                updatedAt: Date(timeIntervalSince1970: row["updated_at"]?.double ?? 0)
            )
        }
    }

    public func save(transfer: TransferRecord) throws {
        try database.execute("""
        INSERT INTO transfers (id, host_id, direction, src, dst, size, state, bytes_done, error, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            state = excluded.state,
            size = excluded.size,
            bytes_done = excluded.bytes_done,
            error = excluded.error,
            updated_at = excluded.updated_at;
        """, [
            .text(transfer.id.uuidString),
            .text(transfer.hostID.uuidString),
            .text(transfer.direction.rawValue),
            .text(transfer.sourcePath),
            .text(transfer.destinationPath),
            .int(transfer.totalBytes),
            .text(transfer.state.rawValue),
            .int(transfer.completedBytes),
            SQLValue(transfer.errorMessage),
            .double(transfer.updatedAt.timeIntervalSince1970),
        ])
    }

    public func deleteTransfer(id: UUID) throws {
        try database.execute("DELETE FROM transfers WHERE id = ?;", [.text(id.uuidString)])
    }

    public func clearFinishedTransfers() throws {
        try database.execute("DELETE FROM transfers WHERE state IN ('completed', 'cancelled');")
    }

    // MARK: - SFTP folder history

    /// Records a visited folder. Paths are visited repeatedly, so this is an
    /// upsert that only refreshes the timestamp.
    public func recordSFTPPath(hostID: UUID, path: String) throws {
        guard !path.isEmpty else { return }
        try database.execute("""
        INSERT INTO sftp_history (host_id, path, last_used) VALUES (?, ?, ?)
        ON CONFLICT(host_id, path) DO UPDATE SET last_used = excluded.last_used;
        """, [.text(hostID.uuidString), .text(path), .double(Date().timeIntervalSince1970)])
        // Keep the table bounded: 50 folders per host is plenty for a menu.
        try database.execute("""
        DELETE FROM sftp_history
        WHERE host_id = ? AND path NOT IN (
            SELECT path FROM sftp_history WHERE host_id = ? ORDER BY last_used DESC LIMIT 50
        );
        """, [.text(hostID.uuidString), .text(hostID.uuidString)])
    }

    public func sftpHistory(hostID: UUID, limit: Int = 12) throws -> [SFTPHistoryEntry] {
        let rows = try database.query("""
        SELECT path, last_used FROM sftp_history WHERE host_id = ? ORDER BY last_used DESC LIMIT ?;
        """, [.text(hostID.uuidString), .int(Int64(limit))])
        return rows.compactMap { row in
            guard let path = row["path"]?.string else { return nil }
            let date = Date(timeIntervalSince1970: row["last_used"]?.double ?? 0)
            return SFTPHistoryEntry(hostID: hostID, path: path, lastUsed: date)
        }
    }

    public func lastSFTPPath(hostID: UUID) throws -> String? {
        try database.scalarString("""
        SELECT path FROM sftp_history WHERE host_id = ? ORDER BY last_used DESC LIMIT 1;
        """, [.text(hostID.uuidString)])
    }

    public func clearSFTPHistory(hostID: UUID) throws {
        try database.execute("DELETE FROM sftp_history WHERE host_id = ?;", [.text(hostID.uuidString)])
    }

    // MARK: - Terminal boards

    public func boards() throws -> [BoardDefinition] {
        let rows = try database.query("SELECT json FROM boards ORDER BY sort ASC, name ASC;")
        return rows.compactMap { row in
            guard let raw = row["json"]?.string, let data = raw.data(using: .utf8) else { return nil }
            return try? jsonDecoder.decode(BoardDefinition.self, from: data)
        }
    }

    public func board(id: UUID) throws -> BoardDefinition? {
        guard let raw = try database.scalarString("SELECT json FROM boards WHERE id = ?;", [.text(id.uuidString)]),
              let data = raw.data(using: .utf8) else { return nil }
        return try? jsonDecoder.decode(BoardDefinition.self, from: data)
    }

    public func save(board: BoardDefinition, sortIndex: Int = 0) throws {
        guard let data = try? jsonEncoder.encode(board) else { return }
        try database.execute("""
        INSERT INTO boards (id, name, json, sort) VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET name = excluded.name, json = excluded.json, sort = excluded.sort;
        """, [.text(board.id.uuidString),
              .text(board.name),
              .text(String(decoding: data, as: UTF8.self)),
              .int(Int64(sortIndex))])
    }

    public func deleteBoard(id: UUID) throws {
        try database.execute("DELETE FROM boards WHERE id = ?;", [.text(id.uuidString)])
    }

    // MARK: - Settings / workspace

    public func setting(key: String) throws -> String? {
        try database.scalarString("SELECT value FROM settings WHERE key = ?;", [.text(key)])
    }

    public func setSetting(key: String, value: String) throws {
        try database.execute("""
        INSERT INTO settings (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """, [.text(key), .text(value)])
    }

    public func settings() throws -> AppSettings {
        guard let raw = try setting(key: "app.settings"), let data = raw.data(using: .utf8) else { return AppSettings() }
        return (try? jsonDecoder.decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    public func save(settings: AppSettings) throws {
        guard let data = try? jsonEncoder.encode(settings) else { return }
        try setSetting(key: "app.settings", value: String(decoding: data, as: UTF8.self))
    }

    public func workspaceSnapshot() throws -> WorkspaceSnapshot? {
        guard let raw = try setting(key: "workspace.snapshot"), let data = raw.data(using: .utf8) else { return nil }
        return try? jsonDecoder.decode(WorkspaceSnapshot.self, from: data)
    }

    public func save(workspace: WorkspaceSnapshot) throws {
        guard let data = try? jsonEncoder.encode(workspace) else { return }
        try setSetting(key: "workspace.snapshot", value: String(decoding: data, as: UTF8.self))
    }

    /// Export the whole catalog as JSON (credentials excluded by design).
    public func exportCatalog() throws -> Data {
        struct Catalog: Codable {
            var groups: [HostGroup]
            var hosts: [SSHHost]
            var proxies: [ProxyConfig]
            var keys: [PrivateKeyRecord]
            var version: Int
        }
        let catalog = Catalog(groups: try groups(), hosts: try hosts(), proxies: try proxies(), keys: try privateKeys(), version: 1)
        return try jsonEncoder.encode(catalog)
    }

    /// Merge an imported JSON document into the catalog. Existing rows are overwritten when ids collide.
    public func importCatalog(data: Data) throws {
        struct Catalog: Codable {
            var groups: [HostGroup]
            var hosts: [SSHHost]
            var proxies: [ProxyConfig]?
            var keys: [PrivateKeyRecord]?
            var version: Int?
        }
        let catalog = try jsonDecoder.decode(Catalog.self, from: data)
        try database.transaction {
            for proxy in catalog.proxies ?? [] { try self.save(proxy: proxy) }
            for group in catalog.groups { try self.save(group: group) }
            for key in catalog.keys ?? [] { try self.save(privateKey: key) }
            for host in catalog.hosts { try self.save(host: host) }
        }
    }

    // MARK: - Helpers

    private func encodeToString<T: Encodable>(_ value: T) -> String? {
        guard let data = try? jsonEncoder.encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func decode<T: Decodable>(_ raw: String?, as type: T.Type) -> T? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? jsonDecoder.decode(type, from: data)
    }

    private func nilIfEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
