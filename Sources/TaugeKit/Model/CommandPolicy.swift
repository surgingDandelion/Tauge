import Foundation

public enum CommandRisk: String, Codable, Equatable, Sendable {
    case normal
    case high

    public var requiresConfirmation: Bool { self == .high }
}

public enum CommandRiskRule: String, Codable, Equatable, Sendable {
    case privilegeEscalation
    case destructiveOperation
    case serviceChange
    case packageChange
    case filesystemChange
    case shellComposition
}

public struct CommandRiskAssessment: Codable, Equatable, Sendable {
    public let command: String
    public let risk: CommandRisk
    public let rule: CommandRiskRule?

    public init(command: String, risk: CommandRisk, rule: CommandRiskRule? = nil) {
        self.command = command
        self.risk = risk
        self.rule = rule
    }

    public var requiresConfirmation: Bool { risk.requiresConfirmation }
}

/// Conservative classification for explicit commands sent to a remote shell.
public enum CommandRiskClassifier {
    private static let separators: Set<String> = [";", "|", "&", "(", ")"]
    private static let privileged = Set(["sudo", "su", "doas"])
    private static let destructive = Set([
        "rm", "rmdir", "mkfs", "mkfs.ext4", "mkfs.xfs", "dd", "fdisk", "parted",
        "shutdown", "reboot", "halt", "poweroff", "init", "kill", "pkill", "killall",
        "mount", "umount", "useradd", "userdel", "usermod", "passwd"
    ])
    private static let filesystem = Set([
        "chmod", "chown", "chgrp", "mv", "cp", "mkdir", "rmdir", "touch", "ln",
        "install", "tee", "truncate"
    ])
    private static let serviceActions = Set([
        "start", "stop", "restart", "reload", "enable", "disable", "mask", "unmask",
        "reset-failed", "kill", "daemon-reload", "isolate"
    ])
    private static let packageActions = Set([
        "install", "i", "add", "remove", "uninstall", "purge", "upgrade", "update",
        "dist-upgrade", "full-upgrade", "autoremove", "reinstall", "clean", "publish",
        "run", "exec", "sync", "link", "unlink"
    ])

    public static func assess(_ command: String) -> CommandRiskAssessment {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CommandRiskAssessment(command: command, risk: .normal) }
        let tokens = tokenize(trimmed)

        for (segmentIndex, segment) in commandSegments(tokens).enumerated() {
            guard let executableIndex = executableIndex(in: segment) else { continue }
            let executable = executableName(segment[executableIndex])
            let arguments = Array(segment.dropFirst(executableIndex + 1)).map { $0.lowercased() }
            if privileged.contains(executable) { return high(trimmed, .privilegeEscalation) }
            if destructive.contains(executable) { return high(trimmed, .destructiveOperation) }
            if filesystem.contains(executable) { return high(trimmed, .filesystemChange) }
            if isServiceMutation(executable: executable, arguments: arguments) { return high(trimmed, .serviceChange) }
            if isPackageMutation(executable: executable, arguments: arguments) { return high(trimmed, .packageChange) }
            if isShellComposition(executable: executable, arguments: arguments, isPipelineStage: segmentIndex > 0) {
                return high(trimmed, .shellComposition)
            }
            if isGitMutation(executable: executable, arguments: arguments)
                || isContainerMutation(executable: executable, arguments: arguments)
                || isKubernetesMutation(executable: executable, arguments: arguments)
                || isTerraformMutation(executable: executable, arguments: arguments) {
                return high(trimmed, .destructiveOperation)
            }
        }
        if tokens.contains(where: { $0 == ">" || $0 == "<" }) { return high(trimmed, .filesystemChange) }
        return CommandRiskAssessment(command: command, risk: .normal)
    }

    private static func high(_ command: String, _ rule: CommandRiskRule) -> CommandRiskAssessment {
        CommandRiskAssessment(command: command, risk: .high, rule: rule)
    }

    private static func isServiceMutation(executable: String, arguments: [String]) -> Bool {
        guard executable == "systemctl" || executable == "service" || executable == "launchctl" else { return false }
        return arguments.contains(where: serviceActions.contains)
    }

    private static func isPackageMutation(executable: String, arguments: [String]) -> Bool {
        let managers = Set(["apt", "apt-get", "yum", "dnf", "apk", "brew", "pip", "pip3", "npm", "pnpm", "yarn"])
        guard managers.contains(executable) else { return false }
        return arguments.contains(where: packageActions.contains)
    }

    private static func isShellComposition(executable: String,
                                           arguments: [String],
                                           isPipelineStage: Bool) -> Bool {
        let interpreters = Set(["sh", "bash", "zsh", "fish", "dash", "ksh", "python", "python3", "perl", "ruby"])
        guard interpreters.contains(executable) else { return false }
        return isPipelineStage
            || arguments.contains("-c")
            || arguments.contains("-e")
            || arguments.contains("--command")
            || arguments.contains(where: { $0.hasSuffix(".sh") })
    }

    private static func isGitMutation(executable: String, arguments: [String]) -> Bool {
        guard executable == "git", let action = arguments.first else { return false }
        if action == "push" { return arguments.contains { $0 == "--force" || $0 == "-f" || $0 == "--delete" } }
        return ["reset", "clean", "checkout", "restore", "rebase", "merge", "cherry-pick", "commit", "branch"].contains(action)
    }

    private static func isContainerMutation(executable: String, arguments: [String]) -> Bool {
        guard executable == "docker" || executable == "podman" else { return false }
        return ["rm", "rmi", "stop", "kill", "restart", "start", "run", "exec", "prune", "build", "push", "pull"].contains(where: arguments.contains)
    }

    private static func isKubernetesMutation(executable: String, arguments: [String]) -> Bool {
        guard executable == "kubectl" || executable == "helm" else { return false }
        return ["delete", "apply", "patch", "replace", "scale", "rollout", "cordon", "drain", "taint", "install", "upgrade", "uninstall"].contains(where: arguments.contains)
    }

    private static func isTerraformMutation(executable: String, arguments: [String]) -> Bool {
        guard executable == "terraform", let action = arguments.first else { return false }
        return ["apply", "destroy", "import", "taint", "untaint"].contains(action)
    }

    private static func executableIndex(in segment: [String]) -> Int? {
        for index in segment.indices {
            let token = segment[index]
            if token == "env" || token == "command" || token == "builtin" || token == "nohup" { continue }
            if token.contains("=") && token.first?.isLetter == true { continue }
            return index
        }
        return nil
    }

    private static func executableName(_ token: String) -> String {
        token.split(separator: "/").last.map(String.init)?.lowercased() ?? token.lowercased()
    }

    private static func commandSegments(_ tokens: [String]) -> [[String]] {
        var segments: [[String]] = [[]]
        for token in tokens {
            if separators.contains(token) { segments.append([]) }
            else { segments[segments.count - 1].append(token) }
        }
        return segments
    }

    private static func tokenize(_ command: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        func flush() {
            guard !current.isEmpty else { return }
            result.append(current)
            current.removeAll(keepingCapacity: true)
        }
        for character in command {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; continue }
            if quote != nil {
                if let activeQuote = quote, character == activeQuote { quote = nil }
                else { current.append(character) }
                continue
            }
            if character == "'" || character == "\"" { quote = character }
            else if character.isWhitespace { flush() }
            else if ";|&()<>".contains(character) { flush(); result.append(String(character)) }
            else { current.append(character) }
        }
        if escaped { current.append("\\") }
        flush()
        return result
    }
}
