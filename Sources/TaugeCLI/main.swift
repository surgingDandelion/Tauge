import Foundation
import NIOPosix
import TaugeKit

@main
enum TaugeCLI {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data(("tauge: " + (error.localizedDescription) + "\n").utf8))
            Foundation.exit(1)
        }
    }

    private static func run(arguments: [String]) async throws {
        guard let command = arguments.first else {
            printUsage()
            return
        }
        switch command {
        case "machine", "machines":
            try await withContext { service, _ in
                try listMachines(service: service, arguments: Array(arguments.dropFirst()))
            }
        case "exec":
            try await withContext { service, _ in
                try await execute(service: service, arguments: Array(arguments.dropFirst()))
            }
        case "cp":
            try await withContext { service, _ in
                try await copy(service: service, arguments: Array(arguments.dropFirst()))
            }
        case "mcp":
            try await withContext { service, mcpEnabled in
                guard mcpEnabled else {
                    throw CLIError.message("MCP 通道未启用，请在 Tauge 设置的通用区打开 MCP 开关。")
                }
                try await runMCP(service: service)
            }
        case "help", "--help", "-h":
            printUsage()
        default:
            throw CLIError.usage("未知命令：" + command)
        }
    }

    private static func listMachines(service: RemoteCommandService,
                                     arguments: [String]) throws {
        let machines = try service.targets()
        if arguments.contains("--json") {
            let data = try JSONEncoder().encode(machines)
            print(String(decoding: data, as: UTF8.self))
            return
        }
        for machine in machines {
            let line = machine.id.uuidString + "\t" + machine.name + "\t" + machine.address
            print(line)
        }
    }

    private static func execute(service: RemoteCommandService,
                                arguments: [String]) async throws {
        guard let machineIndex = arguments.firstIndex(of: "--machine"), machineIndex + 1 < arguments.count else {
            throw CLIError.usage("exec 需要 --machine <名称或 ID>")
        }
        let machineValue = arguments[machineIndex + 1]
        let json = arguments.contains("--json")
        let commandStart = arguments.firstIndex(of: "--").map { $0 + 1 } ?? arguments.count
        guard commandStart < arguments.count else {
            throw CLIError.usage("exec 需要在 -- 后提供命令")
        }
        let command = arguments[commandStart...].joined(separator: " ")
        let result = try await service.execute(target: machineValue,
                                               command: command)
        if json {
            let data = try JSONEncoder().encode(result)
            print(String(decoding: data, as: UTF8.self))
        } else {
            print(result.output, terminator: result.output.hasSuffix("\n") ? "" : "\n")
        }
    }

    private static func copy(service: RemoteCommandService, arguments: [String]) async throws {
        var values = arguments
        let recursive = values.contains { $0 == "-r" || $0 == "--recursive" }
        values.removeAll { $0 == "-r" || $0 == "--recursive" }
        let json = values.contains("--json")
        values.removeAll { $0 == "--json" }
        guard values.count == 2 else {
            throw CLIError.usage("cp 用法：tauge cp [-r] machineA:/source machineB:/destination")
        }
        let source = try parseRemotePath(values[0])
        let destination = try parseRemotePath(values[1])
        let result = try await service.copy(sourceTarget: source.target,
                                            sourcePath: source.path,
                                            destinationTarget: destination.target,
                                            destinationPath: destination.path,
                                            recursive: recursive)
        if json {
            let data = try JSONEncoder().encode(result)
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("copied (result.files) file(s), (result.bytes) bytes in (result.durationMilliseconds) ms")
        }
    }

    private static func parseRemotePath(_ value: String) throws -> (target: String, path: String) {
        guard let separator = value.firstIndex(of: ":") else {
            throw CLIError.usage("远程路径必须使用 machine:/path 格式：" + value)
        }
        let target = String(value[..<separator])
        let path = String(value[value.index(after: separator)...])
        guard !target.isEmpty, !path.isEmpty else {
            throw CLIError.usage("远程路径必须使用 machine:/path 格式：" + value)
        }
        return (target, path.hasPrefix("/") ? path : "/" + path)
    }

    private static func withContext(_ operation: (RemoteCommandService, Bool) async throws -> Void) async throws {
        let url = catalogURL()
        _ = try? HostStore.migrateLegacyDatabaseIfNeeded(to: url)
        _ = try? LocalVaultStore.migrateLegacyDirectoryIfNeeded(to: url.deletingLastPathComponent())
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.message("找不到 Tauge 配置数据库：" + url.path)
        }
        let database = try SQLiteDatabase.openForReading(path: url.path)
        let store = try HostStore(database: database, createSchema: false)
        let mcpEnabled = try store.settings().mcpEnabled
        let vault = LocalVaultStore(directory: url.deletingLastPathComponent())
        let secrets = CachingSecretStore(upstream: MigratingSecretStore(local: vault))
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let service = RemoteCommandService(store: store, secrets: secrets, eventLoopGroup: eventLoopGroup)
        do {
            try await operation(service, mcpEnabled)
        } catch {
            try? await eventLoopGroup.shutdownGracefully()
            throw error
        }
        try? await eventLoopGroup.shutdownGracefully()
    }

    private static func catalogURL() -> URL {
        if let raw = ProcessInfo.processInfo.environment["TAUGE_CATALOG_PATH"], !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        if let raw = UserDefaults.standard.string(forKey: "TaugeCatalogPath"), !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        if let raw = ProcessInfo.processInfo.environment["SHELLX_CATALOG_PATH"], !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        if let raw = UserDefaults.standard.string(forKey: "ShellXCatalogPath"), !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        return HostStore.defaultDatabaseURL()
    }

    private static func printUsage() {
        print("""
        tauge machine list [--json]
        tauge exec --machine <name-or-id> [--json] -- <command> [args...]
        tauge cp [-r] machineA:/source machineB:/destination
        tauge mcp
        """)
    }


    private static func runMCP(service: RemoteCommandService) async throws {
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let id = request["id"]
            let method = request["method"] as? String ?? ""
            let params = request["params"] as? [String: Any] ?? [:]
            if method.hasPrefix("notifications/") { continue }
            let response: [String: Any]
            do {
                response = try await handleMCP(method: method, id: id, params: params, service: service)
            } catch {
                response = ["jsonrpc": "2.0", "id": id ?? NSNull(),
                            "error": ["code": -32000, "message": error.localizedDescription]]
            }
            let output = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
            FileHandle.standardOutput.write(output)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    private static func handleMCP(method: String,
                                  id: Any?,
                                  params: [String: Any],
                                  service: RemoteCommandService) async throws -> [String: Any] {
        switch method {
        case "initialize":
            return ["jsonrpc": "2.0", "id": id ?? NSNull(),
                    "result": ["protocolVersion": "2025-06-18",
                                "capabilities": ["tools": [:]],
                                "serverInfo": ["name": "tauge", "version": TaugeAppInfo.version]]]
        case "notifications/initialized":
            return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": [:]]
        case "tools/list":
            return ["jsonrpc": "2.0", "id": id ?? NSNull(),
                    "result": ["tools": [
                        ["name": "tauge_targets", "description": "List authorized Tauge machines", "inputSchema": ["type": "object"]],
                        ["name": "tauge_exec", "description": "Run a remote command through Tauge", "inputSchema": [
                            "type": "object",
                            "properties": ["target": ["type": "string"], "command": ["type": "string"], "timeoutSeconds": ["type": "number"]],
                            "required": ["target", "command"]
                        ]]
                    ]]]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let result = try await callMCPTool(name: name, arguments: arguments, service: service)
            return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
        default:
            return ["jsonrpc": "2.0", "id": id ?? NSNull(),
                    "error": ["code": -32601, "message": "Method not found"]]
        }
    }

    private static func callMCPTool(name: String,
                                    arguments: [String: Any],
                                    service: RemoteCommandService) async throws -> [String: Any] {
        switch name {
        case "tauge_targets":
            let data = try JSONEncoder().encode(service.targets())
            return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
        case "tauge_exec":
            guard let target = arguments["target"] as? String,
                  let command = arguments["command"] as? String else {
                return ["isError": true, "content": [["type": "text", "text": "target and command are required"]]]
            }
            let timeoutSeconds = (arguments["timeoutSeconds"] as? NSNumber)?.doubleValue ?? 30
            let result = try await service.execute(target: target,
                                                    command: command,
                                                    timeout: .milliseconds(Int64(max(1, timeoutSeconds) * 1000)))
            let data = try JSONEncoder().encode(result)
            return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
        default:
            return ["isError": true, "content": [["type": "text", "text": "Unknown tool: " + name]]]
        }
    }
}

private enum CLIError: Error, LocalizedError {
    case usage(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .message(let message): return message
        }
    }
}
