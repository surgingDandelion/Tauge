import Foundation

/// One Host block from ssh_config. Options that are absent are nil so that
/// precedence across matching blocks can be resolved by the caller.
public struct SSHConfigHost: Equatable, Sendable {
    public var patterns: [String]
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFiles: [String]
    public var proxyJump: String?
    public var proxyCommand: String?
    public var serverAliveInterval: Int?

    public init(patterns: [String],
                hostName: String? = nil,
                user: String? = nil,
                port: Int? = nil,
                identityFiles: [String] = [],
                proxyJump: String? = nil,
                proxyCommand: String? = nil,
                serverAliveInterval: Int? = nil) {
        self.patterns = patterns
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFiles = identityFiles
        self.proxyJump = proxyJump
        self.proxyCommand = proxyCommand
        self.serverAliveInterval = serverAliveInterval
    }

    public var concreteAliases: [String] {
        patterns.filter { pattern in
            !pattern.contains("*") && !pattern.contains("?") && !pattern.hasPrefix("!")
        }
    }
}

public enum SSHConfigError: Error, LocalizedError {
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path): return "Cannot read SSH config at \(path)"
        }
    }
}

public enum SSHConfigParser {
    public static func defaultConfigPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.ssh/config"
    }

    public static func load(path: String? = nil, depth: Int = 0) throws -> [SSHConfigHost] {
        let configPath = path ?? defaultConfigPath()
        guard let data = FileManager.default.contents(atPath: configPath) else {
            if depth == 0 { return [] }
            throw SSHConfigError.unreadable(configPath)
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return parse(text, baseDirectory: (configPath as NSString).deletingLastPathComponent, depth: depth)
    }

    public static func parse(_ text: String,
                             baseDirectory: String = "",
                             depth: Int = 0) -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []
        var current: SSHConfigHost?

        func flush() {
            if let host = current { hosts.append(host) }
            current = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let (key, value) = splitKeyValue(line) else { continue }
            let lowerKey = key.lowercased()

            if lowerKey == "include" {
                flush()
                if depth < 8 {
                    let expanded = expandTilde(value, relativeTo: baseDirectory)
                    for pattern in expanded {
                        let matches = globPaths(pattern)
                        for match in matches {
                            if let included = try? load(path: match, depth: depth + 1) {
                                hosts.append(contentsOf: included)
                            }
                        }
                    }
                }
                continue
            }

            if lowerKey == "match" {
                flush()
                continue
            }

            if lowerKey == "host" {
                flush()
                let patterns = splitWords(value)
                current = SSHConfigHost(patterns: patterns)
                continue
            }

            guard current != nil else { continue }

            switch lowerKey {
            case "hostname":
                if current?.hostName == nil { current?.hostName = value }
            case "user":
                if current?.user == nil { current?.user = value }
            case "port":
                if current?.port == nil, let port = Int(value), port > 0, port < 65536 { current?.port = port }
            case "identityfile":
                current?.identityFiles.append(expandTilde(value, relativeTo: baseDirectory).first ?? value)
            case "proxyjump":
                if current?.proxyJump == nil { current?.proxyJump = value }
            case "proxycommand":
                if current?.proxyCommand == nil { current?.proxyCommand = value }
            case "serveraliveinterval":
                if current?.serverAliveInterval == nil, let interval = Int(value) { current?.serverAliveInterval = interval }
            default:
                break
            }
        }
        flush()
        return hosts
    }

    /// OpenSSH semantics: the first obtained value for each option wins across
    /// all matching Host blocks, in file order.
    public static func effective(for alias: String, in hosts: [SSHConfigHost]) -> SSHConfigHost? {
        let matching = hosts.filter { host in host.patterns.contains { match(pattern: $0, alias: alias) } }
        guard !matching.isEmpty else { return nil }
        var result = SSHConfigHost(patterns: [alias])
        var found = false
        for host in matching {
            if result.hostName == nil, let value = host.hostName { result.hostName = value; found = true }
            if result.user == nil, let value = host.user { result.user = value; found = true }
            if result.port == nil, let value = host.port { result.port = value; found = true }
            if result.identityFiles.isEmpty, !host.identityFiles.isEmpty { result.identityFiles = host.identityFiles; found = true }
            if result.proxyJump == nil, let value = host.proxyJump { result.proxyJump = value; found = true }
            if result.proxyCommand == nil, let value = host.proxyCommand { result.proxyCommand = value; found = true }
            if result.serverAliveInterval == nil, let value = host.serverAliveInterval { result.serverAliveInterval = value; found = true }
        }
        return found ? result : nil
    }

    public static func match(pattern: String, alias: String) -> Bool {
        if pattern.hasPrefix("!") { return false }
        return fnmatch(pattern, alias, 0) == 0
    }

    static func stripComment(_ line: String) -> String {
        var inQuotes = false
        var result = ""
        for character in line {
            if character == "\"" { inQuotes.toggle() }
            if character == "#" && !inQuotes { break }
            result.append(character)
        }
        return result
    }

    static func splitKeyValue(_ line: String) -> (String, String)? {
        if let firstSpace = line.firstIndex(where: { $0 == " " || $0 == "=" || $0 == "\t" }) {
            let key = String(line[line.startIndex..<firstSpace]).trimmingCharacters(in: .whitespaces)
            var remainder = String(line[line.index(after: firstSpace)...]).trimmingCharacters(in: .whitespaces)
            if remainder.hasPrefix("=") { remainder = String(remainder.dropFirst()).trimmingCharacters(in: .whitespaces) }
            guard !key.isEmpty, !remainder.isEmpty else { return nil }
            return (key, unquote(remainder))
        }
        return nil
    }

    static func unquote(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    static func splitWords(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { unquote(String($0)) }
    }

    static func expandTilde(_ path: String, relativeTo baseDirectory: String) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var expanded = path
        if expanded == "~" { expanded = home }
        else if expanded.hasPrefix("~/") { expanded = home + String(expanded.dropFirst()) }
        if !expanded.hasPrefix("/") && !baseDirectory.isEmpty {
            expanded = baseDirectory + "/" + expanded
        }
        return splitWords(expanded)
    }

    static func globPaths(_ pattern: String) -> [String] {
        let files = (pattern as NSString).expandingTildeInPath
        let directory = (files as NSString).deletingLastPathComponent
        let namePattern = (files as NSString).lastPathComponent
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return entries
            .filter { fnmatch(namePattern, $0, 0) == 0 }
            .sorted()
            .map { directory + "/" + $0 }
    }
}
