import SwiftUI
import AppKit
import TaugeKit

/// Sheet for creating or editing one host.
///
/// The sheet only shows what changes how a connection behaves (address, user,
/// auth, proxy, jump chain). Rarer knobs live
/// behind "高级", which is collapsed by default.
struct HostEditorView: View {
    @EnvironmentObject private var app: AppState
    @ViewState private var host: SSHHost
    @ViewState private var password = ""
    @ViewState private var passphrase = ""
    @ViewState private var validationMessage: String?
    @ViewState private var jumpQuery = ""
    @ViewState private var editorSheet: HostEditorSheet?
    @ViewState private var showsAdvanced = false

    private enum HostEditorSheet: Identifiable {
        case proxy(ProxyConfig)
        case group(HostGroup)

        var id: String {
            switch self {
            case .proxy(let proxy): return "proxy-" + proxy.id.uuidString
            case .group(let group): return "group-" + group.id.uuidString
            }
        }
    }

    init(host: SSHHost) {
        _host = ViewState(wrappedValue: host)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(host.name.isEmpty ? L("新建主机") : host.name)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(L("取消")) { app.editingHost = nil }
                    .keyboardShortcut(.cancelAction)
                Button(L("保存")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    connectionSection
                    authSection
                    proxySection
                    jumpSection
                    advancedSection
                    if let validationMessage {
                        Text(validationMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.danger)
                    }
                }
                .padding(16)
            }
        }
        // The sheet paints its own canvas: the window background is not part of
        // the content view, so without this the form floats on whatever the
        // window shows through and thin secondary labels lose their contrast.
        .background(Theme.windowBackground)
        .frame(width: 620, height: 620)
        .sheet(item: $editorSheet) { sheet in
            switch sheet {
            case .proxy(let draft):
                ProxyEditorView(
                    proxy: draft,
                    onSave: { proxy, secret in
                        if !secret.isEmpty {
                            try? app.environment.secrets.setSecret(
                                secret,
                                for: .proxyPassword(proxy.id)
                            )
                        }
                        app.saveProxy(proxy)
                        host.proxyPolicy = .use(proxy.id)
                        editorSheet = nil
                    },
                    onCancel: { editorSheet = nil }
                )
                .environmentObject(app)
            case .group(let group):
                GroupEditorView(
                    group: group,
                    onSave: { saved in
                        app.saveGroup(saved)
                        editorSheet = nil
                    },
                    onCancel: { editorSheet = nil }
                )
                .environmentObject(app)
            }
        }
    }

    // MARK: - Sections

    private var connectionSection: some View {
        section(L("连接")) {
            labeled(L("名称")) {
                TextField(L("例如 生产环境 Web"), text: $host.name)
                    .textFieldStyle(.roundedBorder)
            }
            labeled(L("地址")) {
                HStack(spacing: 6) {
                    TextField(L("example.com 或 10.0.0.1"), text: $host.hostname)
                        .textFieldStyle(.roundedBorder)
                    Text(L("端口"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                    TextField("22", value: $host.port, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 62)
                }
            }
            labeled(L("用户名")) {
                TextField("root", text: $host.username)
                    .textFieldStyle(.roundedBorder)
            }
            labeled(L("分组")) {
                HStack(spacing: 6) {
                    Picker("", selection: $host.groupID) {
                        Text(L("未分组")).tag(UUID?.none)
                        ForEach(app.groups) { group in
                            Text(app.groupPath(for: group.id)).tag(Optional(group.id))
                        }
                    }
                    .labelsHidden()
                    Button(L("编辑分组…")) { editSelectedGroup() }
                        .font(.system(size: 11))
                        .disabled(host.groupID == nil)
                }
            }
            ColorChoicePicker(colorHex: $host.colorHex)
        }
    }

    private var authSection: some View {
        section(L("认证")) {
            labeled(L("方式")) {
                Picker("", selection: $host.authMethod) {
                    ForEach(AuthMethod.allCases, id: \.self) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                .labelsHidden()
            }
            switch host.authMethod {
            case .password, .keyboardInteractive:
                labeled(L("密码")) {
                    SecureField(L("留空则使用已保存的密码"), text: $password)
                        .textFieldStyle(.roundedBorder)
                }
                labeled("") {
                    Toggle(L("保存密码到凭据库"), isOn: $host.savesPassword)
                        .font(.system(size: 11))
                }
            case .privateKey:
                labeled(L("私钥")) {
                    Picker("", selection: keySelection) {
                        Text(L("磁盘上的私钥文件")).tag(UUID?.none)
                        ForEach(app.keys) { key in
                            Text(key.name).tag(Optional(key.id))
                        }
                    }
                    .labelsHidden()
                }
                if host.keyID == nil {
                    labeled(L("路径")) {
                        HStack(spacing: 6) {
                            TextField("~/.ssh/id_rsa", text: identityPath)
                                .textFieldStyle(.roundedBorder)
                            Button(L("选择…")) { chooseKeyFile() }
                                .font(.system(size: 11))
                        }
                    }
                }
                labeled(L("口令")) {
                    SecureField(L("私钥口令（可选）"), text: $passphrase)
                        .textFieldStyle(.roundedBorder)
                }
            case .agent:
                Text(L("使用 ssh-agent 里的密钥；需要系统 ssh 连接方式，或在内置实现里可用且已加载的 agent 密钥。"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var proxySection: some View {
        section(L("代理")) {
            labeled(L("代理")) {
                HStack(spacing: 6) {
                    Picker("", selection: proxySelection) {
                        Text(L("不使用代理")).tag("direct")
                        Text(L("继承分组设置")).tag("inherit")
                        ForEach(app.proxies) { proxy in
                            Text(proxy.name + " · " + proxy.endpointDescription).tag(proxy.id.uuidString)
                        }
                    }
                    .labelsHidden()
                    Menu {
                        Button(L("HTTP 代理…")) { beginNewProxy(.http) }
                        Button(L("HTTPS 代理…")) { beginNewProxy(.https) }
                        Button(L("SOCKS5 代理…")) { beginNewProxy(.socks5) }
                        Button(L("SOCKS5（远端 DNS）…")) { beginNewProxy(.socks5h) }
                    } label: {
                        Label(L("新建"), systemImage: "plus")
                            .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            if let selectedProxy {
                ProxyTestView(proxy: selectedProxy,
                              defaultTarget: host.hostname.isEmpty
                                  ? "example.com:443"
                                  : host.hostname + ":" + String(host.port))
                    .padding(.leading, 72)
            }
            Text(L("代理只作用于连接的第一跳 TCP，优先级：主机 > 分组 > 全局。")
                 + L("代理与跳板机只能二选一：选了代理，下面的跳板机会被清空。")
                 + L("连接失败时先点上面的「测试连通性」，它能把代理不可达和代理拒绝隧道分开。"))
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 72)
        }
    }

    /// The concrete proxy the picker currently resolves to, if any.
    private var selectedProxy: ProxyConfig? {
        guard case .use(let id) = host.proxyPolicy else { return nil }
        return app.proxies.first { $0.id == id }
    }

    private var jumpSection: some View {
        section(L("跳板机")) {
            labeled(L("方式")) {
                Picker("", selection: jumpSelection) {
                    Text(L("直连")).tag("direct")
                    Text(L("继承分组设置")).tag("inherit")
                    Text(L("指定跳板机")).tag("custom")
                }
                .labelsHidden()
            }
            if host.jumpPolicy.isInherit {
                Text(inheritedJumpDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 72)
            }
            if case .hosts(let ids) = host.jumpPolicy {
                VStack(alignment: .leading, spacing: 8) {
                    if ids.isEmpty {
                        Text(L("按顺序经过 1–3 台主机；在下面输入名称或地址搜索，不会列出全部主机。"))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        jumpChips(ids)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.secondary)
                        TextField(L("搜索主机（名称或地址）"), text: $jumpQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                        if !jumpQuery.isEmpty {
                            Button { jumpQuery = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.fieldBackground))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.separator))
                    if !jumpQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        jumpResults(ids)
                    }
                }
                .padding(.leading, 72)
            }
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { showsAdvanced.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showsAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(L("高级"))
                        .font(.system(size: 11, weight: .semibold))
                    Text(L("连接方式、终端、保活"))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)

            if showsAdvanced {
                VStack(alignment: .leading, spacing: 8) {
                    labeled(L("连接方式")) {
                        Picker("", selection: transportSelection) {
                            Text(L("自动（推荐）")).tag("auto")
                            ForEach(HostTransport.allCases, id: \.self) { transport in
                                Text(transport.displayName).tag(transport.rawValue)
                            }
                        }
                        .labelsHidden()
                    }
                    Text(transportHint)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 72)
                    labeled(L("终端类型")) {
                        TextField("xterm-256color", text: terminalTypeText)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeled(L("编码")) {
                        Picker("", selection: encodingSelection) {
                            Text(L("继承分组")).tag("inherit")
                            ForEach(TextEncodingKind.allCases, id: \.self) { kind in
                                Text(kind.displayName).tag(kind.rawValue)
                            }
                        }
                        .labelsHidden()
                    }
                    labeled(L("起始目录")) {
                        TextField(L("（可选）"), text: stringBinding(\.startDirectory))
                            .textFieldStyle(.roundedBorder)
                    }
                    labeled(L("启动命令")) {
                        TextField(L("（可选）"), text: stringBinding(\.startupCommand))
                            .textFieldStyle(.roundedBorder)
                    }
                    labeled(L("上传目录")) {
                        TextField(L("（可选）"), text: stringBinding(\.defaultUploadDirectory))
                            .textFieldStyle(.roundedBorder)
                    }
                    labeled(L("保活")) {
                        Picker("", selection: keepaliveSelection) {
                            Text(L("继承分组")).tag(0)
                            Text(L("关闭")).tag(-1)
                            Text(L("每 30 秒")).tag(30)
                            Text(L("每 60 秒")).tag(60)
                            Text(L("每 300 秒")).tag(300)
                        }
                        .labelsHidden()
                    }
                    labeled("") {
                        Toggle(L("记录会话日志"), isOn: sessionLoggingBinding)
                            .font(.system(size: 11))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.fieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.separator))
            }
        }
    }

    // MARK: - Jump chain widgets

    private func jumpChips(_ ids: [UUID]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                if index > 0 {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.secondary)
                }
                if let jump = app.host(id: id) {
                    HStack(spacing: 4) {
                        Text(jump.name)
                            .font(.system(size: 11))
                        Button { toggleJump(id, on: false) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.secondary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.accent.opacity(0.14)))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func jumpResults(_ ids: [UUID]) -> some View {
        let matches = jumpMatches(excluding: ids)
        return VStack(alignment: .leading, spacing: 0) {
            if matches.isEmpty {
                Text(L("没有匹配的主机"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
                    .padding(8)
            } else {
                ForEach(matches) { candidate in
                    Button {
                        toggleJump(candidate.id, on: true)
                        jumpQuery = ""
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 10))
                            Text(candidate.name)
                                .font(.system(size: 11))
                            Text(candidate.displayAddress)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.secondary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.fieldBackground))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.separator))
    }

    private func jumpMatches(excluding ids: [UUID]) -> [SSHHost] {
        let query = jumpQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        return Array(app.hosts.filter { candidate in
            candidate.id != host.id
                && !ids.contains(candidate.id)
                && (candidate.name.lowercased().contains(query)
                    || candidate.displayAddress.lowercased().contains(query))
        }.prefix(6))
    }

    // MARK: - Bindings

    private var proxySelection: Binding<String> {
        Binding(get: {
            switch host.proxyPolicy {
            case .inherit: return "inherit"
            case .direct: return "direct"
            case .use(let id): return id.uuidString
            }
        }, set: { value in
            switch value {
            case "inherit": host.proxyPolicy = .inherit
            case "direct": host.proxyPolicy = .direct
            default:
                guard let id = UUID(uuidString: value) else { return }
                host.proxyPolicy = .use(id)
                // Picking a proxy replaces the jump chain: they are two ways to
                // reach the first hop, not two stages of one route.
                host.jumpPolicy = RouteRules.jumpPolicy(afterSelectingProxy: .use(id), current: host.jumpPolicy)
                validationMessage = nil
            }
        })
    }

    private var jumpSelection: Binding<String> {
        Binding(get: {
            switch host.jumpPolicy {
            case .inherit: return "inherit"
            case .direct: return "direct"
            case .hosts: return "custom"
            }
        }, set: { value in
            switch value {
            case "inherit": host.jumpPolicy = .inherit
            case "custom":
                if case .hosts = host.jumpPolicy { return }
                host.jumpPolicy = .hosts([])
            default:
                host.jumpPolicy = .direct
                validationMessage = nil
            }
        })
    }

    private var keySelection: Binding<UUID?> {
        Binding(get: { host.keyID }, set: { host.keyID = $0 })
    }

    private var identityPath: Binding<String> {
        Binding(get: { host.identityFilePath ?? "" },
                set: { host.identityFilePath = $0.isEmpty ? nil : $0 })
    }

    private var transportSelection: Binding<String> {
        Binding(get: {
            switch host.transport {
            case .none: return "auto"
            case .some(.builtin): return "builtin"
            case .some(.system): return "system"
            }
        }, set: { value in
            switch value {
            case "builtin": host.transport = .builtin
            case "system": host.transport = .system
            default: host.transport = nil
            }
        })
    }

    private var transportHint: String {
        switch host.transport {
        case .none:
            return L("默认先用内置实现；遇到只支持旧算法（ssh-rsa / diffie-hellman-group14-sha1）的服务器，会在连接失败时提示并改用系统 ssh。")
        case .some(let transport):
            return transport.detail
        }
    }

    private var terminalTypeText: Binding<String> {
        Binding(get: { host.terminalType ?? "" },
                set: { host.terminalType = $0.isEmpty ? nil : $0 })
    }

    private var encodingSelection: Binding<String> {
        Binding(get: { host.encoding?.rawValue ?? "inherit" },
                set: { host.encoding = $0 == "inherit" ? nil : TextEncodingKind(rawValue: $0) })
    }

    private var keepaliveSelection: Binding<Int> {
        Binding(get: { host.keepaliveSeconds ?? 0 },
                set: { host.keepaliveSeconds = $0 == 0 ? nil : ($0 < 0 ? nil : $0) })
    }

    private var sessionLoggingBinding: Binding<Bool> {
        Binding(get: { host.sessionLoggingEnabled ?? false },
                set: { host.sessionLoggingEnabled = $0 })
    }

    private func stringBinding(_ path: WritableKeyPath<SSHHost, String?>) -> Binding<String> {
        Binding(get: { host[keyPath: path] ?? "" },
                set: { host[keyPath: path] = $0.isEmpty ? nil : $0 })
    }

    // MARK: - Group defaults

    private func editSelectedGroup() {
        guard let id = host.groupID, let group = app.group(id: id) else { return }
        editorSheet = .group(group)
    }

    private var inheritedJumpDescription: String {
        guard let groupID = host.groupID else { return L("未分组，等同直连") }
        var visited: Set<UUID> = []
        var currentID: UUID? = groupID
        while let id = currentID, let group = app.group(id: id), visited.insert(id).inserted {
            switch group.defaults.jumpPolicy {
            case .direct:
                return L("继承自「%@」：直连", group.name)
            case .hosts(let ids) where !ids.isEmpty:
                return L("继承自「%@」：%@", group.name, jumpNames(ids))
            case .hosts:
                return L("继承自「%@」：直连", group.name)
            case .inherit:
                currentID = group.parentID
            }
        }
        return L("上级分组未设置跳板机，等同直连")
    }

    private func jumpNames(_ ids: [UUID]) -> String {
        ids.map { app.host(id: $0)?.name ?? L("已失效的跳板机") }
            .joined(separator: " → ")
    }

    // MARK: - Actions

    private func beginNewProxy(_ type: ProxyType) {
        var proxy = ProxyConfig(name: type.displayName, type: type)
        proxy.port = type.defaultPort
        editorSheet = .proxy(proxy)
    }

    private func toggleJump(_ id: UUID, on: Bool) {
        var ids: [UUID] = {
            if case .hosts(let ids) = host.jumpPolicy { return ids }
            return []
        }()
        if on {
            guard !ids.contains(id) else { return }
            guard ids.count < 3 else {
                validationMessage = L("最多只能串联 3 台跳板机")
                return
            }
            ids.append(id)
        } else {
            ids.removeAll { $0 == id }
        }
        validationMessage = nil
        host.jumpPolicy = .hosts(ids)
        // Selecting the first jump host wins over a previously chosen proxy.
        host.proxyPolicy = RouteRules.proxyPolicy(afterSelectingJump: host.jumpPolicy, current: host.proxyPolicy)
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = L("选择用于认证的私钥文件")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        host.identityFilePath = url.path
        host.keyID = nil
    }

    private func save() {
        let name = host.name.trimmingCharacters(in: .whitespaces)
        let address = host.hostname.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty || !address.isEmpty else {
            validationMessage = L("请至少填写名称或地址")
            return
        }
        if !address.isEmpty && host.port <= 0 {
            validationMessage = L("端口需要是大于 0 的整数")
            return
        }
        host.name = name
        host.hostname = address
        // Imported or hand-edited hosts may carry both; keep the proxy.
        let route = RouteRules.normalized(proxy: host.proxyPolicy, jump: host.jumpPolicy)
        host.proxyPolicy = route.proxy
        host.jumpPolicy = route.jump
        if !password.isEmpty {
            try? app.environment.secrets.setSecret(password, for: .hostPassword(host.id))
        }
        if !passphrase.isEmpty {
            try? app.environment.secrets.setSecret(passphrase, for: .hostPassphrase(host.id))
        }
        app.saveHost(host)
    }

    // MARK: - Small helpers

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardStroke))
        }
    }

    private func labeled<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if title.isEmpty {
                Spacer().frame(width: 64)
            } else {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
            content()
        }
    }
}
