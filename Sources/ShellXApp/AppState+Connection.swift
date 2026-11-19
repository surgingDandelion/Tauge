import AppKit
import Foundation
import NIOCore
import ShellXKit

// MARK: - Connection orchestration

extension AppState {
    /// Connects a tab that came back from the workspace snapshot.
    ///
    /// Restored tabs are idle because the snapshot stores the strip layout, not
    /// the sockets. Selection, app activation and the pane's own reconnect
    /// button all funnel through here so an idle tab never stays blank.
    func connectIfIdle(_ tab: TerminalTab) {
        guard case .idle = tab.connectionState, !tab.isClosing else { return }
        connect(tab: tab)
    }

    /// Asks for Touch ID once per launch before a stored credential is read.
    ///
    /// The vault is a file, so macOS never asks for the keychain password and
    /// nothing would stop a passer-by from connecting as the user. This gate is
    /// what makes reading a stored credential fingerprint-first. It is skipped
    /// when the setting is off, when the Mac has no sensor with an enrolled
    /// finger, and after the first successful unlock in this process. A hard
    /// authentication failure opens the vault rather than blocking the
    /// connection: the gate is a convenience, the file permissions are the guard.
    private func unlockCredentialsIfNeeded(tab: TerminalTab) async -> Bool {
        guard settings.unlockWithBiometrics, BiometricGate.hasBiometrics() else { return true }
        let gate = BiometricGate.shared
        if gate.isUnlocked { return true }

        let previous = tab.connectionState
        tab.markConnecting(L("等待 Touch ID 解锁"))
        switch await gate.unlock(reason: L("解锁已保存的登录密码与私钥口令")) {
        case .unlocked, .unavailable:
            return true
        case .cancelled:
            restore(tab, afterDismissedUnlock: previous, reason: L("已取消解锁"))
            return false
        case .failed:
            // The sheet only reports this after repeated bad attempts. Open the
            // vault instead of leaving the user unable to connect at all.
            return true
        }
    }

    /// Puts the tab back where it was when the unlock sheet was raised. A live
    /// session must not be relabelled as disconnected just because the user
    /// dismissed Touch ID, and a fresh tab has to show why nothing happened.
    private func restore(_ tab: TerminalTab, afterDismissedUnlock previous: TabConnectionState, reason: String) {
        if previous.isConnected {
            tab.connectionState = .connected
        } else {
            tab.markDisconnected(reason)
        }
    }

    /// Connects the tab. A scheduled retry passes `force` because it moved the
    /// tab into the "reconnecting" state itself, which would otherwise look busy
    /// and make the retry a no-op.
    func connect(tab: TerminalTab, force: Bool = false) {
        // A waiting retry timer counts as idle: an explicit attempt (the retry
        // button, a refresh) should dial now and supersede the timer instead of
        // being swallowed by the "reconnecting" state the timer itself set.
        let waitingForRetry = tab.reconnectTask != nil
        guard force || waitingForRetry || !tab.connectionState.isBusy else { return }
        tab.reconnectTask?.cancel()
        tab.reconnectTask = nil
        tab.connectTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performConnect(tab: tab)
        }
        tab.connectTask = task
    }

    private func performConnect(tab: TerminalTab) async {
        let host = tab.host
        guard await unlockCredentialsIfNeeded(tab: tab) else { return }
        tab.markConnecting(L("解析配置"))
        do {
            let resolver = ConfigResolver(catalog: Catalog(groups: groups, hosts: hosts, proxies: proxies, keys: keys))
            let config = try resolver.effective(for: host)
            let route = resolver.routeDescription(for: config)
            tab.statusDetail = route
            tab.setEncoding(config.encoding)

            let requestedTransport = effectiveTransport(for: config)
            var usedCompatibilityMode = false
            var established: EstablishedConnection?
            do {
                established = try await establishConnection(host: host,
                                                            config: config,
                                                            transport: requestedTransport,
                                                            tab: tab)
            } catch let error as SSHConnectionError where error.stage == .keyExchange && requestedTransport == .builtin {
                // The server only offers algorithms the in-process stack refuses
                // (ssh-rsa host keys, group14-sha1 KEX). Hand the session to the
                // local OpenSSH client and remember the choice for next time.
                tab.markConnecting(L("改用系统 ssh 兼容模式"))
                established = try await establishConnection(host: host,
                                                            config: config,
                                                            transport: .system,
                                                            tab: tab)
                usedCompatibilityMode = established != nil
                if usedCompatibilityMode {
                    tab.host.transport = .system
                    try? store.save(host: tab.host)
                    reloadCatalog()
                    tab.statusDetail = config.jumps.isEmpty
                        ? L("系统 ssh 兼容模式：服务器仅支持 ssh-rsa / SHA-1 旧算法")
                        : L("系统 ssh 兼容模式：跳板机只支持 ssh-rsa / SHA-1 旧算法")
                }
            }
            guard let established else {
                tab.markDisconnected(L("已取消认证"))
                return
            }
            let client = established.client
            tab.client = client
            // Detection rides on this connection but never blocks the terminal or
            // the file browser: the sidebar glyph updates whenever the probe returns.
            detectPlatformIfNeeded(hostID: host.id, client: client)

            // An SFTP tab has no shell: skip the terminal channel entirely and
            // go straight to the file browser.
            if tab.kind == .sftp {
                tab.attachClientOnly(client: client,
                                     encoding: config.encoding,
                                     terminalType: config.terminalType,
                                     route: route)
                try? store.recordConnection(hostID: host.id)
                recentHosts = (try? store.recentHosts(limit: 20)) ?? recentHosts
                await openSFTP(tab: tab)
                await openPendingPanes(tab)
                scheduleTerminalFocus(0.2)
                return
            }

            let logger = makeSessionLogger(config: config, host: host, auth: established.auth)
            let session = try await client.openTerminal(term: config.terminalType,
                                                        columns: tab.terminalColumns,
                                                        rows: tab.terminalRows,
                                                        onData: { [weak tab] data in
                                                            Task { @MainActor in tab?.receive(data) }
                                                        },
                                                        onClose: { [weak self, weak tab] error in
                                                            Task { @MainActor in
                                                                self?.terminalDidClose(tab: tab, error: error)
                                                            }
                                                        })
            tab.attach(client: client,
                       session: session,
                       encoding: config.encoding,
                       terminalType: config.terminalType,
                       route: route,
                       logger: logger)
            // The view may have been resized again while the channel was opening;
            // push the current size so the shell never keeps the placeholder one.
            tab.resize(columns: tab.terminalColumns, rows: tab.terminalRows)
            try? store.recordConnection(hostID: host.id)
            recentHosts = (try? store.recentHosts(limit: 20)) ?? recentHosts
            tab.runStartupCommandIfNeeded()

            if tab.showsSFTP {
                await openSFTP(tab: tab)
            }
            await openPendingPanes(tab)
            // The shell owns the keyboard as soon as it is attached: without
            // this the first keystroke after a connect went to the window.
            scheduleTerminalFocus(0.2)
        } catch is CancellationError {
            tab.markDisconnected(L("已取消"))
        } catch {
            tab.markFailed(describe(error))
            present(error)
            scheduleReconnectIfNeeded(tab: tab)
        }
    }

    struct PreparedConnection {
        let options: SSHConnectOptions
        let auth: SSHAuthMaterial
        let jumpCount: Int
        let transport: HostTransport
    }

    struct EstablishedConnection {
        let client: SSHClient
        let auth: SSHAuthMaterial
        let transport: HostTransport
    }

    /// Resolves effective configuration into ready-to-use connect options,
    /// including jump hosts and proxy. Returns nil when the user cancels an
    /// authentication prompt.
    func preparedConnection(host: SSHHost,
                            config: EffectiveHostConfig,
                            allowPrompt: Bool,
                            transport: HostTransport = .builtin) async throws -> PreparedConnection? {
        let proxy = try await proxyEndpoint(for: config.proxy)
        let targetUsername = config.host.username.isEmpty ? NSUserName() : config.host.username

        switch transport {
        case .builtin:
            guard let auth = try await authMaterial(for: host, allowPrompt: allowPrompt) else { return nil }
            var jumps: [SSHJumpEndpoint] = []
            for step in config.jumps {
                let jumpUsername = step.host.username.isEmpty ? targetUsername : step.host.username
                guard let jumpAuth = try await authMaterial(for: step.host, allowPrompt: allowPrompt, fallback: auth) else {
                    return nil
                }
                jumps.append(SSHJumpEndpoint(host: step.host.hostname,
                                             port: step.host.port,
                                             username: jumpUsername,
                                             auth: jumpAuth,
                                             hostKeyValidator: hostKeyValidator(for: step.host)))
            }
            let options = SSHConnectOptions(host: config.host.hostname,
                                            port: config.host.port,
                                            username: targetUsername,
                                            auth: auth,
                                            hostKeyValidator: hostKeyValidator(for: config.host),
                                            proxy: proxy,
                                            jumps: jumps,
                                            connectTimeout: .seconds(20),
                                            keepaliveSeconds: config.keepaliveSeconds)
            return PreparedConnection(options: options, auth: auth, jumpCount: jumps.count, transport: .builtin)

        case .system:
            guard let credential = try await systemCredential(for: host, allowPrompt: allowPrompt) else { return nil }
            var jumps: [SSHJumpEndpoint] = []
            for step in config.jumps {
                let jumpUsername = step.host.username.isEmpty ? targetUsername : step.host.username
                guard let jumpCredential = try await systemCredential(for: step.host,
                                                                       allowPrompt: allowPrompt) else {
                    return nil
                }
                jumps.append(SSHJumpEndpoint(host: step.host.hostname,
                                             port: step.host.port,
                                             username: jumpUsername,
                                             auth: .none,
                                             systemCredential: jumpCredential,
                                             hostKeyValidator: { _ in .trust(remember: false) }))
            }
            let options = SSHConnectOptions(host: config.host.hostname,
                                            port: config.host.port,
                                            username: targetUsername,
                                            auth: .none,
                                            hostKeyValidator: hostKeyValidator(for: config.host),
                                            proxy: proxy,
                                            jumps: jumps,
                                            connectTimeout: .seconds(20),
                                            keepaliveSeconds: config.keepaliveSeconds,
                                            transport: .system,
                                            systemCredential: credential)
            return PreparedConnection(options: options, auth: .none, jumpCount: jumps.count, transport: .system)
        }
    }

    /// The transport a host has to use. Besides the per-host preference, a jump
    /// host that itself only speaks old algorithms forces the whole chain onto the
    /// system client: the in-process stack cannot tunnel through it either, and the
    /// builtin attempt would fail after a needless round of TCP + handshake.
    func effectiveTransport(for config: EffectiveHostConfig) -> HostTransport {
        if let explicit = config.host.transport { return explicit }
        if config.jumps.contains(where: { $0.host.transport == .system }) { return .system }
        return .builtin
    }

    /// Prepares credentials and opens the transport. Returns nil when the user
    /// cancelled a prompt.
    private func establishConnection(host: SSHHost,
                                     config: EffectiveHostConfig,
                                     transport: HostTransport,
                                     tab: TerminalTab) async throws -> EstablishedConnection? {
        tab.markConnecting(transport == .system ? L("准备系统 ssh") : L("身份认证"))
        guard let prepared = try await preparedConnection(host: host,
                                                          config: config,
                                                          allowPrompt: true,
                                                          transport: transport) else {
            return nil
        }
        try Task.checkCancellation()
        if transport == .system {
            tab.markConnecting(L("通过系统 ssh 连接"))
        } else {
            tab.markConnecting(prepared.jumpCount == 0 ? L("建立 SSH 连接") : L("经过 ") + String(prepared.jumpCount) + L(" 级跳板连接"))
        }
        let client = SSHClient(eventLoopGroup: environment.eventLoopGroup)
        do {
            try await client.connect(prepared.options)
            try Task.checkCancellation()
        } catch {
            // A failed attempt must not leave its channel or event loop handlers
            // behind, otherwise a transport fallback would double up on sockets.
            await client.shutdown()
            throw error
        }
        // The transport can die on its own long after this call returns: the peer
        // hangs up, the TCP path breaks, or a keepalive goes unanswered. Report it
        // so the tab drops stale channels and reconnects instead of staying on a
        // frozen terminal.
        await client.setDisconnectHandler { [weak self, weak tab] reason in
            Task { @MainActor in
                guard let self, let tab else { return }
                self.transportDidClose(tab: tab, client: client, reason: reason)
            }
        }
        return EstablishedConnection(client: client, auth: prepared.auth, transport: transport)
    }

    /// The tab's own transport died by itself. The terminal channel usually
    /// reports the close first, so state is only moved when the tab still looked
    /// live; the stale SFTP channels are dropped in every case.
    func transportDidClose(tab: TerminalTab, client: SSHClient, reason: String) {
        guard !tab.isClosing, tab.client === client else { return }
        let wasLive = tab.connectionState.isConnected || tab.connectionState.isBusy
        tab.client = nil
        Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            await self.invalidateSFTPChannels(tab: tab, deadClient: client)
            self.persistWorkspace()
        }
        guard wasLive else { return }
        tab.markDisconnected(reason)
        tab.logger?.close()
        scheduleReconnectIfNeeded(tab: tab)
    }

    /// One extra pane's dedicated connection died. Its client is dropped so the
    /// next refresh (or the single automatic retry) dials it again.
    func paneTransportDidClose(tab: TerminalTab, pane: RemoteBrowserModel, client: SSHClient, reason: String) {
        guard !tab.isClosing, tab.remoteClients[pane.id] === client else { return }
        tab.remoteClients[pane.id] = nil
        Task { await client.disconnect() }
        if let sftp = pane.client {
            Task { await sftp.shutdown() }
            pane.setClient(nil)
        }
        pane.connectionError = reason
        schedulePaneReconnectIfNeeded(tab: tab, pane: pane)
    }

    /// One delayed retry for a pane that lost its connection. Further failures do
    /// not queue more attempts; the pane keeps its retry button for manual ones.
    private func schedulePaneReconnectIfNeeded(tab: TerminalTab, pane: RemoteBrowserModel) {
        guard settings.autoReconnect,
              !tab.isClosing,
              tab.paneReconnectTasks[pane.id] == nil else { return }
        tab.paneReconnectTasks[pane.id] = Task { @MainActor [weak self, weak tab, weak pane] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, let tab, let pane, !tab.isClosing else { return }
            tab.paneReconnectTasks[pane.id] = nil
            await self.ensureSFTPChannel(tab: tab, pane: pane)
        }
    }

    /// Extra SFTP panes remembered from a previous session are dialled once the
    /// tab's own connection is up.
    private func openPendingPanes(_ tab: TerminalTab) async {
        guard !tab.pendingPaneHostIDs.isEmpty else { return }
        let pending = tab.pendingPaneHostIDs.compactMap { self.host(id: $0) }
        tab.pendingPaneHostIDs.removeAll()
        for extra in pending {
            await addSFTPPane(tab, host: extra)
        }
    }

    func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty {
            return description
        }
        // NIO bridges raw channel failures into "The operation couldn't be
        // completed. (NIOCore.ChannelError error 9.)"; TransportFailure turns
        // those into a cause the user can act on.
        if let detail = TransportFailure.describe(error).detail { return detail }
        // Enum-shaped NIO errors bridge to "error 9", which says nothing; their
        // description names the case (eof, ioOnClosedChannel, ...) instead.
        let described = String(describing: error)
        if !described.isEmpty, !described.contains("Error Domain="), described != error.localizedDescription {
            return described
        }
        return error.localizedDescription
    }

    func terminalDidClose(tab: TerminalTab?, error: Error?) {
        guard let tab, !tab.isClosing else { return }
        // A close triggered by our own teardown already updated the state.
        if case .idle = tab.connectionState { return }
        let reason = error.map { describe($0) } ?? L("连接已断开")
        tab.markDisconnected(reason)
        tab.logger?.close()
        scheduleReconnectIfNeeded(tab: tab)
    }

    /// Board panes are live sessions too, even though they are not in the tab strip.
    func isLive(tab: TerminalTab) -> Bool {
        tabs.contains { $0.id == tab.id } || boardSessions.contains { $0.id == tab.id }
    }

    private func scheduleReconnectIfNeeded(tab: TerminalTab) {
        // One attempt at a time: a transport failure and the terminal channel
        // close both report here, and two timers would race for the connection.
        guard settings.autoReconnect,
              !tab.isClosing,
              isLive(tab: tab),
              tab.reconnectAttempt < 6,
              tab.reconnectTask == nil else { return }
        tab.reconnectAttempt += 1
        let delay = min(30, pow(2.0, Double(tab.reconnectAttempt - 1)))
        tab.markConnecting(L("连接断开，") + String(Int(delay)) + L(" 秒后第 ") + String(tab.reconnectAttempt) + L(" 次重连"))
        tab.reconnectTask = Task { @MainActor [weak self, weak tab] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let tab else { return }
            tab.reconnectTask = nil
            guard !tab.isClosing, let self, self.isLive(tab: tab) else { return }
            // The retry set the tab's state to "reconnecting"; force bypasses the
            // busy guard, which used to make every scheduled retry a no-op.
            self.connect(tab: tab, force: true)
        }
    }

    func makeSessionLogger(config: EffectiveHostConfig, host: SSHHost, auth: SSHAuthMaterial) -> SessionLogger? {
        guard config.sessionLogging else { return nil }
        var redactions: [String] = []
        if case .password(let password) = auth { redactions.append(password) }
        return SessionLogger(directory: SessionLogger.defaultDirectory(),
                             hostName: host.name.isEmpty ? host.hostname : host.name,
                             redactions: redactions)
    }

    // MARK: - Authentication

    func authMaterial(for host: SSHHost, allowPrompt: Bool, fallback: SSHAuthMaterial? = nil) async throws -> SSHAuthMaterial? {
        switch host.authMethod {
        case .password, .keyboardInteractive:
            if let password = try? environment.secrets.secret(for: .hostPassword(host.id)) {
                return .password(password)
            }
            if let fallback { return fallback }
            guard allowPrompt else { return nil }
            guard let value = await promptForSecret(title: L("输入登录密码"),
                                                    detail: host.name + "（" + host.displayAddress + "）",
                                                    isPassphrase: false) else { return nil }
            if host.savesPassword {
                try? environment.secrets.setSecret(value, for: .hostPassword(host.id))
            }
            return .password(value)
        case .privateKey:
            if let material = try await privateKeyMaterial(for: host, allowPrompt: allowPrompt) {
                return material
            }
            return fallback
        case .agent:
            throw AppError(title: L("暂不支持 SSH Agent 认证"),
                           message: L("当前版本使用 SwiftNIO SSH，尚未实现 agent 协议转发。"),
                           suggestion: L("请在主机设置中改用私钥或密码认证。"))
        }
    }

    private struct PrivateKeySource {
        let data: Data
        let passphrase: String?
        let name: String
    }

    /// Raw key bytes plus any known passphrase, shared by the built-in stack
    /// (which parses the key) and the system transport (which hands the file to
    /// OpenSSH).
    private func privateKeySource(for host: SSHHost, allowPrompt: Bool) async throws -> PrivateKeySource? {
        var record: PrivateKeyRecord?
        if let keyID = host.keyID, let found = keys.first(where: { $0.id == keyID }) {
            record = found
        }

        var data: Data?
        if let record {
            if let storageRef = record.storageRef, storageRef.hasPrefix("file:") {
                let path = String(storageRef.dropFirst(5))
                data = try? Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            } else if let blob = try? environment.secrets.secret(for: .privateKey(record.id)) {
                data = Data(blob.utf8)
            }
        }
        if data == nil, let path = host.identityFilePath, !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            data = try? Data(contentsOf: URL(fileURLWithPath: expanded))
        }
        guard let data else {
            throw AppError(title: L("缺少私钥"),
                           message: L("主机 ") + host.name + L(" 使用私钥认证，但没有可用的私钥文件。"),
                           suggestion: L("请在主机设置中选择私钥，或先导入 ~/.ssh 下的密钥。"))
        }

        var passphrase: String?
        let needsPassphrase = record?.hasPassphrase ?? false
        if needsPassphrase {
            passphrase = try? environment.secrets.secret(for: .hostPassphrase(host.id))
            if passphrase == nil && allowPrompt {
                passphrase = await promptForSecret(title: L("输入私钥口令"),
                                                   detail: record?.name ?? L("私钥"),
                                                   isPassphrase: true)
            }
        }
        return PrivateKeySource(data: data, passphrase: passphrase, name: record?.name ?? L("私钥"))
    }

    private func privateKeyMaterial(for host: SSHHost, allowPrompt: Bool) async throws -> SSHAuthMaterial? {
        guard let source = try await privateKeySource(for: host, allowPrompt: allowPrompt) else { return nil }
        do {
            let parsed = try SSHKeyParser.parse(data: source.data, passphrase: source.passphrase)
            return .privateKey(parsed.key)
        } catch SSHKeyError.encrypted {
            guard allowPrompt, source.passphrase == nil else { throw SSHKeyError.encrypted }
            guard let entered = await promptForSecret(title: L("输入私钥口令"),
                                                      detail: source.name,
                                                      isPassphrase: true) else { return nil }
            let parsed = try SSHKeyParser.parse(data: source.data, passphrase: entered)
            if host.savesPassword {
                try? environment.secrets.setSecret(entered, for: .hostPassphrase(host.id))
            }
            return .privateKey(parsed.key)
        }
    }

    /// Credentials for the local OpenSSH client. Unlike the built-in stack it
    /// also supports agent authentication, since `ssh` speaks the protocol.
    func systemCredential(for host: SSHHost, allowPrompt: Bool) async throws -> SystemSSHCredential? {
        switch host.authMethod {
        case .password, .keyboardInteractive:
            if let password = try? environment.secrets.secret(for: .hostPassword(host.id)) {
                return .password(password)
            }
            guard allowPrompt else { return nil }
            guard let value = await promptForSecret(title: L("输入登录密码"),
                                                    detail: host.name + "（" + host.displayAddress + "）",
                                                    isPassphrase: false) else { return nil }
            if host.savesPassword {
                try? environment.secrets.setSecret(value, for: .hostPassword(host.id))
            }
            return .password(value)
        case .privateKey:
            guard let source = try await privateKeySource(for: host, allowPrompt: allowPrompt) else { return nil }
            var passphrase = source.passphrase
            do {
                _ = try SSHKeyParser.parse(data: source.data, passphrase: passphrase)
            } catch SSHKeyError.encrypted {
                guard allowPrompt, passphrase == nil else { throw SSHKeyError.encrypted }
                guard let entered = await promptForSecret(title: L("输入私钥口令"),
                                                          detail: source.name,
                                                          isPassphrase: true) else { return nil }
                passphrase = entered
                if host.savesPassword {
                    try? environment.secrets.setSecret(entered, for: .hostPassphrase(host.id))
                }
            } catch {
                // OpenSSH understands a few formats we do not; let it try.
            }
            return .key(text: String(decoding: source.data, as: UTF8.self), passphrase: passphrase)
        case .agent:
            return .agent
        }
    }

    private func promptForSecret(title: String, detail: String, isPassphrase: Bool) async -> String? {
        await withCheckedContinuation { continuation in
            self.passwordContinuation = continuation
            self.passwordPrompt = PasswordPrompt(title: title, detail: detail, isPassphrase: isPassphrase)
        }
    }

    // MARK: - Proxy

    private func proxyEndpoint(for proxy: ProxyConfig?) async throws -> ProxyEndpoint? {
        guard let proxy else { return nil }
        var password: String?
        if proxy.savesPassword {
            password = try? environment.secrets.secret(for: .proxyPassword(proxy.id))
            if password == nil && !proxy.username.isEmpty {
                password = await promptForSecret(title: L("输入代理密码"),
                                                 detail: proxy.name + "（" + proxy.host + ":" + String(proxy.port) + "）",
                                                 isPassphrase: false)
                if let password {
                    try? environment.secrets.setSecret(password, for: .proxyPassword(proxy.id))
                }
            }
        }
        return ProxyEndpoint(type: proxy.type,
                             host: proxy.host,
                             port: proxy.port,
                             username: proxy.username.isEmpty ? nil : proxy.username,
                             password: password)
    }

    /// Endpoint for the "test" buttons in the proxy editor and settings.
    /// Reads the saved password but never prompts: a modal in the middle of a
    /// probe would be confusing, and the editor passes the password still in its
    /// field explicitly.
    func proxyEndpointForTesting(_ proxy: ProxyConfig, password: String? = nil) -> ProxyEndpoint {
        let saved = proxy.savesPassword
            ? (try? environment.secrets.secret(for: .proxyPassword(proxy.id)))
            : nil
        return ProxyEndpoint(type: proxy.type,
                             host: proxy.host,
                             port: proxy.port,
                             username: proxy.username.isEmpty ? nil : proxy.username,
                             password: password ?? saved)
    }

    func testProxy(_ proxy: ProxyConfig,
                   password: String? = nil,
                   targetHost: String,
                   targetPort: Int) async -> ProxyProbeResult {
        await ProxyProbe.test(proxyEndpointForTesting(proxy, password: password),
                              targetHost: targetHost,
                              targetPort: targetPort)
    }

    // MARK: - Host keys

    func hostKeyValidator(for host: SSHHost) -> HostKeyValidator {
        { @Sendable info in
            await self.validateHostKey(info)
        }
    }

    func validateHostKey(_ info: HostKeyInfo) async -> HostKeyDecision {
        let hostPort = info.host + ":" + String(info.port)
        let stored = try? store.hostKey(hostPort: hostPort, keyType: info.keyType)
        if let stored, stored.fingerprintSHA256 == info.fingerprintSHA256 {
            return .trust(remember: false)
        }
        let changed = stored != nil
        let decision = await withCheckedContinuation { continuation in
            self.hostKeyContinuation = continuation
            self.hostKeyPrompt = HostKeyPrompt(info: info,
                                               previousFingerprint: stored?.fingerprintSHA256,
                                               isChanged: changed)
        }
        if case .trust(let remember) = decision, remember {
            let entry = KnownHostEntry(hostPort: hostPort,
                                       keyType: info.keyType,
                                       fingerprintSHA256: info.fingerprintSHA256,
                                       publicKeyBase64: Self.base64KeyBody(info.openSSHPublicKey))
            try? store.save(hostKey: entry)
            knownHosts = (try? store.hostKeys()) ?? knownHosts
        }
        return decision
    }

    private static func base64KeyBody(_ openSSH: String) -> String {
        let parts = openSSH.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : ""
    }

    func forgetHostKey(_ entry: KnownHostEntry) {
        try? store.deleteHostKey(hostPort: entry.hostPort, keyType: entry.keyType)
        knownHosts = (try? store.hostKeys()) ?? knownHosts
    }

    // MARK: - SFTP

    func toggleSFTP(_ tab: TerminalTab) {
        if tab.showsSFTP {
            tab.showsSFTP = false
            return
        }
        tab.showsSFTP = true
        // refreshSFTP re-dials a dead connection, so revealing the panel after a
        // dropped link no longer leaves an empty browser behind.
        Task { await refreshSFTP(tab: tab) }
    }

    func openSFTP(tab: TerminalTab) async {
        await openSFTP(tab: tab, pane: tab.remote)
    }

    /// Opens (or reveals) the SFTP subsystem for one pane. The main pane rides
    /// on the tab's terminal connection; extra panes each own a connection.
    /// A pane whose transport died is dialled again rather than written off.
    func openSFTP(tab: TerminalTab, pane: RemoteBrowserModel) async {
        if await sftpChannelIsUsable(tab: tab, pane: pane) {
            tab.showsSFTP = true
            return
        }
        if let stale = pane.client {
            // The subsystem channel is closed; drop it before dialling again.
            Task { await stale.shutdown() }
            pane.setClient(nil)
        }
        pane.connectionError = nil
        let isMain = pane === tab.remote
        let client: SSHClient
        if isMain {
            guard let existing = tab.client, await existing.isConnected else {
                // The tab's own connection is gone. Reconnecting the tab reopens
                // every pane through performConnect, so only ask for that.
                tab.showsSFTP = true
                tab.client = nil
                pane.connectionError = L("连接已断开，正在重新连接…")
                connect(tab: tab)
                return
            }
            client = existing
        } else {
            guard let hostID = pane.hostID, let host = host(id: hostID) else {
                pane.connectionError = L("主机已被删除，无法重新连接。")
                return
            }
            do {
                if let existing = tab.remoteClients[pane.id], await existing.isConnected {
                    client = existing
                } else {
                    if let dead = tab.remoteClients.removeValue(forKey: pane.id) {
                        Task { await dead.disconnect() }
                    }
                    client = try await paneConnection(tab: tab, host: host, pane: pane)
                }
            } catch {
                pane.connectionError = describe(error)
                return
            }
        }

        pane.isConnecting = true
        tab.sftpLoading = true
        defer {
            pane.isConnecting = false
            tab.sftpLoading = false
        }
        do {
            let sftp = try await client.openSFTP()
            if isMain {
                tab.attach(sftp: sftp)
            } else {
                pane.setClient(sftp)
            }
            tab.showsSFTP = true
            configureSFTPHistory(for: pane)
            // Reopen the folder this host was last browsed in; fall back to the
            // host/group default only when there is no history yet.
            let remembered = lastSFTPPath(for: pane.hostID)
            let hostDefault = pane.hostID.flatMap { host(id: $0) }?.startDirectory
            let start = isMain
                ? (remembered ?? tab.lastRemoteDirectory ?? tab.host.startDirectory)
                : (pane.startDirectory ?? remembered ?? hostDefault)
            await pane.attach(client: sftp, startDirectory: start)
            recordSFTPPath(pane.path, for: pane.hostID)
            if isMain {
                tab.lastRemoteDirectory = pane.path
                tab.local.reload()
                persistWorkspace()
            }
        } catch {
            // An extra pane reports inline with a retry button: a modal for a
            // server the user just added interrupts whatever else they were
            // doing in the other panes.
            let text = describe(error)
            pane.connectionError = text
            if isMain {
                presentMessage(L("打开 SFTP 失败"), text)
            }
        }
    }

    func refreshSFTP(tab: TerminalTab) async {
        await refreshSFTP(tab: tab, pane: tab.remote)
    }

    /// Reloads a pane, reopening its connection first when the transport died.
    /// Refreshing a dead pane now re-dials instead of doing nothing.
    func refreshSFTP(tab: TerminalTab, pane: RemoteBrowserModel) async {
        let ready = await ensureSFTPChannel(tab: tab, pane: pane)
        guard ready else { return }
        await pane.refresh()
        recordSFTPPath(pane.path, for: pane.hostID)
        if pane === tab.remote {
            tab.lastRemoteDirectory = pane.path
            persistWorkspace()
        }
    }

    /// True when the pane has a live SFTP channel on a live transport.
    private func sftpChannelIsUsable(tab: TerminalTab, pane: RemoteBrowserModel) async -> Bool {
        guard let sftp = pane.client, !(await sftp.isClosed) else { return false }
        guard let ssh = tab.sshClient(for: pane), await ssh.isConnected else { return false }
        return true
    }

    /// Makes sure the pane can browse, reopening the subsystem when needed.
    /// Returns whether a usable channel is in place afterwards.
    @discardableResult
    func ensureSFTPChannel(tab: TerminalTab, pane: RemoteBrowserModel) async -> Bool {
        guard !(await sftpChannelIsUsable(tab: tab, pane: pane)) else { return true }
        await openSFTP(tab: tab, pane: pane)
        guard let sftp = pane.client else { return false }
        return !(await sftp.isClosed)
    }

    /// Drops the SFTP channels that rode on a transport that is now gone and
    /// tells the affected panes why they are empty.
    func invalidateSFTPChannels(tab: TerminalTab, deadClient: SSHClient?) async {
        for pane in tab.allRemotes {
            guard let sftp = pane.client else { continue }
            let ssh = tab.sshClient(for: pane)
            let alive: Bool
            if let ssh, ssh !== deadClient {
                alive = await ssh.isConnected
            } else {
                alive = false
            }
            if alive { continue }
            await sftp.shutdown()
            pane.setClient(nil)
            pane.connectionError = L("连接已断开，点击刷新重新连接。")
        }
    }

    /// Adds another remote pane to the tab, connecting on demand. Reusing the
    /// tab's own connection when the host matches keeps extra panes cheap.
    func addSFTPPane(_ tab: TerminalTab, host: SSHHost, startDirectory: String? = nil) async {
        if let existing = tab.allRemotes.first(where: { $0.hostID == host.id }) {
            tab.showsSFTP = true
            await refreshSFTP(tab: tab, pane: existing)
            return
        }
        let pane = RemoteBrowserModel()
        pane.hostID = host.id
        pane.hostName = TerminalTab.label(for: host)
        pane.showHidden = tab.remote.showHidden
        // nil means "decide when connecting": remembered folder first, then the
        // host default (resolved in openSFTP).
        pane.startDirectory = startDirectory
        pane.isConnecting = true
        tab.extraRemotes.append(pane)
        tab.showsSFTP = true
        defer { pane.isConnecting = false }
        do {
            let client = try await paneConnection(tab: tab, host: host, pane: pane)
            let sftp = try await client.openSFTP()
            pane.setClient(sftp)
            configureSFTPHistory(for: pane)
            let start = pane.startDirectory
                ?? lastSFTPPath(for: host.id)
                ?? host.startDirectory
            await pane.attach(client: sftp, startDirectory: start)
            recordSFTPPath(pane.path, for: pane.hostID)
        } catch is CancellationError {
            pane.connectionError = L("已取消连接")
        } catch {
            let text = describe(error)
            pane.connectionError = text
            presentMessage(L("打开 SFTP 失败（") + host.name + "）", text)
        }
    }

    private func paneConnection(tab: TerminalTab, host: SSHHost, pane: RemoteBrowserModel) async throws -> SSHClient {
        if host.id == tab.hostID, let existing = tab.client, await existing.isConnected {
            return existing
        }
        if let existing = tab.remoteClients[pane.id] {
            if await existing.isConnected { return existing }
            tab.remoteClients[pane.id] = nil
            Task { await existing.disconnect() }
        }
        let resolver = ConfigResolver(catalog: Catalog(groups: groups, hosts: hosts, proxies: proxies, keys: keys))
        let config = try resolver.effective(for: host)
        let transport = effectiveTransport(for: config)
        let client: SSHClient
        do {
            client = try await connectPane(host: host, config: config, transport: transport)
        } catch let error as SSHConnectionError where error.stage == .keyExchange && transport == .builtin {
            client = try await connectPane(host: host, config: config, transport: .system)
            var updated = host
            updated.transport = .system
            try? store.save(host: updated)
            reloadCatalog()
        }
        tab.remoteClients[pane.id] = client
        // Extra panes own their transport, so they watch it themselves instead of
        // relying on the tab's terminal channel to report the loss.
        await client.setDisconnectHandler { [weak self, weak tab, weak pane] reason in
            Task { @MainActor in
                guard let self, let tab, let pane else { return }
                self.paneTransportDidClose(tab: tab, pane: pane, client: client, reason: reason)
            }
        }
        try? store.recordConnection(hostID: host.id)
        recentHosts = (try? store.recentHosts(limit: 20)) ?? recentHosts
        return client
    }

    private func connectPane(host: SSHHost, config: EffectiveHostConfig, transport: HostTransport) async throws -> SSHClient {
        guard let prepared = try await preparedConnection(host: host,
                                                          config: config,
                                                          allowPrompt: true,
                                                          transport: transport) else {
            throw CancellationError()
        }
        let client = SSHClient(eventLoopGroup: environment.eventLoopGroup)
        do {
            try await client.connect(prepared.options)
        } catch {
            await client.shutdown()
            throw error
        }
        return client
    }

    func closeSFTPPane(_ tab: TerminalTab, pane: RemoteBrowserModel) {
        guard pane !== tab.remote else { return }
        tab.removeRemotePane(pane)
        persistWorkspace()
    }
}
