import SwiftUI
import AppKit
import TaugeKit

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var updater = UpdateController.shared
    @ViewState private var selectedSection = SettingsSection.general
    @ViewState private var newKnownHostWarning: String?
    @ViewState private var editingProxyDraft: ProxyConfig?
    @ViewState private var expandedTestProxyID: UUID?

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general, appearance, terminal, transfer, proxies, security, shortcuts, advanced, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return L("通用")
            case .appearance: return L("外观")
            case .terminal: return L("终端")
            case .transfer: return L("传输")
            case .proxies: return L("代理")
            case .security: return L("安全")
            case .shortcuts: return L("快捷键")
            case .advanced: return L("高级")
            case .about: return L("关于")
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintpalette"
            case .terminal: return "terminal"
            case .transfer: return "arrow.up.arrow.down"
            case .proxies: return "network"
            case .security: return "lock.shield"
            case .shortcuts: return "keyboard"
            case .advanced: return "wrench.and.screwdriver"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        HSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 160)
            .background(Theme.sidebarBackground)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(selectedSection.title).font(.system(size: 16, weight: .semibold))
                    switch selectedSection {
                    case .general: generalSection
                    case .appearance: appearanceSection
                    case .terminal: terminalSection
                    case .transfer: transferSection
                    case .proxies: proxiesSection
                    case .security: securitySection
                    case .shortcuts: shortcutsSection
                    case .advanced: advancedSection
                    case .about: aboutSection
                    }
                    Spacer(minLength: 0)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 640, height: 520)
        // A nested sheet: the settings sheet already owns the window's single
        // presentation slot, so proxy editing here must not go through the
        // ContentView router.
        .sheet(item: $editingProxyDraft) { draft in
            ProxyEditorView(
                proxy: draft,
                onSave: { proxy, secret in
                    if !secret.isEmpty {
                        try? app.environment.secrets.setSecret(secret, for: .proxyPassword(proxy.id))
                    }
                    app.saveProxy(proxy)
                    editingProxyDraft = nil
                },
                onCancel: { editingProxyDraft = nil }
            )
            .environmentObject(app)
        }
    }

    // MARK: - General

    private var generalSection: some View {
        card {
            row(L("语言")) {
                Picker("", selection: binding(\.language)) {
                    ForEach(TaugeLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            row(L("默认视图")) {
                Picker("", selection: Binding(get: { app.settings.navigationMode },
                                              set: { app.toggleBoard($0 == "board") })) {
                    Text(L("标签视图")).tag("tabs")
                    Text(L("工作区视图")).tag("board")
                }
                .labelsHidden()
                .frame(width: 160)
            }
            row(L("侧边栏")) {
                Toggle(L("左侧显示主机列表（⌃⌘S）"), isOn: Binding(get: { app.settings.sidebarVisible },
                                                            set: { app.toggleSidebar($0) }))
            }
            row(L("关闭窗口时")) {
                Toggle(L("运行中的会话需要确认"), isOn: binding(\.confirmCloseRunning))
            }
            row(L("自动重连")) {
                Toggle(L("网络中断后指数退避重连"), isOn: binding(\.autoReconnect))
            }
            row(L("自动检查更新")) {
                Toggle(L("每天检查一次 GitHub 发布"), isOn: binding(\.automaticallyChecksForUpdates))
            }
            row(L("MCP 通道")) {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(L("启用 Tauge MCP 通道"), isOn: binding(\.mcpEnabled))
                    Text(L("开启后，Tauge 提供本地 MCP 命令通道，复用当前主机目录、凭据库和 SSH 连接能力。"))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            row(L("隐私")) {
                Text(L("主机信息、凭据与会话内容只保存在本机，不会上传。"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        card {
            row(L("主题")) {
                Picker("", selection: binding(\.appearance)) {
                    Text(L("跟随系统")).tag("system")
                    Text(L("浅色")).tag("light")
                    Text(L("深色")).tag("dark")
                }
                .labelsHidden()
                .frame(width: 160)
            }
            row(L("终端配色")) {
                Picker("", selection: binding(\.terminalThemeName)) {
                    ForEach(TerminalThemeCatalog.names, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            row(L("背景透明度")) {
                HStack {
                    Slider(value: binding(\.terminalBackgroundOpacity), in: 0.6...1.0)
                        .frame(width: 160)
                    Text(String(format: "%.0f%%", app.settings.terminalBackgroundOpacity * 100))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
    }

    // MARK: - Terminal

    private var terminalSection: some View {
        card {
            row(L("字体")) {
                Picker("", selection: binding(\.terminalFontFamily)) {
                    ForEach(["SF Mono", "Menlo", "Monaco", "JetBrains Mono", "Fira Code", "Hack"], id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }
            row(L("字号")) {
                HStack {
                    Stepper("", value: binding(\.terminalFontSize), in: 9...28)
                        .labelsHidden()
                    Text("\(Int(app.settings.terminalFontSize)) pt")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
            }
            row(L("行高")) {
                HStack {
                    Slider(value: binding(\.terminalLineHeight), in: 0.9...1.6)
                        .frame(width: 160)
                    Text(String(format: "%.2f", app.settings.terminalLineHeight))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
            }
            row(L("回滚行数")) {
                Picker("", selection: binding(\.scrollbackLines)) {
                    Text("1,000").tag(1000)
                    Text("5,000").tag(5000)
                    Text("10,000").tag(10000)
                    Text("50,000").tag(50000)
                }
                .labelsHidden()
                .frame(width: 140)
            }
            row(L("Option 键")) {
                Toggle(L("作为 Meta 键发送"), isOn: binding(\.optionAsMeta))
            }
            row(L("复制")) {
                Toggle(L("选中即复制"), isOn: binding(\.copyOnSelect))
            }
            row(L("粘贴")) {
                Toggle(L("多行粘贴前确认"), isOn: binding(\.confirmMultilinePaste))
            }
            row(L("命令广播")) {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(L("在工作区同步输入"), isOn: binding(\.broadcastInput))
                    Text(L("开启后，在任一窗格输入的内容会同时发送给其他已连接窗格。默认关闭，工作区标题栏的「广播」开关可以随时切换（⌥⌘B）。"))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Transfer

    private var transferSection: some View {
        card {
            row(L("并发传输")) {
                Picker("", selection: binding(\.defaultTransferConcurrency)) {
                    Text("1").tag(1)
                    Text(L("2（推荐）")).tag(2)
                    Text("3").tag(3)
                    Text("4").tag(4)
                }
                .labelsHidden()
                .frame(width: 140)
            }
            row(L("失败重试")) {
                Picker("", selection: binding(\.transferRetryCount)) {
                    Text("0").tag(0)
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text(L("3（推荐）")).tag(3)
                    Text("5").tag(5)
                }
                .labelsHidden()
                .frame(width: 140)
            }
            row(L("冲突策略")) {
                Picker("", selection: binding(\.conflictPolicy)) {
                    Text(L("每次都询问")).tag("ask")
                    Text(L("覆盖")).tag("overwrite")
                    Text(L("跳过")).tag("skip")
                    Text(L("重命名")).tag("rename")
                    Text(L("仅较新")).tag("onlyIfNewer")
                }
                .labelsHidden()
                .frame(width: 160)
            }
            row(L("上传目录")) {
                Text(L("拖拽到侧边栏主机时使用的默认上传目录在主机设置中配置。"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
        }
    }

    // MARK: - Proxies

    private var proxiesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            card {
                row(L("代理服务器")) {
                    HStack(spacing: 8) {
                        Text(L("%d 个代理", app.proxies.count))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                        Button(L("新建代理…")) {
                            var proxy = ProxyConfig(name: "HTTP CONNECT", type: .http)
                            proxy.port = ProxyType.http.defaultPort
                            editingProxyDraft = proxy
                        }
                    }
                }
                Text(L("代理只用于连接的第一跳 TCP，支持 HTTP CONNECT、SOCKS5 与 SOCKS5（远端 DNS）；HTTPS（TLS）代理暂未实现。")
                     + L("配置了代理的主机不再经过跳板机：代理与跳板机只能二选一。"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if app.proxies.isEmpty {
                    Text(L("还没有代理。新建后可在这里编辑、测试、删除。"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                } else {
                    ForEach(app.proxies) { proxy in
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(proxy.name)
                                        .font(.system(size: 11, weight: .medium))
                                    Text(proxy.endpointDescription
                                         + (proxy.username.isEmpty ? "" : L(" · 用户 ") + proxy.username))
                                        .font(.system(size: 10).monospaced())
                                        .foregroundStyle(Theme.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer(minLength: 0)
                                Button(L("编辑")) { editingProxyDraft = proxy }
                                    .buttonStyle(.link)
                                    .font(.system(size: 10))
                                Button(expandedTestProxyID == proxy.id ? L("收起") : L("测试")) {
                                    expandedTestProxyID = expandedTestProxyID == proxy.id ? nil : proxy.id
                                }
                                .buttonStyle(.link)
                                .font(.system(size: 10))
                                Button(L("删除")) {
                                    if expandedTestProxyID == proxy.id { expandedTestProxyID = nil }
                                    app.deleteProxy(proxy.id)
                                }
                                .buttonStyle(.link)
                                .font(.system(size: 10))
                            }
                            if expandedTestProxyID == proxy.id {
                                ProxyTestView(proxy: proxy)
                                    .environmentObject(app)
                            }
                        }
                    }
                }
            }
            Text(L("提示：连接失败时先点「测试」。它只验证到代理这一段，能把「代理地址/端口不可达」和「代理拒绝这条隧道」分开，")
                 + L("分别对应代理配置问题与目标机/账号问题。"))
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            card {
                row(L("已知主机")) {
                    Text(L("%d 条记录", app.knownHosts.count))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
                if app.knownHosts.isEmpty {
                    Text(L("首次连接时会展示主机密钥指纹，确认后写入 known_hosts。"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                } else {
                    ForEach(app.knownHosts) { entry in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.hostPort)
                                    .font(.system(size: 11, weight: .medium))
                                Text(entry.keyType + "  " + entry.fingerprintSHA256)
                                    .font(.system(size: 10).monospaced())
                                    .foregroundStyle(Theme.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button(L("移除")) {
                                app.forgetHostKey(entry)
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 10))
                        }
                        Divider()
                    }
                }
            }
            card {
                row(L("私钥")) {
                    Button(L("导入私钥…")) { app.showingKeyImporter = true }
                }
                if app.keys.isEmpty {
                    Text(L("尚未导入私钥。支持 OpenSSH 新格式、PKCS#1、PKCS#8 与 SEC1（Ed25519 / ECDSA / RSA）。"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                } else {
                    ForEach(app.keys) { key in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key.name).font(.system(size: 11, weight: .medium))
                                Text(key.fingerprintSHA256)
                                    .font(.system(size: 10).monospaced())
                                    .foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            Button(L("删除")) { app.deletePrivateKey(key.id) }
                                .buttonStyle(.link)
                                .font(.system(size: 10))
                        }
                        Divider()
                    }
                }
            }
            card {
                row(L("凭据存储")) {
                    Text(L("密码与口令保存在应用目录的加密库里（vault.v1.enc，仅当前用户可读）。"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
                row(L("解锁方式")) {
                    Toggle(L("使用 Touch ID 解锁凭据"), isOn: binding(\.unlockWithBiometrics))
                        .disabled(!BiometricGate.hasBiometrics())
                }
                Text(biometricHint)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("凭据库与代码签名无关：重新构建、重装或换签名都不会再触发登录钥匙串密码框。旧版本的凭据会在无需授权时自动搬进本地库；若旧条目受旧签名保护，请在 Tauge 的主机密码框重新输入一次。"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Shortcuts

    private var shortcutsSection: some View {
        card {
            ForEach(Self.shortcutRows, id: \.0) { row in
                HStack {
                    Text(row.0).font(.system(size: 11))
                    Spacer()
                    Text(row.1)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(Theme.secondary)
                }
                Divider()
            }
        }
    }

    private static let shortcutRows: [(String, String)] = [
        (L("新建标签"), "⌘T"),
        (L("关闭标签"), "⌘W"),
        (L("重新连接"), "⌘R"),
        (L("显示/隐藏 SFTP"), "⇧⌘O"),
        (L("切换标签 1–9"), "⌘1 … ⌘9"),
        (L("增/减字号"), "⌘+ / ⌘-"),
        (L("快速打开"), "⌘K"),
        (L("传输中心"), "⇧⌘J"),
        (L("新建主机"), "⌘N"),
        (L("新建分组"), "⇧⌘N"),
        (L("保存编辑的文件"), "⌘S")
    ]

    // MARK: - Advanced

    private var advancedSection: some View {
        card {
            row(L("日志目录")) {
                HStack {
                    Text(SessionLogger.defaultDirectory().path)
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(Theme.secondary)
                    Button(L("打开")) {
                        NSWorkspace.shared.open(SessionLogger.defaultDirectory())
                    }
                    .buttonStyle(.link)
                }
            }
            row(L("数据库")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.environment.databaseURL.path)
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(Theme.secondary)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        Text(app.catalogReadOnly ? L("只读（无法保存修改）") : L("可写"))
                            .font(.system(size: 10))
                            .foregroundStyle(app.catalogReadOnly ? Theme.warning : Theme.success)
                        Button(L("在 Finder 中显示")) { app.revealCatalogInFinder() }
                            .buttonStyle(.link)
                        Button(L("迁移到可写位置…")) { app.chooseCatalogLocation() }
                            .buttonStyle(.link)
                    }
                }
            }
            row(L("导出主机配置")) {
                Button(L("导出…")) { app.exportCatalog() }
            }
            row(L("导入主机配置")) {
                Button(L("导入…")) { app.importCatalog() }
            }
            row(L("从 SSH 配置导入")) {
                Button(L("导入 ~/.ssh/config")) { app.importSSHConfig() }
            }
            if app.environment.isEphemeralDatabase {
                Text(L("当前使用临时数据库（应用支持目录不可写），配置不会持久保存。"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
            }
            if app.catalogReadOnly {
                Text(L("数据库当前位置不可写：修改不会被保存。请从 Finder 直接启动 Tauge.app，或使用上方的“迁移到可写位置…”。"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tauge").font(.system(size: 18, weight: .semibold))
                    Text(L("版本 %@（构建 %@）", TaugeAppInfo.version, TaugeAppInfo.build))
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 12)
                Button(L("检查更新…")) { updater.checkForUpdates(manual: true) }
                    .controlSize(.small)
                    .disabled(updater.isBusy)
            }
            if let lastCheck = updater.lastCheck {
                Text(L("上次检查：%@", lastCheck.formatted(date: .abbreviated, time: .shortened)))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
            } else {
                Text(L("尚未检查更新"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
            }
            Text(L("本地优先的 macOS SSH / SFTP 客户端。终端、文件浏览与传输共享同一条 SSH 连接。"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            Text(L("终端渲染基于 SwiftTerm（MIT）；SSH 协议栈基于 SwiftNIO SSH（Apache 2.0）。"))
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
        .shadow(color: Theme.shadow, radius: 6, y: 1.5)
    }

    // MARK: - Helpers

    /// Explains the Touch ID gate, or why it is unavailable on this Mac.
    private var biometricHint: String {
        guard BiometricGate.hasBiometrics() else {
            return L("此 Mac 没有可用的 Touch ID，连接时会直接读取凭据库。")
        }
        return L("每次启动后第一次连接会要求 Touch ID（也可用登录密码）；解锁一次后本次运行不再询问。")
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { app.settings[keyPath: keyPath] },
            set: { newValue in
                var updated = app.settings
                updated[keyPath: keyPath] = newValue
                app.updateSettings(updated)
            }
        )
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
            .shadow(color: Theme.shadow, radius: 6, y: 1.5)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .frame(width: 90, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

