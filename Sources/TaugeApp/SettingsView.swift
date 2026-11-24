import SwiftUI
import AppKit
import TaugeKit

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var updater = UpdateController.shared
    @ViewState private var selectedSection = SettingsSection.general
    @ViewState private var hoveredSection: SettingsSection?
    @ViewState private var editingProxyDraft: ProxyConfig?
    @ViewState private var expandedTestProxyID: UUID?
    @ViewState private var cliInstallMessage: String?
    private let onClose: (() -> Void)?

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

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
        VStack(spacing: 0) {
            if let onClose {
                header(onClose: onClose)
                Theme.separator.frame(height: 1)
            }
            HStack(spacing: 0) {
                sidebar
                Theme.separator.frame(width: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 19) {
                        Text(selectedSection.title)
                            .font(.system(size: 24, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
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
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 29)
                    .padding(.vertical, 24)
                }
                .id(selectedSection)
                .controlSize(.small)
                .accessibilityIdentifier("tauge-settings-content-\(selectedSection.rawValue)")
            }
        }
        .background(Theme.windowBackground)
        .frame(width: 740, height: 560)
        // A nested sheet: the settings sheet already owns the window's single
        // presentation slot, so proxy editing here must not go through the
        // ContentView router.
        .sheet(item: $editingProxyDraft) { draft in
            ProxyEditorView(
                proxy: draft,
                onSave: { _ in editingProxyDraft = nil },
                onCancel: { editingProxyDraft = nil }
            )
            .environmentObject(app)
        }
    }

    private func header(onClose: @escaping () -> Void) -> some View {
        HStack(spacing: 9) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Theme.tabRailBackground, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.separator))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(Text(L("返回")))
            .help(L("返回"))
            Text(L("设置"))
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 17)
        .frame(height: 49)
        .background(Theme.windowBackground)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(spacing: 3) {
                ForEach(SettingsSection.allCases) { section in
                    let selected = selectedSection == section
                    Button { selectedSection = section } label: {
                        HStack(spacing: 8) {
                            Image(systemName: section.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(selected ? Theme.accent : Theme.secondary)
                                .frame(width: 17)
                            Text(section.title)
                                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        }
                        .padding(.horizontal, 9)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .background(selected ? Theme.rowSelection : (hoveredSection == section ? Theme.rowHover : .clear),
                                    in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        if inside { hoveredSection = section }
                        else if hoveredSection == section { hoveredSection = nil }
                    }
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("tauge-settings-section-\(section.rawValue)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 14)
        }
        .frame(width: 146)
        .background(Theme.sidebarBackground)
    }

    // MARK: - General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup(L("界面")) {
                row(L("语言")) {
                    Picker(L("语言"), selection: binding(\.language)) {
                        ForEach(TaugeLanguage.allCases) { language in
                            Text(language.displayName).tag(language.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 153)
                }
                row(L("默认视图")) {
                    Picker(L("默认视图"), selection: Binding(get: { app.settings.navigationMode },
                                                          set: { app.toggleBoard($0 == "board") })) {
                        Text(L("标签视图")).tag("tabs")
                        Text(L("工作区视图")).tag("board")
                    }
                    .labelsHidden()
                    .frame(width: 153)
                }
                toggleRow(L("侧边栏"), detail: L("显示起始页连接库（⌃⌘S）"),
                          isOn: Binding(get: { app.settings.startPageSidebarVisible }, set: { app.toggleSidebar($0) }))
            }
            settingsGroup(L("会话")) {
                toggleRow(L("关闭窗口时"), detail: L("运行中的会话需要确认"), isOn: binding(\.confirmCloseRunning))
                toggleRow(L("自动重连"), detail: L("网络中断后指数退避重连"), isOn: binding(\.autoReconnect))
            }
            settingsGroup(L("更新与集成")) {
                toggleRow(L("自动检查更新"), detail: L("每天检查一次 GitHub 发布"), isOn: binding(\.automaticallyChecksForUpdates))
                toggleRow(L("MCP 通道"),
                          detail: L("开启后，Tauge 提供本地 MCP 命令通道，复用当前主机目录、凭据库和 SSH 连接能力。"),
                          isOn: binding(\.mcpEnabled))
                row("tauge mcp", detail: L("连接方式为本地 stdio，不监听 TCP 端口，也不需要地址和端口。")) {
                    HStack(spacing: 7) {
                        Button(action: copyMCPCommand) {
                            Label(L("复制命令"), systemImage: "doc.on.doc")
                        }
                        Button(L("安装 tauge 命令"), action: installCLI)
                    }
                }
                if let cliInstallMessage {
                    note(cliInstallMessage)
                        .textSelection(.enabled)
                }
            }
            settingsGroup(L("隐私")) {
                note(L("主机信息、凭据与会话内容只保存在本机，不会上传。"))
            }
        }
    }

    // MARK: - Appearance

    private enum AppearanceChoice: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return L("跟随系统")
            case .light: return L("浅色")
            case .dark: return L("深色")
            }
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup(L("主题")) {
                HStack(spacing: 12) {
                    ForEach(AppearanceChoice.allCases) { appearance in
                        let selected = app.settings.appearance == appearance.rawValue
                        Button {
                            binding(\.appearance).wrappedValue = appearance.rawValue
                        } label: {
                            VStack(spacing: 7) {
                                appearanceSample(appearance)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(selected ? Theme.accent : Theme.cardStroke, lineWidth: selected ? 1.5 : 1)
                                    )
                                Text(appearance.title)
                                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(appearance.title))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
            }
            settingsGroup(L("终端外观")) {
                row(L("终端配色")) {
                    Picker(L("终端配色"), selection: binding(\.terminalThemeName)) {
                        ForEach(TerminalThemeCatalog.names, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 153)
                }
                row(L("背景透明度")) {
                    HStack(spacing: 8) {
                        Slider(value: binding(\.terminalBackgroundOpacity), in: 0.6...1.0)
                            .accessibilityLabel(Text(L("背景透明度")))
                            .frame(width: 130)
                        Text(String(format: "%.0f%%", app.settings.terminalBackgroundOpacity * 100))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                            .frame(minWidth: 34, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func appearanceSample(_ appearance: AppearanceChoice) -> some View {
        Group {
            if appearance == .system {
                HStack(spacing: 0) {
                    appearanceWindow(dark: false)
                    appearanceWindow(dark: true)
                }
            } else {
                appearanceWindow(dark: appearance == .dark)
            }
        }
        .frame(height: 65)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private func appearanceWindow(dark: Bool) -> some View {
        let surface = dark ? Color(nsColor: NSColor(srgbRed: 0.13, green: 0.15, blue: 0.18, alpha: 1)) : Color.white
        let chrome = dark ? Color.white.opacity(0.09) : Color.black.opacity(0.045)
        let line = dark ? Color.white.opacity(0.18) : Color.black.opacity(0.14)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                ForEach(0..<3) { _ in
                    Circle().fill(line).frame(width: 3, height: 3)
                }
            }
            .padding(.leading, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 13)
            .background(chrome)
            Rectangle().fill(line).frame(height: 0.5)
            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<3) { _ in
                        Capsule().fill(line).frame(width: 13, height: 2)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 24)
                .padding(.top, 7)
                .background(chrome)
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(line).frame(width: 20, height: 3)
                    Capsule().fill(line).frame(maxWidth: 43).frame(height: 2)
                    Capsule().fill(line).frame(maxWidth: 32).frame(height: 2)
                    Spacer(minLength: 0)
                }
                .padding(.top, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(surface)
    }

    // MARK: - Terminal

    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup {
                row(L("字体")) {
                    Picker(L("字体"), selection: binding(\.terminalFontFamily)) {
                        ForEach(["SF Mono", "Menlo", "Monaco", "JetBrains Mono", "Fira Code", "Hack"], id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 153)
                }
                row(L("字号")) {
                    HStack(spacing: 8) {
                        Text("\(Int(app.settings.terminalFontSize)) pt")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                        Stepper(L("字号"), value: binding(\.terminalFontSize), in: 9...28)
                            .labelsHidden()
                    }
                }
                row(L("行高")) {
                    HStack(spacing: 8) {
                        Slider(value: binding(\.terminalLineHeight), in: 0.9...1.6)
                            .accessibilityLabel(Text(L("行高")))
                            .frame(width: 130)
                        Text(String(format: "%.2f", app.settings.terminalLineHeight))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                            .frame(minWidth: 34, alignment: .trailing)
                    }
                }
                row(L("回滚行数")) {
                    Picker(L("回滚行数"), selection: binding(\.scrollbackLines)) {
                        Text("1,000").tag(1000)
                        Text("5,000").tag(5000)
                        Text("10,000").tag(10000)
                        Text("50,000").tag(50000)
                    }
                    .labelsHidden()
                    .frame(width: 153)
                }
            }
            settingsGroup(L("输入与剪贴板")) {
                toggleRow(L("Option 键"), detail: L("作为 Meta 键发送"), isOn: binding(\.optionAsMeta))
                toggleRow(L("复制"), detail: L("选中即复制"), isOn: binding(\.copyOnSelect))
                toggleRow(L("粘贴"), detail: L("多行粘贴前确认"), isOn: binding(\.confirmMultilinePaste))
                toggleRow(L("命令广播"),
                          detail: L("开启后，在任一窗格输入的内容会同时发送给其他已连接窗格。默认关闭，工作区标题栏的「广播」开关可以随时切换（⌥⌘B）。"),
                          isOn: binding(\.broadcastInput))
            }
        }
    }

    // MARK: - Transfer

    private var transferSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup(L("传输任务")) {
                row(L("并发传输")) {
                    Picker(L("并发传输"), selection: binding(\.defaultTransferConcurrency)) {
                        Text("1").tag(1)
                        Text(L("2（推荐）")).tag(2)
                        Text("3").tag(3)
                        Text("4").tag(4)
                    }
                    .labelsHidden()
                    .frame(width: 153)
                }
                row(L("失败重试")) {
                    Picker(L("失败重试"), selection: binding(\.transferRetryCount)) {
                        Text("0").tag(0)
                        Text("1").tag(1)
                        Text("2").tag(2)
                        Text(L("3（推荐）")).tag(3)
                        Text("5").tag(5)
                    }
                    .labelsHidden()
                    .frame(width: 153)
                }
                row(L("冲突策略")) {
                    Picker(L("冲突策略"), selection: binding(\.conflictPolicy)) {
                        Text(L("每次都询问")).tag("ask")
                        Text(L("覆盖")).tag("overwrite")
                        Text(L("跳过")).tag("skip")
                        Text(L("重命名")).tag("rename")
                        Text(L("仅较新")).tag("onlyIfNewer")
                    }
                    .labelsHidden()
                    .frame(width: 153)
                }
            }
            settingsGroup(L("上传目录")) {
                note(L("拖拽到侧边栏主机时使用的默认上传目录在主机设置中配置。"))
            }
        }
    }

    // MARK: - Proxies

    private var proxiesSection: some View {
        VStack(alignment: .leading, spacing: 17) {
            settingsGroup(L("代理服务器")) {
                row(L("%d 个代理", app.proxies.count)) {
                    Button(L("新建代理…")) {
                        var proxy = ProxyConfig(name: "HTTP CONNECT", type: .http)
                        proxy.port = ProxyType.http.defaultPort
                        editingProxyDraft = proxy
                    }
                }

                if app.proxies.isEmpty {
                    note(L("还没有代理。新建后可在这里编辑、测试、删除。"))
                } else {
                    ForEach(app.proxies) { proxy in
                        let endpoint = proxy.endpointDescription
                            + (proxy.username.isEmpty ? "" : L(" · 用户 ") + proxy.username)
                        row(proxy.name, detail: endpoint, monospaced: true) {
                            HStack(spacing: 8) {
                                Button(L("编辑")) { editingProxyDraft = proxy }
                                Button(expandedTestProxyID == proxy.id ? L("收起") : L("测试")) {
                                    expandedTestProxyID = expandedTestProxyID == proxy.id ? nil : proxy.id
                                }
                                Button(L("删除")) {
                                    if expandedTestProxyID == proxy.id { expandedTestProxyID = nil }
                                    app.deleteProxy(proxy.id)
                                }
                            }
                        }
                        if expandedTestProxyID == proxy.id {
                            ProxyTestView(proxy: proxy)
                                .environmentObject(app)
                                .padding(.vertical, 10)
                                .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
                        }
                    }
                }
            }
            note(L("代理只用于连接的第一跳 TCP，支持 HTTP CONNECT、SOCKS5 与 SOCKS5（远端 DNS）；HTTPS（TLS）代理暂未实现。")
                 + L("配置了代理的主机不再经过跳板机：代理与跳板机只能二选一。"))
            note(L("提示：连接失败时先点「测试」。它只验证到代理这一段，能把「代理地址/端口不可达」和「代理拒绝这条隧道」分开，")
                 + L("分别对应代理配置问题与目标机/账号问题。"))
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup(L("已知主机")) {
                if app.knownHosts.isEmpty {
                    note(L("首次连接时会展示主机密钥指纹，确认后写入 known_hosts。"))
                } else {
                    ForEach(app.knownHosts) { entry in
                        row(entry.hostPort, detail: entry.keyType + "  " + entry.fingerprintSHA256, monospaced: true) {
                            Button(L("移除")) { app.forgetHostKey(entry) }
                        }
                    }
                    note(L("%d 条记录", app.knownHosts.count))
                }
            }
            settingsGroup(L("私钥")) {
                row(L("%d 条记录", app.keys.count)) {
                    Button(L("导入私钥…")) { app.showingKeyImporter = true }
                }
                if app.keys.isEmpty {
                    note(L("尚未导入私钥。支持 OpenSSH 新格式、PKCS#1、PKCS#8 与 SEC1（Ed25519 / ECDSA / RSA）。"))
                } else {
                    ForEach(app.keys) { key in
                        row(key.name, detail: key.fingerprintSHA256, monospaced: true) {
                            Button(L("删除")) { app.deletePrivateKey(key.id) }
                        }
                    }
                }
            }
            settingsGroup(L("凭据存储")) {
                note(L("密码与口令保存在应用目录的加密库里（vault.v1.enc，仅当前用户可读）。"))
                note(L("启动、连接或显示已保存的密码时，不需要 Touch ID 或 Mac 登录密码。仅能无提示读取的旧钥匙串凭据会自动迁移；无法迁移时请在对应配置里重新输入一次。"))
            }
        }
    }

    // MARK: - Shortcuts

    private var shortcutsSection: some View {
        settingsGroup {
            ForEach(Self.shortcutRows, id: \.0) { shortcut in
                row(shortcut.0) {
                    Text(shortcut.1)
                        .font(TechFont.mono(11, .medium))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 7)
                        .frame(minHeight: 22)
                        .background(Theme.tabRailBackground, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.separator))
                }
            }
        }
    }

    private static var shortcutRows: [(String, String)] {
        [
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
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup(L("本地存储")) {
                row(L("日志目录"), detail: SessionLogger.defaultDirectory().path, monospaced: true) {
                    Button(L("打开")) { NSWorkspace.shared.open(SessionLogger.defaultDirectory()) }
                }
                row(L("数据库"), detail: app.environment.databaseURL.path, monospaced: true) {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 7) {
                            Text(app.catalogReadOnly ? L("只读（无法保存修改）") : L("可写"))
                                .font(.system(size: 11))
                                .foregroundStyle(app.catalogReadOnly ? Theme.warning : Theme.secondary)
                            Button(L("在 Finder 中显示")) { app.revealCatalogInFinder() }
                        }
                        Button(L("迁移到可写位置…")) { app.chooseCatalogLocation() }
                    }
                }
                if app.environment.isEphemeralDatabase {
                    note(L("当前使用临时数据库（应用支持目录不可写），配置不会持久保存。"), color: Theme.warning)
                }
                if app.catalogReadOnly {
                    note(L("数据库当前位置不可写：修改不会被保存。请从 Finder 直接启动 Tauge.app，或使用上方的“迁移到可写位置…”。"), color: Theme.warning)
                }
            }
            settingsGroup(L("主机配置")) {
                row(L("导出主机配置")) {
                    Button(L("导出…")) { app.exportCatalog() }
                }
                row(L("导入主机配置")) {
                    Button(L("导入…")) { app.importCatalog() }
                }
                row(L("从 SSH 配置导入")) {
                    Button(L("导入 ~/.ssh/config")) { app.importSSHConfig() }
                }
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 11) {
                TechAppLogo(size: 45)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tauge").font(.system(size: 18, weight: .semibold))
                    Text(L("版本 %@（构建 %@）", TaugeAppInfo.version, TaugeAppInfo.build))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            settingsGroup {
                row(L("检查更新"), detail: updater.lastCheck.map {
                    L("上次检查：%@", $0.formatted(date: .abbreviated, time: .shortened))
                } ?? L("尚未检查更新")) {
                    Button(L("检查更新…")) { updater.checkForUpdates(manual: true) }
                        .disabled(updater.isBusy)
                }
                note(L("本地优先的 macOS SSH / SFTP 客户端。终端、文件浏览与传输共享同一条 SSH 连接。"))
            }
            settingsGroup(L("开源组件")) {
                note(L("终端渲染基于 SwiftTerm（MIT）；SSH 协议栈基于 SwiftNIO SSH（Apache 2.0）。"))
            }
        }
    }

    // MARK: - Helpers

    private func copyMCPCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("tauge mcp", forType: .string)
    }

    private func installCLI() {
        do {
            let path = try TaugeCLIInstaller.install()
            cliInstallMessage = L("已安装到 %@", path.path)
        } catch {
            cliInstallMessage = error.localizedDescription
        }
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

    private func settingsGroup<Content: View>(_ title: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 7)
            }
            Theme.separator.frame(height: 1)
            content()
        }
    }

    private func row<Content: View>(
        _ title: String, detail: String? = nil, monospaced: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    if let detail {
                        if monospaced {
                            Text(detail)
                                .font(TechFont.mono(11))
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        } else {
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                content().fixedSize(horizontal: true, vertical: false)
            }
            .padding(.vertical, 8)
            .frame(minHeight: 42)
            Theme.separator.frame(height: 1)
        }
    }

    private func toggleRow(_ title: String, detail: String? = nil, isOn: Binding<Bool>) -> some View {
        row(title, detail: detail) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func note(_ text: String, color: Color = Theme.secondary) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 7)
    }
}

