import SwiftUI
import AppKit
import TaugeKit

/// Sheet for creating or editing one host.
///
/// Connection settings are divided into sections around a live host summary.
struct HostEditorView: View {
    @EnvironmentObject private var app: AppState
    @ViewState private var host: SSHHost
    @ViewState private var password = SavedCredentialDraft()
    @ViewState private var passphrase = SavedCredentialDraft()
    @ViewState private var loadedCredentials = false
    @ViewState private var credentialError: String?
    @ViewState private var validationMessage: String?
    @ViewState private var jumpQuery = ""
    @ViewState private var editorSheet: HostEditorSheet?
    @ViewState private var selectedSection: EditorSection = .connection
    @ViewState private var tagsText: String
    @ViewState private var portText: String
    @FocusState private var focusedField: EditorField?
    private let originallySavesPassword: Bool

    private enum EditorField: Hashable {
        case name, user, address, port, identityPath, jumpQuery
        case terminalType, startDirectory, uploadDirectory, startupCommand, tags, notes
    }

    private enum EditorSection: String, CaseIterable {
        case connection, authentication, route, advanced

        var title: String {
            switch self {
            case .connection: return L("连接")
            case .authentication: return L("认证")
            case .route: return L("代理与跳板")
            case .advanced: return L("高级")
            }
        }

        var icon: String {
            switch self {
            case .connection: return "powerplug"
            case .authentication: return "key"
            case .route: return "arrow.triangle.branch"
            case .advanced: return "slider.horizontal.3"
            }
        }
    }

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
        _tagsText = ViewState(initialValue: host.tags.filter { !Self.isFavoriteTag($0) }.joined(separator: ", "))
        _portText = ViewState(initialValue: String(host.port))
        originallySavesPassword = host.savesPassword
    }

    private var inheritedColorHex: String? {
        HostColor.inheritedHex(forGroupID: host.groupID, groups: app.groups)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Theme.separator.frame(height: 1)
            VStack(alignment: .leading, spacing: 15) {
                sectionPicker
                if let message = validationMessage ?? credentialError {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("host-editor-validation")
                }
                HStack(alignment: .top, spacing: 18) {
                    ScrollView {
                        selectedForm
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 12)
                            .padding(.trailing, 4)
                    }
                    .id(selectedSection)
                    connectionSummary
                        .frame(width: 194)
                }
            }
            .padding(20)
        }
        .background(Theme.windowBackground)
        .frame(width: 810, height: 570)
        .onAppear { loadCredentials() }
        .sheet(item: $editorSheet) { sheet in
            switch sheet {
            case .proxy(let draft):
                ProxyEditorView(
                    proxy: draft,
                    onSave: { proxy in
                        proxySelection.wrappedValue = proxy.id.uuidString
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

    @ViewBuilder
    private var selectedForm: some View {
        switch selectedSection {
        case .connection: connectionSection
        case .authentication: authSection
        case .route: routingSection
        case .advanced: advancedSection
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 5) {
                Label(host.name.isEmpty ? L("主机") : host.name, systemImage: "server.rack")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Text(app.host(id: host.id) == nil ? L("新建主机") : L("编辑主机"))
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.5)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 12)
            Button(L("取消")) { app.editingHost = nil }
                .buttonStyle(EditorButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button {
                save()
            } label: {
                Label(L("保存"), systemImage: "checkmark")
            }
            .buttonStyle(EditorButtonStyle(prominent: true))
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.regular)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.titleBarGradient)
    }

    private var sectionPicker: some View {
        HStack(spacing: 4) {
            ForEach(EditorSection.allCases, id: \.self) { item in
                Button {
                    selectedSection = item
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                            .accessibilityHidden(true)
                        Text(item.title)
                            .font(.system(size: 12, weight: selectedSection == item ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .foregroundStyle(selectedSection == item ? Color.primary : Theme.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 29)
                    .background(selectedSection == item ? Theme.cardBackground : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(selectedSection == item ? Theme.separator : .clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedSection == item ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.tabRailBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.separator, lineWidth: 1))
    }

    private var connectionSummary: some View {
        let resolved = HostColor.resolve(host: host, groups: app.groups)
        let tint = resolved.flatMap { Color(hex: $0.hex) } ?? Theme.secondary
        let platform = app.platformInfo(for: host.id)
        return VStack(alignment: .leading, spacing: 10) {
            Text(L("连接概览"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            HStack(spacing: 8) {
                HostPlatformIcon(platform: platform?.platform, detail: platform?.detail, size: 18, fallbackColor: tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(tint.opacity(0.24), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(host.name.isEmpty ? L("新主机") : host.name)
                        .font(.system(size: 12, weight: .semibold))
                    Text(host.displayAddress)
                        .font(TechFont.mono(10.5))
                        .foregroundStyle(Theme.secondary)
                        .truncationMode(.middle)
                }
                .lineLimit(1)
            }
            summaryRow(L("操作系统"), platform?.platform.displayName ?? L("登录后自动识别操作系统"))
            summaryRow(L("分组"), app.groupPath(for: host.groupID))
            summaryRow(L("配色来源"), colorSource(resolved))
            summaryRow(L("连接方式"), routeSummary)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panelBackground, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.separator, lineWidth: 1))
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Theme.separator.frame(height: 1)
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            Text(value).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func colorSource(_ resolved: HostColor.Resolution?) -> String {
        switch resolved?.source {
        case .host: return L("主机自定义")
        case .group(_, let name): return L("继承「%@」", name)
        case nil: return L("默认配色")
        }
    }

    private var routeSummary: String {
        if case .use = host.proxyPolicy { return app.proxyName(for: host.proxyPolicy) }
        if case .hosts = host.jumpPolicy { return app.jumpDescription(for: host.jumpPolicy) }
        if host.proxyPolicy == .inherit || host.jumpPolicy == .inherit { return L("继承分组设置") }
        return L("直连")
    }

    // MARK: - Sections

    private var connectionSection: some View {
        section(L("连接信息")) {
            fieldPair {
                textField(L("名称"), L("例如 生产环境 Web"), text: $host.name, focus: .name)
                textField(L("用户名"), "root", text: $host.username, focus: .user)
            }
            fieldPair {
                textField(L("地址"), L("example.com 或 10.0.0.1"), text: $host.hostname,
                          focus: .address, monospaced: true)
                textField(L("端口"), "22", text: $portText, focus: .port, monospaced: true)
            }

            let groups: [(UUID?, String)] = [(nil, L("未分组"))]
                + app.groups.map { (Optional($0.id), app.groupPath(for: $0.id)) }
            field(L("分组")) {
                HStack(spacing: 8) {
                    choice(L("分组"), selection: $host.groupID, options: groups)
                    Button(L("编辑分组…")) { editSelectedGroup() }
                        .buttonStyle(EditorButtonStyle())
                        .fixedSize()
                        .disabled(host.groupID == nil)
                }
            }

            Theme.separator.frame(height: 1)
            ColorChoicePicker(colorHex: $host.colorHex, inheritedHex: inheritedColorHex)
                .padding(.vertical, 3)
        }
    }

    private var authSection: some View {
        section(L("认证")) {
            field(L("方式")) {
                choice(L("方式"), selection: $host.authMethod,
                       options: AuthMethod.allCases.map { ($0, $0.displayName) })
            }

            switch host.authMethod {
            case .password, .keyboardInteractive:
                credentialField(L("密码"), prompt: L("密码"), text: $password.text)
                    .id(host.authMethod)
                Toggle(L("保存密码到凭据库"), isOn: $host.savesPassword)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            case .privateKey:
                let keys: [(UUID?, String)] = [(nil, L("磁盘上的私钥文件"))]
                    + app.keys.map { (Optional($0.id), $0.name) }
                field(L("私钥")) {
                    choice(L("私钥"), selection: keySelection, options: keys)
                }
                if host.keyID == nil {
                    field(L("路径")) {
                        HStack(spacing: 8) {
                            textControl(L("路径"), "~/.ssh/id_ed25519", text: identityPath,
                                        focus: .identityPath, monospaced: true)
                            Button(L("选择…")) { chooseKeyFile() }
                                .buttonStyle(EditorButtonStyle())
                                .fixedSize()
                        }
                    }
                }

                credentialField(L("口令"), prompt: L("私钥口令（可选）"), text: $passphrase.text,
                                isPassphrase: true)
                Toggle(L("保存口令到凭据库"), isOn: $host.savesPassword)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            case .agent:
                fieldHint(L("使用 ssh-agent 里的密钥；需要系统 ssh 连接方式，或在内置实现里可用且已加载的 agent 密钥。"))
            }
        }
    }

    private var routingSection: some View {
        section(L("代理与跳板")) {
            proxyControls
            Theme.separator.frame(height: 1)
            jumpControls
        }
    }

    @ViewBuilder
    private var proxyControls: some View {
        let proxies = [("inherit", L("继承分组设置")), ("direct", L("不使用代理"))]
            + app.proxies.map { ($0.id.uuidString, $0.name + " · " + $0.endpointDescription) }
        field(L("代理")) {
            HStack(spacing: 8) {
                choice(L("代理"), selection: proxySelection, options: proxies)
                Menu {
                    Button(L("HTTP 代理…")) { beginNewProxy(.http) }
                    Button(L("HTTPS 代理…")) { beginNewProxy(.https) }
                    Button(L("SOCKS5 代理…")) { beginNewProxy(.socks5) }
                    Button(L("SOCKS5（远端 DNS）…")) { beginNewProxy(.socks5h) }
                } label: {
                    Label(L("新建"), systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 9)
                        .frame(height: 34)
                        .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.separator, lineWidth: 1)
                        }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        if let selectedProxy {
            ProxyTestView(proxy: selectedProxy,
                          defaultTarget: host.hostname.isEmpty
                              ? "example.com:443"
                              : host.hostname + ":" + String(parsedPort ?? host.port))
        }
        fieldHint(L("代理只作用于连接的第一跳 TCP，优先级：主机 > 分组 > 全局。")
                  + L("代理与跳板机只能二选一：选了代理，下面的跳板机会被清空。")
                  + L("连接失败时先点上面的「测试连通性」，它能把代理不可达和代理拒绝隧道分开。"))
    }

    /// The concrete proxy the picker currently resolves to, if any.
    private var selectedProxy: ProxyConfig? {
        guard case .use(let id) = host.proxyPolicy else { return nil }
        return app.proxies.first { $0.id == id }
    }

    @ViewBuilder
    private var jumpControls: some View {
        field(L("跳板机")) {
            choice(L("跳板机"), selection: jumpSelection,
                   options: [("inherit", L("继承分组设置")), ("direct", L("直连")), ("custom", L("指定跳板机"))])
        }
        if host.jumpPolicy.isInherit {
            fieldHint(inheritedJumpDescription)
        }
        if case .hosts(let ids) = host.jumpPolicy {
            if ids.isEmpty {
                fieldHint(L("按顺序经过 1–3 台主机；在下面输入名称或地址搜索，不会列出全部主机。"))
            } else {
                jumpChips(ids)
            }
            controlSurface(focused: focusedField == .jumpQuery) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .accessibilityHidden(true)
                    TextField(L("搜索主机（名称或地址）"), text: $jumpQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($focusedField, equals: .jumpQuery)
                    if !jumpQuery.isEmpty {
                        Button { jumpQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.secondary)
                        .accessibilityLabel(L("清空搜索"))
                    }
                }
            }
            if !jumpQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                jumpResults(ids)
            }
        }
    }

    private var advancedSection: some View {
        section(L("终端与主机信息")) {
            let transports = [("auto", L("自动（推荐）"))]
                + HostTransport.allCases.map { ($0.rawValue, $0.displayName) }
            field(L("连接方式")) {
                choice(L("连接方式"), selection: transportSelection, options: transports)
            }
            fieldHint(transportHint)

            let encodings = [("inherit", L("继承分组"))]
                + TextEncodingKind.allCases.map { ($0.rawValue, $0.displayName) }
            fieldPair {
                textField(L("终端类型"), "xterm-256color", text: terminalTypeText, focus: .terminalType, monospaced: true)
                field(L("编码")) {
                    choice(L("编码"), selection: encodingSelection, options: encodings)
                }
            }
            fieldPair {
                textField(L("起始目录"), L("（可选）"), text: stringBinding(\.startDirectory), focus: .startDirectory)
                textField(L("上传目录"), L("（可选）"), text: stringBinding(\.defaultUploadDirectory), focus: .uploadDirectory)
            }
            fieldPair {
                textField(L("启动命令"), L("（可选）"), text: stringBinding(\.startupCommand), focus: .startupCommand)
                field(L("保活")) {
                    choice(L("保活"), selection: keepaliveSelection,
                           options: [(0, L("继承分组")), (-1, L("关闭")), (30, L("每 30 秒")),
                                     (60, L("每 60 秒")), (300, L("每 300 秒"))])
                }
            }
            Toggle(L("记录会话日志"), isOn: sessionLoggingBinding)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

            Theme.separator.frame(height: 1)
            textField(L("主机标签"), L("用逗号区分标签"), text: $tagsText, focus: .tags)
            field(L("备注")) {
                TextEditor(text: $host.notes)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .focused($focusedField, equals: .notes)
                    .padding(4)
                    .frame(height: 76)
                    .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(controlBorder(focusedField == .notes), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .accessibilityLabel(L("备注"))
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

    private func loadCredentials() {
        guard !loadedCredentials else { return }
        loadedCredentials = true
        do {
            try password.load(from: app.environment.secrets, account: .hostPassword(host.id))
            try passphrase.load(from: app.environment.secrets, account: .hostPassphrase(host.id))
        } catch {
            credentialError = L("无法读取本地凭据。请检查凭据库文件是否可读且完整。")
        }
    }

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

    private var parsedPort: Int? {
        Int(portText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func showConnectionError(_ message: String, focus: EditorField) {
        validationMessage = message
        selectedSection = .connection
        DispatchQueue.main.async { focusedField = focus }
    }

    private func save() {
        let name = host.name.trimmingCharacters(in: .whitespaces)
        let address = host.hostname.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty || !address.isEmpty else {
            showConnectionError(L("请至少填写名称或地址"), focus: .name)
            return
        }
        // A formatted TextField can leave the previous integer in its binding
        // when the draft is invalid. Validate the visible draft before saving.
        let port = parsedPort
        if !address.isEmpty && port.map({ (1...65535).contains($0) }) != true {
            showConnectionError(L("端口需为 1–65535 之间的整数。"), focus: .port)
            return
        }
        validationMessage = nil
        host.name = name
        host.hostname = address
        if let port { host.port = port }
        var tags = host.tags.filter(Self.isFavoriteTag)
        for segment in tagsText.split(whereSeparator: { $0 == "," || $0 == "，" }) {
            let tag = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tag.isEmpty && !tags.contains(tag) { tags.append(tag) }
        }
        host.tags = tags
        // Imported or hand-edited hosts may carry both; keep the proxy.
        let route = RouteRules.normalized(proxy: host.proxyPolicy, jump: host.jumpPolicy)
        host.proxyPolicy = route.proxy
        host.jumpPolicy = route.jump
        let secrets = app.environment.secrets
        do {
            try password.save(to: secrets, account: .hostPassword(host.id),
                              remember: host.savesPassword, wasRemembered: originallySavesPassword)
            try passphrase.save(to: secrets, account: .hostPassphrase(host.id),
                                remember: host.savesPassword, wasRemembered: originallySavesPassword)
        } catch {
            credentialError = L("无法保存本地凭据。请检查凭据库文件和目录是否可写。")
            selectedSection = .authentication
            return
        }
        app.saveHost(host)
    }

    // MARK: - Small helpers

    private static func isFavoriteTag(_ tag: String) -> Bool {
        tag == "favorite" || tag == "收藏"
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .accessibilityHidden(true)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fieldPair<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) { content() }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.windowBackground, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Theme.separator, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private func fieldHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func textField(_ title: String, _ prompt: String, text: Binding<String>,
                           focus: EditorField, monospaced: Bool = false) -> some View {
        field(title) {
            textControl(title, prompt, text: text, focus: focus, monospaced: monospaced)
        }
    }

    private func textControl(_ title: String, _ prompt: String, text: Binding<String>,
                             focus: EditorField, monospaced: Bool) -> some View {
        controlSurface(focused: focusedField == focus) {
            TextField(title, text: text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(monospaced ? TechFont.mono(12) : .system(size: 12.5))
                .disableAutocorrection(monospaced)
                .focused($focusedField, equals: focus)
                .accessibilityLabel(title)
        }
    }

    private func credentialField(_ title: String, prompt: String, text: Binding<String>,
                                 isPassphrase: Bool = false) -> some View {
        field(title) {
            controlSurface {
                RevealableCredentialField(title: prompt, text: text, isPassphrase: isPassphrase,
                                          usesPlainEditorStyle: true)
                    .font(.system(size: 12.5))
            }
        }
    }

    private func choice<Value: Hashable>(_ title: String, selection: Binding<Value>,
                                         options: [(value: Value, label: String)]) -> some View {
        let selected = options.first(where: { $0.value == selection.wrappedValue })?.label ?? ""
        return Menu {
            Picker(title, selection: selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].label).tag(options[index].value)
                }
            }
            .labelsHidden()
        } label: {
            controlSurface {
                HStack(spacing: 8) {
                    Text(selected)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.primary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel(title)
        .accessibilityValue(selected)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func controlSurface<Content: View>(focused: Bool = false,
                                               @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
            .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(controlBorder(focused), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
    }

    private func controlBorder(_ focused: Bool) -> Color {
        focused ? Theme.accent.opacity(0.65) : Theme.cardStroke
    }

    private struct EditorButtonStyle: ButtonStyle {
        var prominent = false

        @Environment(\.isEnabled) private var isEnabled

        func makeBody(configuration: Configuration) -> some View {
            let fill = prominent ? Theme.dynamic(light: 0x253044, dark: 0xDCE5F5) : Theme.fieldBackground
            return configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(prominent
                                 ? Theme.dynamic(light: 0xFFFFFF, dark: 0x1B2638)
                                 : .primary)
                .padding(.horizontal, 11)
                .frame(height: 34)
                .background(fill, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(prominent ? .clear : Theme.cardStroke, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.8 : 1)
        }
    }
}
