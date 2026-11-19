import Foundation
import Darwin

/// Credentials handed to the system ssh client.
///
/// Unlike \`SSHAuthMaterial\` this can carry a private key in text form (the app
/// already reads it from the Keychain or disk) so a temporary 0600 file can be
/// written for \`ssh -i\`.
public enum SystemSSHCredential: Sendable {
    case agent
    case key(text: String, passphrase: String?)
    case password(String)
    case none

    /// The secret the askpass helper has to return, if any.
    var askpassSecret: String? {
        switch self {
        case .password(let password):
            return password
        case .key(_, let passphrase):
            guard let passphrase, !passphrase.isEmpty else { return nil }
            return passphrase
        case .agent, .none:
            return nil
        }
    }
}

public struct SystemSSHJump: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var credential: SystemSSHCredential

    public init(host: String,
                port: Int,
                username: String,
                credential: SystemSSHCredential = .none) {
        self.host = host
        self.port = port
        self.username = username
        self.credential = credential
    }
}

public struct SystemSSHOptions: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var credential: SystemSSHCredential
    public var jumps: [SystemSSHJump]
    public var proxy: ProxyEndpoint?
    public var connectTimeoutSeconds: Int
    public var keepaliveSeconds: Int
    public var term: String

    public init(host: String,
                port: Int,
                username: String,
                credential: SystemSSHCredential,
                jumps: [SystemSSHJump] = [],
                proxy: ProxyEndpoint? = nil,
                connectTimeoutSeconds: Int = 20,
                keepaliveSeconds: Int = 0,
                term: String = "xterm-256color") {
        self.host = host
        self.port = port
        self.username = username
        self.credential = credential
        self.jumps = jumps
        self.proxy = proxy
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.keepaliveSeconds = keepaliveSeconds
        self.term = term
    }

    public var destination: String {
        username.isEmpty ? host : username + "@" + host
    }
}

public enum SystemSSHError: Error, LocalizedError, Sendable {
    case unsupportedProxy(String)
    case missingExecutable(String)
    case keyUnavailable
    case processFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedProxy(let name):
            return L("系统 ssh 兼容模式无法使用 ") + name + L("：系统 ssh 只能借 nc 转发，带不了代理认证，也不支持把代理和跳板机串起来。")
                + L("请把「高级 → 连接方式」改回「自动」或「内置」——内置 SSH 栈支持 HTTP CONNECT / SOCKS5 的完整认证。")
        case .missingExecutable(let path):
            return L("找不到系统 ssh 客户端（") + path + "）。"
        case .keyUnavailable:
            return L("系统 ssh 兼容模式需要可用的私钥内容。")
        case .processFailed(let detail):
            return detail
        }
    }
}

/// Temporary directory holding the 0600 identity file and the askpass helper.
/// Sessions keep a reference so the files outlive the connection, and the
/// directory is removed when the last reference goes away.
public final class SystemSSHWorkspace: @unchecked Sendable {
    public let directory: URL
    public let sshExecutable: String
    public private(set) var keyPath: String?
    public private(set) var askpassPath: String?
    /// ProxyCommand that tunnels through every configured jump host.
    public private(set) var jumpProxyPath: String?

    private let lock = NSLock()
    private var cleaned = false

    public init(options: SystemSSHOptions, sshExecutable: String = "/usr/bin/ssh") throws {
        guard FileManager.default.isExecutableFile(atPath: sshExecutable) else {
            throw SystemSSHError.missingExecutable(sshExecutable)
        }
        self.sshExecutable = sshExecutable
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shellx-systemssh-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        self.directory = root

        if case .key(let text, _) = options.credential {
            guard !text.isEmpty else { throw SystemSSHError.keyUnavailable }
            let path = root.appendingPathComponent("identity").path
            var contents = text
            if !contents.hasSuffix("\n") { contents += "\n" }
            try contents.write(toFile: path, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            self.keyPath = path
        }

        if let secret = options.credential.askpassSecret {
            let path = root.appendingPathComponent("askpass").path
            let quoted = secret.replacingOccurrences(of: "'", with: "'\\''")
            let script = "#!/bin/sh\nprintf '%s\\n' '" + quoted + "'\n"
            try script.write(toFile: path, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            self.askpassPath = path
        }

        if !options.jumps.isEmpty {
            self.jumpProxyPath = try SystemSSHWorkspace.writeJumpScripts(options: options,
                                                                        sshExecutable: sshExecutable,
                                                                        root: root,
                                                                        keyPath: keyPath,
                                                                        askpassAvailable: askpassPath != nil)
        }
    }

    /// OpenSSH rewrites `-J chain` into an ssh invocation that does *not* inherit
    /// the `-o` options we pass here, so a legacy jump host would still refuse the
    /// connection. Each hop therefore gets its own script that carries the legacy
    /// algorithm options and forwards to the next hop with `-W`.
    private static func writeJumpScripts(options: SystemSSHOptions,
                                         sshExecutable: String,
                                         root: URL,
                                         keyPath: String?,
                                         askpassAvailable: Bool) throws -> String {
        var previous: String?
        for (index, jump) in options.jumps.enumerated() {
            var command = shellQuoted(sshExecutable)
            let hopFiles = try writeJumpCredential(jump.credential, root: root, index: index)
            let hopUsesCredential = !isNone(jump.credential)
            var hopOptions = SystemSSHCommandBuilder.baseOptions(
                options: options,
                askpassAvailable: hopFiles.askpassPath != nil || (!hopUsesCredential && askpassAvailable)
            )
            if let hopKeyPath = hopFiles.keyPath {
                hopOptions += ["-i", hopKeyPath, "-o", "IdentitiesOnly=yes"]
            } else if !hopUsesCredential, let keyPath {
                // Backward-compatible fallback for callers that only supplied
                // one identity and leave hop authentication to that key.
                hopOptions += ["-i", keyPath, "-o", "IdentitiesOnly=yes"]
            }
            command += " " + hopOptions.map(shellQuoted).joined(separator: " ")
            if let previous {
                // The path lives in our own temporary directory, so it never needs
                // its own quoting level here.
                command += " -o " + shellQuoted("ProxyCommand=" + previous + " %h %p")
            }
            command += " -p " + String(jump.port)
            if !jump.username.isEmpty {
                command += " -l " + shellQuoted(jump.username)
            }
            command += " -W \"$1:$2\""
            command += " " + shellQuoted(jump.host)
            let path = root.appendingPathComponent("jump\(index + 1).sh").path
            try ("#!/bin/sh\nexec " + command + "\n").write(toFile: path, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            previous = path
        }
        return previous ?? ""
    }

    private static func isNone(_ credential: SystemSSHCredential) -> Bool {
        if case .none = credential { return true }
        return false
    }

    private static func writeJumpCredential(_ credential: SystemSSHCredential,
                                            root: URL,
                                            index: Int) throws -> (keyPath: String?, askpassPath: String?) {
        var keyPath: String?
        if case .key(let text, _) = credential {
            guard !text.isEmpty else { throw SystemSSHError.keyUnavailable }
            let path = root.appendingPathComponent("jump(index + 1)-identity").path
            var contents = text
            if !contents.hasSuffix("\n") { contents += "\n" }
            try contents.write(toFile: path, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            keyPath = path
        }

        var askpassPath: String?
        if let secret = credential.askpassSecret {
            let path = root.appendingPathComponent("jump(index + 1)-askpass").path
            let quoted = secret.replacingOccurrences(of: "'", with: "'\\''")
            let script = "#!/bin/sh\nprintf '%s\\n' '" + quoted + "'\n"
            try script.write(toFile: path, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            askpassPath = path
        }
        return (keyPath, askpassPath)
    }

    /// Quotes a string for /bin/sh, including the awkward embedded quote case.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    deinit {
        cleanup()
    }

    public func cleanup() {
        lock.lock()
        if cleaned {
            lock.unlock()
            return
        }
        cleaned = true
        lock.unlock()
        try? FileManager.default.removeItem(at: directory)
    }
}

public enum SystemSSHMode: Equatable, Sendable {
    case terminal
    case sftp
    case command(String)
}

/// Builds the argv and environment for the system ssh client.
public enum SystemSSHCommandBuilder {
    /// Algorithms the vendored stack refuses but old servers still require.
    /// The \`+\` prefix keeps every modern algorithm enabled and only appends the
    /// legacy ones, so negotiation stays as strong as the server allows.
    static let legacyOptions: [String] = [
        "-o", "HostKeyAlgorithms=+ssh-rsa",
        "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa",
        "-o", "KexAlgorithms=+diffie-hellman-group14-sha1",
        "-o", "Ciphers=+aes128-ctr,aes192-ctr,aes256-ctr",
        "-o", "MACs=+hmac-sha1,hmac-sha2-256",
    ]

    /// Options every hop of a chain needs: non-interactive, no shared control
    /// socket, and the legacy algorithms an old server may require.
    static func baseOptions(options: SystemSSHOptions,
                            askpassAvailable: Bool = false) -> [String] {
        var args: [String] = []
        args += ["-o", "BatchMode=" + (askpassAvailable ? "no" : "yes")]
        args += ["-o", "StrictHostKeyChecking=accept-new"]
        args += ["-o", "LogLevel=ERROR"]
        args += ["-o", "ConnectTimeout=" + String(max(options.connectTimeoutSeconds, 1))]
        args += ["-o", "ControlMaster=no", "-o", "ControlPath=none"]
        args += legacyOptions
        return args
    }

    public static func arguments(options: SystemSSHOptions, workspace: SystemSSHWorkspace, mode: SystemSSHMode) -> [String] {
        var args = baseOptions(options: options, askpassAvailable: workspace.askpassPath != nil)
        if options.keepaliveSeconds > 0 {
            args += ["-o", "ServerAliveInterval=" + String(options.keepaliveSeconds)]
            args += ["-o", "ServerAliveCountMax=3"]
        }

        if let proxy = options.proxy {
            if let command = proxyCommand(for: proxy) {
                args += ["-o", "ProxyCommand=" + command]
            }
        }
        if let jumpProxy = workspace.jumpProxyPath {
            args += ["-o", "ProxyCommand=" + jumpProxy + " %h %p"]
        }

        switch options.credential {
        case .key:
            if let keyPath = workspace.keyPath {
                args += ["-i", keyPath]
                args += ["-o", "IdentitiesOnly=yes"]
            }
        case .password:
            args += ["-o", "PubkeyAuthentication=no"]
            args += ["-o", "KbdInteractiveAuthentication=yes"]
            args += ["-o", "PreferredAuthentications=password,keyboard-interactive"]
            args += ["-o", "NumberOfPasswordPrompts=1"]
        case .none:
            args += ["-o", "PubkeyAuthentication=no"]
        case .agent:
            break
        }

        args += ["-p", String(options.port)]

        switch mode {
        case .terminal:
            args += ["-tt"]
            args += [options.destination]
        case .sftp:
            args += ["-s"]
            args += [options.destination, "sftp"]
        case .command(let command):
            args += ["--", options.destination, command]
        }
        return args
    }

    public static func environment(options: SystemSSHOptions,
                                   workspace: SystemSSHWorkspace,
                                   base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["TERM"] = options.term
        // Keep ssh from trying to talk to a terminal it does not own and take
        // the answer from the helper instead. 8.4+ honours SSH_ASKPASS_REQUIRE.
        env.removeValue(forKey: "SSH_TTY")
        if let askpass = workspace.askpassPath {
            env["SSH_ASKPASS"] = askpass
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = env["DISPLAY"] ?? ":0"
        } else {
            env.removeValue(forKey: "SSH_ASKPASS")
            env.removeValue(forKey: "SSH_ASKPASS_REQUIRE")
        }
        return env
    }

    /// macOS ships \`nc\`, which can speak SOCKS5 and HTTP CONNECT. Authenticated
    /// proxies cannot be expressed this way, so they stay unsupported.
    static func proxyCommand(for proxy: ProxyEndpoint) -> String? {
        if proxy.username?.isEmpty == false || proxy.password?.isEmpty == false { return nil }
        let endpoint = proxy.host + ":" + String(proxy.port)
        switch proxy.type {
        case .socks5, .socks5h:
            return "/usr/bin/nc -X 5 -x " + endpoint + " %h %p"
        case .http:
            return "/usr/bin/nc -X connect -x " + endpoint + " %h %p"
        case .https:
            return nil
        }
    }

    /// Throws when the requested route cannot be expressed to the system client.
    public static func validate(options: SystemSSHOptions) throws {
        guard let proxy = options.proxy else { return }
        if proxyCommand(for: proxy) == nil {
            if proxy.type == .https {
                throw SystemSSHError.unsupportedProxy(L("HTTPS（TLS）代理"))
            }
            let authenticated = proxy.username?.isEmpty == false || proxy.password?.isEmpty == false
            throw SystemSSHError.unsupportedProxy((authenticated ? L("带用户名或密码的 ") : "") + proxy.type.displayName)
        }
        if !options.jumps.isEmpty {
            throw SystemSSHError.unsupportedProxy(L("代理 + 跳板机组合"))
        }
    }
}

public struct SystemSSHResult: Sendable {
    public var stdout: Data
    public var stderr: Data
    public var exitCode: Int32
    public var timedOut: Bool

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Spawns short-lived system ssh processes with a timeout.
public enum SystemSSHRunner {
    /// Blocking; call it off the main actor (and off the cooperative pool).
    public static func run(options: SystemSSHOptions,
                           workspace: SystemSSHWorkspace,
                           command: String,
                           timeout: TimeInterval) -> SystemSSHResult {
        let arguments = SystemSSHCommandBuilder.arguments(options: options, workspace: workspace, mode: .command(command))
        let environment = SystemSSHCommandBuilder.environment(options: options, workspace: workspace)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: workspace.sshExecutable)
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let out = LockedData()
        let err = LockedData()
        var exitCode: Int32 = -1
        var timedOut = false

        do {
            try process.run()
        } catch {
            return SystemSSHResult(stdout: Data(), stderr: Data(error.localizedDescription.utf8), exitCode: -1, timedOut: false)
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            out.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            err.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + max(timeout, 0.1))
        timer.setEventHandler {
            timedOut = true
            process.terminate()
        }
        timer.resume()

        process.waitUntilExit()
        timer.cancel()
        exitCode = process.terminationStatus
        group.wait()

        return SystemSSHResult(stdout: out.value, stderr: err.value, exitCode: exitCode, timedOut: timedOut)
    }
}

/// A long-lived ssh child (terminal or SFTP) that the client can tear down.
public protocol SystemSSHChild: AnyObject, Sendable {
    var isRunning: Bool { get }
    func terminate()
}

/// Interactive shell over a local pseudo terminal.
public final class SystemSSHTerminalProcess: SystemSSHChild, @unchecked Sendable {
    public var onData: (@Sendable (Data) -> Void)?
    public var onClose: (@Sendable (Error?) -> Void)?

    private let process: Process
    private let masterFD: Int32
    private let workspace: SystemSSHWorkspace
    private var source: DispatchSourceRead?
    private let readQueue = DispatchQueue(label: "shellx.systemssh.pty.read")
    private let writeQueue = DispatchQueue(label: "shellx.systemssh.pty.write")
    private let stateLock = NSLock()
    private var closed = false
    private var closeNotified = false

    public init(options: SystemSSHOptions,
                workspace: SystemSSHWorkspace,
                columns: Int,
                rows: Int) throws {
        self.workspace = workspace
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: UInt16(max(rows, 1)),
                           ws_col: UInt16(max(columns, 1)),
                           ws_xpixel: 0,
                           ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw SystemSSHError.processFailed(L("无法创建本地伪终端（errno ") + String(errno) + "）")
        }
        self.masterFD = master

        let handle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: workspace.sshExecutable)
        process.arguments = SystemSSHCommandBuilder.arguments(options: options, workspace: workspace, mode: .terminal)
        process.environment = SystemSSHCommandBuilder.environment(options: options, workspace: workspace)
        process.standardInput = handle
        process.standardOutput = handle
        process.standardError = handle
        self.process = process

        var flags = fcntl(master, F_GETFL, 0)
        flags |= O_NONBLOCK
        _ = fcntl(master, F_SETFL, flags)

        do {
            try process.run()
        } catch {
            close(master)
            close(slave)
            throw SystemSSHError.processFailed(L("无法启动 ssh：") + error.localizedDescription)
        }
        // The child owns its copy of the slave end now; keeping ours open would
        // stop the master from ever seeing EOF.
        close(slave)

        process.terminationHandler = { [weak self] _ in
            self?.finish(nil)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: readQueue)
        source.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        source.resume()
        self.source = source
    }

    public var isRunning: Bool {
        stateLock.lock()
        let done = closed
        stateLock.unlock()
        return !done && process.isRunning
    }

    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let done = self.closed
            self.stateLock.unlock()
            guard !done else { return }
            data.withUnsafeBytes { raw in
                guard var pointer = raw.baseAddress else { return }
                var remaining = raw.count
                while remaining > 0 {
                    let written = Darwin.write(self.masterFD, pointer, remaining)
                    if written > 0 {
                        pointer = pointer.advanced(by: written)
                        remaining -= written
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
            }
        }
    }

    public func resize(columns: Int, rows: Int) {
        var size = winsize(ws_row: UInt16(max(rows, 1)),
                           ws_col: UInt16(max(columns, 1)),
                           ws_xpixel: 0,
                           ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
        // The pty slave is not the ssh child's controlling terminal (Foundation
        // launches it without one), so the kernel never posts SIGWINCH and
        // OpenSSH never forwards a window-change to the remote pty. Poking the
        // child ourselves is what makes the remote shell re-wrap at the new
        // column count; without it CJK lines keep wrapping at the old width.
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGWINCH)
        }
    }

    public func terminate() {
        if process.isRunning {
            process.terminate()
        }
        finish(nil)
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(masterFD, raw.baseAddress, raw.count)
            }
            if count > 0 {
                onData?(Data(buffer[0..<count]))
                continue
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            // EOF or a hard error: the child is gone.
            finish(nil)
            return
        }
    }

    private func finish(_ error: Error?) {
        stateLock.lock()
        if closed {
            stateLock.unlock()
            return
        }
        closed = true
        let notify = !closeNotified
        closeNotified = true
        stateLock.unlock()
        source?.cancel()
        source = nil
        close(masterFD)
        if process.isRunning {
            process.terminate()
        }
        if notify {
            onClose?(error)
        }
    }

    deinit {
        terminate()
    }
}

/// SFTP subsystem over \`ssh -s <host> sftp\`, exposed as a regular transport.
public final class SystemSSHSFTPTransport: SFTPTransport, SystemSSHChild, @unchecked Sendable {
    private let process: Process
    private let workspace: SystemSSHWorkspace
    private let input: FileHandle
    private let output: FileHandle
    private let errorPipe: FileHandle

    private let lock = NSLock()
    private var buffer = Data()
    private var waiter: CheckedContinuation<Data?, Never>?
    private var closed = false
    private var stderrData = Data()

    public init(options: SystemSSHOptions, workspace: SystemSSHWorkspace) throws {
        self.workspace = workspace
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: workspace.sshExecutable)
        process.arguments = SystemSSHCommandBuilder.arguments(options: options, workspace: workspace, mode: .sftp)
        process.environment = SystemSSHCommandBuilder.environment(options: options, workspace: workspace)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        self.process = process
        self.input = stdinPipe.fileHandleForWriting
        self.output = stdoutPipe.fileHandleForReading
        self.errorPipe = stderrPipe.fileHandleForReading

        do {
            try process.run()
        } catch {
            throw SystemSSHError.processFailed(L("无法启动 ssh：") + error.localizedDescription)
        }

        output.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.closeStream(nil)
            } else {
                self?.deliver(data)
            }
        }
        errorPipe.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.appendStderr(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            self?.output.readabilityHandler = nil
            self?.closeStream(nil)
        }
    }

    public var isRunning: Bool { process.isRunning }

    public var stderrText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: stderrData, as: UTF8.self)
    }

    public func send(_ data: Data) async throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        // TransferEngine intentionally has a request window. FileHandle writes
        // from those concurrent SFTP tasks can otherwise interleave bytes on
        // the single `ssh -s sftp` stdin, which corrupts packets on jumped
        // system-ssh sessions.
        try input.write(contentsOf: data)
    }

    public func receive() async throws -> Data? {
        lock.lock()
        if !buffer.isEmpty {
            let chunk = buffer
            buffer.removeAll(keepingCapacity: true)
            lock.unlock()
            return chunk
        }
        if closed {
            let text = String(decoding: stderrData, as: UTF8.self)
            lock.unlock()
            if !text.isEmpty {
                throw SFTPError.transport(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }
        lock.unlock()
        return await withCheckedContinuation { continuation in
            lock.lock()
            if !buffer.isEmpty {
                let chunk = buffer
                buffer.removeAll(keepingCapacity: true)
                lock.unlock()
                continuation.resume(returning: chunk)
                return
            }
            if closed {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }

    public func closeTransport() async {
        lock.lock()
        let done = closed
        lock.unlock()
        if !done { terminate() }
        closeStream(nil)
    }

    public func terminate() {
        input.closeFile()
        if process.isRunning { process.terminate() }
        closeStream(nil)
    }

    private func appendStderr(_ data: Data) {
        lock.lock()
        stderrData.append(data)
        lock.unlock()
    }

    private func deliver(_ data: Data) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: data)
            return
        }
        buffer.append(data)
        lock.unlock()
    }

    private func closeStream(_ error: Error?) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(returning: nil)
    }

    deinit {
        output.readabilityHandler = nil
        errorPipe.readabilityHandler = nil
        input.closeFile()
        if process.isRunning { process.terminate() }
    }
}

/// Thread-safe byte collector for the command runner.
final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
