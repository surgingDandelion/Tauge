import Foundation

/// Errors raised while staging and swapping an update. Every message is
/// localized because it is shown inside the update window.
public enum TaugeUpdateInstallError: Error, Equatable, LocalizedError {
    case unsafeLocation(String)
    case missingDestination
    case extractionFailed(String)
    case invalidBundle
    case identifierMismatch(expected: String, actual: String)
    case versionMismatch(expected: String, actual: String)
    case signatureInvalid(String)
    case teamMismatch(expected: String, actual: String)
    case permissionDenied(String)
    case installFailed(String)
    case relaunchFailed

    public var errorDescription: String? {
        switch self {
        case .unsafeLocation(let path):
            return L("Tauge 位于只读位置（%@），无法在应用内更新。", path)
        case .missingDestination:
            return L("找不到当前应用的位置，无法更新。")
        case .extractionFailed(let detail):
            return L("无法解压更新包：%@", detail)
        case .invalidBundle:
            return L("更新包中没有可用的 Tauge.app。")
        case .identifierMismatch(let expected, let actual):
            return L("更新包的 Bundle ID 不匹配（应为 %@，实际 %@）。", expected, actual)
        case .versionMismatch(let expected, let actual):
            return L("更新包版本不匹配（应为 %@，实际 %@）。", expected, actual)
        case .signatureInvalid(let detail):
            return L("更新包的代码签名无效：%@", detail)
        case .teamMismatch(let expected, let actual):
            return L("更新包的签名团队不匹配（应为 %@，实际 %@）。", expected, actual)
        case .permissionDenied(let path):
            return L("没有权限写入 %@，无法安装更新。", path)
        case .installFailed(let detail):
            return L("安装更新失败：%@", detail)
        case .relaunchFailed:
            return L("无法重新启动 Tauge，请手动打开应用。")
        }
    }
}

/// A staged update that only has to be moved into place after the app exits.
public struct TaugePreparedInstall: Sendable {
    public let destination: URL
    public let stagedApp: URL
    public let backup: URL
    public let stagingRoot: URL
    public let archive: URL
    public let script: URL
    public let privileged: Bool
}

/// Stages, validates and then swaps an update. The actual swap is performed by
/// a detached shell script after the running process exits, so Tauge never
/// executes from a bundle that is being moved out from under it.
public enum TaugeUpdateInstaller {
    public static func prepare(archive: URL,
                               update: TaugeUpdate,
                               currentApp: URL = Bundle.main.bundleURL) throws -> TaugePreparedInstall {
        let fileManager = FileManager.default
        guard currentApp.pathExtension == "app" else {
            throw TaugeUpdateInstallError.missingDestination
        }
        let path = currentApp.standardizedFileURL.path
        guard !path.contains("/AppTranslocation/"), !path.hasPrefix("/Volumes/") else {
            throw TaugeUpdateInstallError.unsafeLocation(path)
        }
        let destination = currentApp.standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        let fileName = destination.lastPathComponent
        let token = UUID().uuidString
        let backup = parent.appendingPathComponent(".\(fileName).backup-\(token)", isDirectory: true)
        let writable = fileManager.isWritableFile(atPath: parent.path)
        let stagingRoot: URL
        if writable {
            stagingRoot = parent.appendingPathComponent(".TaugeUpdate-\(token)", isDirectory: true)
        } else {
            stagingRoot = fileManager.temporaryDirectory.appendingPathComponent("TaugeUpdate-\(token)", isDirectory: true)
        }

        do {
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            let extractRoot = stagingRoot.appendingPathComponent("extracted", isDirectory: true)
            try fileManager.createDirectory(at: extractRoot, withIntermediateDirectories: true)
            let extraction = try run("/usr/bin/ditto", ["-x", "-k", archive.path, extractRoot.path])
            guard extraction.status == 0 else {
                throw TaugeUpdateInstallError.extractionFailed(extraction.output)
            }
            let stagedApp = extractRoot.appendingPathComponent(fileName, isDirectory: true)
            guard fileManager.fileExists(atPath: stagedApp.path) else {
                throw TaugeUpdateInstallError.invalidBundle
            }
            try validate(stagedApp: stagedApp, currentApp: destination, update: update)
            try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stagedApp.path])

            let privileged = !writable
            let script = stagingRoot.appendingPathComponent("install.sh")
            try writeScript(to: script,
                            destination: destination,
                            stagedApp: stagedApp,
                            backup: backup,
                            stagingRoot: stagingRoot,
                            archive: archive,
                            privileged: privileged)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            return TaugePreparedInstall(destination: destination,
                                        stagedApp: stagedApp,
                                        backup: backup,
                                        stagingRoot: stagingRoot,
                                        archive: archive,
                                        script: script,
                                        privileged: privileged)
        } catch {
            try? fileManager.removeItem(at: stagingRoot)
            throw error
        }
    }

    /// Launch the detached swap script and then let the caller terminate.
    public static func launch(_ install: TaugePreparedInstall) throws {
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let user = NSUserName()
        let uid = String(getuid())
        let gid = String(getgid())
        let arguments = [install.script.path,
                         pid,
                         install.destination.path,
                         install.stagedApp.path,
                         install.backup.path,
                         install.stagingRoot.path,
                         install.archive.path,
                         user,
                         uid,
                         gid]

        if !install.privileged {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                throw TaugeUpdateInstallError.relaunchFailed
            }
            return
        }

        let command = (["/bin/sh"] + arguments).map(shellQuote).joined(separator: " ")
        let appleScript = "do shell script \(appleScriptQuote(command)) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw TaugeUpdateInstallError.relaunchFailed
        }
    }

    // MARK: - Validation

    private static func validate(stagedApp: URL, currentApp: URL, update: TaugeUpdate) throws {
        guard let staged = Bundle(url: stagedApp),
              let current = Bundle(url: currentApp) else {
            throw TaugeUpdateInstallError.invalidBundle
        }
        let expectedID = current.bundleIdentifier ?? TaugeAppInfo.bundleIdentifier
        let actualID = staged.bundleIdentifier ?? ""
        guard actualID == expectedID else {
            throw TaugeUpdateInstallError.identifierMismatch(expected: expectedID, actual: actualID)
        }
        let expectedVersion = update.version.description
        let actualVersion = staged.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard actualVersion == expectedVersion else {
            throw TaugeUpdateInstallError.versionMismatch(expected: expectedVersion, actual: actualVersion)
        }

        let verify = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedApp.path])
        guard verify.status == 0 else {
            throw TaugeUpdateInstallError.signatureInvalid(verify.output)
        }
        let currentTeam = try signatureTeam(currentApp)
        let stagedTeam = try signatureTeam(stagedApp)
        if let currentTeam, !currentTeam.isEmpty, currentTeam != stagedTeam {
            throw TaugeUpdateInstallError.teamMismatch(expected: currentTeam, actual: stagedTeam ?? "")
        }
    }

    private static func signatureTeam(_ app: URL) throws -> String? {
        let result = try run("/usr/bin/codesign", ["-dv", "--verbose=4", app.path])
        guard result.status == 0 else {
            throw TaugeUpdateInstallError.signatureInvalid(result.output)
        }
        for line in result.output.split(whereSeparator: { $0.isNewline }) {
            let text = String(line)
            guard text.hasPrefix("TeamIdentifier=") else { continue }
            let value = String(text.dropFirst("TeamIdentifier=".count))
            return value == "not set" || value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - Script

    private static func writeScript(to url: URL,
                                    destination: URL,
                                    stagedApp: URL,
                                    backup: URL,
                                    stagingRoot: URL,
                                    archive: URL,
                                    privileged: Bool) throws {
        var lines = [
            "#!/bin/sh",
            "set -u",
            "pid=\"$1\"",
            "dest=\"$2\"",
            "staged=\"$3\"",
            "backup=\"$4\"",
            "staging=\"$5\"",
            "archive=\"$6\"",
            "user=\"$7\"",
            "uid=\"$8\"",
            "gid=\"$9\"",
            "i=0",
            "while kill -0 \"$pid\" 2>/dev/null; do",
            "  sleep 0.2",
            "  i=$((i + 1))",
            "  if [ \"$i\" -gt 600 ]; then exit 1; fi",
            "done",
            "installed=0",
            "restore() {",
            "  if [ \"$installed\" = 0 ] && [ -d \"$backup\" ] && [ ! -e \"$dest\" ]; then",
            "    mv \"$backup\" \"$dest\"",
            "    open \"$dest\" 2>/dev/null || true",
            "  fi",
            "}",
            "trap restore EXIT",
            "rm -rf \"$backup\"",
            "if ! mv \"$dest\" \"$backup\"; then open \"$dest\"; exit 1; fi",
            "if ! mv \"$staged\" \"$dest\"; then mv \"$backup\" \"$dest\"; open \"$dest\"; exit 1; fi",
            "installed=1"
        ]
        if privileged {
            lines.append("chown -R \"$uid:$gid\" \"$dest\"")
            lines.append("xattr -dr com.apple.quarantine \"$dest\" 2>/dev/null || true")
            lines.append("if ! sudo -u \"$user\" /usr/bin/open \"$dest\"; then")
        } else {
            lines.append("if ! open \"$dest\"; then")
        }
        lines.append("  rm -rf \"$dest\"")
        lines.append("  mv \"$backup\" \"$dest\"")
        lines.append("  open \"$dest\" 2>/dev/null || true")
        lines.append("  exit 1")
        lines.append("fi")
        // The backup is only needed until the new bundle has launched. Keeping it
        // would leave a hidden ~50 MB copy next to the app after every update.
        lines.append("rm -rf \"$backup\" \"$staging\" \"$archive\"")
        let script = lines.joined(separator: "\n") + "\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Process helpers

    struct ProcessResult {
        let status: Int32
        let output: String
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw TaugeUpdateInstallError.installFailed(error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus,
                             output: String(data: data, encoding: .utf8) ?? "")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
