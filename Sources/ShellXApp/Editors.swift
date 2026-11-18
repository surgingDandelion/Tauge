import SwiftUI
import AppKit
import ShellXKit

struct GroupEditorView: View {
    @EnvironmentObject private var app: AppState
    @ViewState private var group: HostGroup
    @ViewState private var defaults: GroupDefaults

    init(group: HostGroup) {
        _group = ViewState(wrappedValue: group)
        _defaults = ViewState(wrappedValue: group.defaults)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("分组")).font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(L("取消")) { app.editingGroup = nil }
                    .keyboardShortcut(.cancelAction)
                Button(L("保存")) {
                    group.defaults = defaults
                    app.saveGroup(group)
                    app.editingGroup = nil
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Divider()
            Form {
                TextField(L("名称"), text: $group.name)
                Picker(L("上级分组"), selection: $group.parentID) {
                    Text(L("顶级分组")).tag(UUID?.none)
                    ForEach(app.groups.filter { $0.id != group.id }) { candidate in
                        Text(app.groupPath(for: candidate.id)).tag(Optional(candidate.id))
                    }
                }
                Section(L("默认值（向下继承）")) {
                    Picker(L("代理"), selection: Binding(
                        get: {
                            switch defaults.proxyPolicy {
                            case .inherit: return "inherit"
                            case .direct: return "direct"
                            case .use(let id): return id.uuidString
                            }
                        },
                        set: { value in
                            switch value {
                            case "inherit": defaults.proxyPolicy = .inherit
                            case "direct": defaults.proxyPolicy = .direct
                            default:
                                if let id = UUID(uuidString: value) { defaults.proxyPolicy = .use(id) }
                            }
                        }
                    )) {
                        Text(L("继承")).tag("inherit")
                        Text(L("不使用代理")).tag("direct")
                        ForEach(app.proxies) { proxy in
                            Text(proxy.name).tag(proxy.id.uuidString)
                        }
                    }
                    Picker(L("编码"), selection: $defaults.encoding) {
                        Text(L("继承")).tag(TextEncodingKind?.none)
                        ForEach(TextEncodingKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(Optional(kind))
                        }
                    }
                    TextField(L("终端类型"), text: Binding(
                        get: { defaults.terminalType ?? "" },
                        set: { defaults.terminalType = $0.isEmpty ? nil : $0 }
                    ))
                    TextField(L("默认上传目录"), text: Binding(
                        get: { defaults.defaultUploadDirectory ?? "" },
                        set: { defaults.defaultUploadDirectory = $0.isEmpty ? nil : $0 }
                    ))
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 480)
    }
}

struct ProxyEditorView: View {
    @EnvironmentObject private var app: AppState
    @ViewState private var proxy: ProxyConfig
    @ViewState private var password = ""
    /// Optional callbacks let the host editor host this sheet itself: the single
    /// sheet router in ContentView owns `editingProxy`, so a proxy created from a
    /// host form must be handed back instead of touching the router.
    private let onSave: ((ProxyConfig, String) -> Void)?
    private let onCancel: (() -> Void)?

    init(proxy: ProxyConfig,
         onSave: ((ProxyConfig, String) -> Void)? = nil,
         onCancel: (() -> Void)? = nil) {
        _proxy = ViewState(wrappedValue: proxy)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("代理")).font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(L("取消")) {
                    if let onCancel { onCancel() } else { app.editingProxy = nil }
                }
                .keyboardShortcut(.cancelAction)
                Button(L("保存")) {
                    if let onSave {
                        onSave(proxy, password)
                    } else {
                        if !password.isEmpty {
                            try? app.environment.secrets.setSecret(password, for: .proxyPassword(proxy.id))
                        }
                        app.saveProxy(proxy)
                        app.editingProxy = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Divider()
            Form {
                TextField(L("名称"), text: $proxy.name)
                Picker(L("类型"), selection: $proxy.type) {
                    ForEach(ProxyType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                TextField(L("地址"), text: $proxy.host)
                TextField(L("端口"), value: $proxy.port, format: .number)
                TextField(L("用户名（可选）"), text: $proxy.username)
                SecureField(L("密码（可选）"), text: $password)
                Toggle(L("保存密码到凭据库"), isOn: $proxy.savesPassword)
                Text(L("作用域：主机 > 分组 > 全局；代理仅用于连接第一跳 TCP。选了代理的主机不再经过跳板机。"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
                if proxy.type == .https {
                    Text(L("HTTPS（TLS）代理暂未实现，连接与测试都会提示不支持；请改用 HTTP CONNECT 或 SOCKS5。"))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.warning)
                }
                // Inside the Form so it scrolls: a sheet taller than its parent
                // window gets clipped, which hid the test button entirely.
                Section(L("连接测试")) {
                    ProxyTestView(proxy: proxy,
                                  password: password.isEmpty ? nil : password,
                                  defaultTarget: "example.com:443")
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 520)
    }
}
