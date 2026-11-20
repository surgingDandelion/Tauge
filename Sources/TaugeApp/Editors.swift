import SwiftUI
import AppKit
import TaugeKit

/// Small shared palette used by host and group editors. Storing the hex value
/// keeps the setting portable across launches and compatible with the catalog
/// JSON/export format; the empty option follows the generated default tint.
struct ColorChoicePicker: View {
    @Binding var colorHex: String?
    var title: String = "颜色"
    /// The color this item would display while `colorHex` is nil. Hosts use
    /// the closest group color; groups use their parent chain.
    var inheritedHex: String?
    var inheritedTitle: String = "继承分组颜色"
    var compact = false
    @ViewState private var isPresented = false

    private struct Choice: Identifiable {
        let hex: String
        let nameKey: String
        var id: String { hex }
    }

    private var hasInheritedColor: Bool {
        inheritedHex != nil
    }

    private var showsInheritedColor: Bool {
        colorHex == nil && inheritedHex != nil
    }

    private var swatchColor: Color {
        Color(hex: colorHex) ?? Color(hex: inheritedHex) ?? Theme.secondary.opacity(0.35)
    }

    private var statusText: String {
        if let choice = Self.choices.first(where: {
            $0.hex.caseInsensitiveCompare(colorHex ?? "") == .orderedSame
        }) {
            return L(choice.nameKey)
        }
        return showsInheritedColor ? L(inheritedTitle) : L("默认")
    }

    private static let choices = [
        Choice(hex: "#E95420", nameKey: "橙色"),
        Choice(hex: "#2F86AE", nameKey: "蓝绿色"),
        Choice(hex: "#3B82F6", nameKey: "蓝色"),
        Choice(hex: "#7C5CFC", nameKey: "靛紫色"),
        Choice(hex: "#A855F7", nameKey: "紫色"),
        Choice(hex: "#D946EF", nameKey: "洋红色"),
        Choice(hex: "#E11D48", nameKey: "玫红色"),
        Choice(hex: "#16A34A", nameKey: "绿色"),
        Choice(hex: "#0D9488", nameKey: "青绿色"),
        Choice(hex: "#CA8A04", nameKey: "金色"),
        Choice(hex: "#EA580C", nameKey: "深橙色"),
        Choice(hex: "#64748B", nameKey: "灰蓝色"),
    ]

    var body: some View {
        HStack(spacing: 8) {
            if !compact {
                Text(L(title))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            Button {
                isPresented.toggle()
            } label: {
                if compact {
                    Circle()
                        .fill(swatchColor)
                        .frame(width: 13, height: 13)
                        .overlay(Circle().stroke(Theme.hairline.opacity(0.8), lineWidth: 0.6))
                } else {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(swatchColor)
                            .frame(width: 13, height: 13)
                        Text(statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                palette
            }
        }
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                colorHex = nil
                isPresented = false
            } label: {
                HStack(spacing: 8) {
                    if let inherited = Color(hex: inheritedHex) {
                        Circle()
                            .fill(inherited)
                            .frame(width: 15, height: 15)
                            .overlay(Circle().stroke(Color.primary.opacity(0.18), lineWidth: 0.5))
                    } else {
                        Image(systemName: "circle.dashed")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.secondary)
                    }
                    Text(hasInheritedColor ? L(inheritedTitle) : L("跟随默认颜色"))
                        .font(.system(size: 11))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(Self.choices) { choice in
                    Button {
                        colorHex = choice.hex
                        isPresented = false
                    } label: {
                        VStack(spacing: 4) {
                            Circle()
                                .fill(Color(hex: choice.hex) ?? Theme.accent)
                                .frame(width: 24, height: 24)
                                .overlay(Circle().stroke(Color.primary.opacity(0.16), lineWidth: 0.5))
                            Text(L(choice.nameKey))
                                .font(.system(size: 10))
                                .lineLimit(1)
                            Text(choice.hex)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(Theme.panelBackground)
    }
}

struct GroupEditorView: View {
    @EnvironmentObject private var app: AppState
    @ViewState private var group: HostGroup
    @ViewState private var defaults: GroupDefaults
    @ViewState private var jumpQuery = ""
    @ViewState private var jumpMessage: String?

    private let onSave: ((HostGroup) -> Void)?
    private let onCancel: (() -> Void)?

    init(
        group: HostGroup,
        onSave: ((HostGroup) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        _group = ViewState(wrappedValue: group)
        _defaults = ViewState(wrappedValue: group.defaults)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    /// The color this group itself would inherit from its parent chain.
    private var inheritedColorHex: String? {
        HostColor.inheritedHex(forGroupID: group.parentID, groups: app.groups)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("分组设置")).font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(L("取消")) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L("保存")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Divider()
            Form {
                TextField(L("名称"), text: $group.name)
                Picker(L("上级分组"), selection: $group.parentID) {
                    Text(L("顶级分组")).tag(UUID?.none)
                    ForEach(availableParents) { candidate in
                        Text(app.groupPath(for: candidate.id)).tag(Optional(candidate.id))
                    }
                }
                ColorChoicePicker(colorHex: $group.colorHex,
                                  inheritedHex: inheritedColorHex,
                                  inheritedTitle: "继承上级分组颜色")
                Text(L("组内主机未单独设置颜色时继承这里的颜色；子分组会继续向上查找最近的颜色。"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Section(L("默认值（向下继承）")) {
                    Picker(L("代理"), selection: proxySelection) {
                        Text(L("继承上级分组")).tag("inherit")
                        Text(L("不使用代理")).tag("direct")
                        ForEach(app.proxies) { proxy in
                            Text(proxy.name).tag(proxy.id.uuidString)
                        }
                    }
                    Text(L("代理与跳板机只能二选一：选了代理，下面的跳板机会被清空。"))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker(L("跳板机"), selection: jumpSelection) {
                        Text(L("继承上级分组")).tag("inherit")
                        Text(L("直连")).tag("direct")
                        Text(L("指定跳板机")).tag("custom")
                    }
                    jumpDetail
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
        .frame(width: 520, height: 600)
    }

    // MARK: - Jump defaults

    @ViewBuilder
    private var jumpDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch defaults.jumpPolicy {
            case .inherit:
                hint(inheritedJumpText)
            case .direct:
                EmptyView()
            case .hosts(let ids):
                jumpHostsEditor(ids)
            }
            hint(L("组内主机的跳板机设为「继承分组设置」时使用这里的选择；越近的分组优先，主机自己的设置优先。"))
        }
    }

    @ViewBuilder
    private func jumpHostsEditor(_ ids: [UUID]) -> some View {
        if ids.isEmpty {
            hint(L("按顺序经过 1–3 台主机；在下面输入名称或地址搜索，不会列出全部主机。"))
        } else {
            jumpChips(ids)
        }
        searchField
        if !jumpQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            jumpResults(ids)
        }
        if let jumpMessage {
            Text(jumpMessage)
                .font(.system(size: 10))
                .foregroundStyle(Theme.danger)
        }
    }

    private var searchField: some View {
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
    }

    private func jumpChips(_ ids: [UUID]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                if index > 0 {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.secondary)
                }
                let missing = app.host(id: id) == nil
                HStack(spacing: 4) {
                    Text(app.host(id: id)?.name ?? L("已失效的跳板机"))
                        .font(.system(size: 11))
                        .foregroundStyle(missing ? Theme.danger : Color.primary)
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
            !ids.contains(candidate.id)
                && (candidate.name.lowercased().contains(query)
                    || candidate.displayAddress.lowercased().contains(query))
        }.prefix(6))
    }

    private func toggleJump(_ id: UUID, on: Bool) {
        var ids: [UUID]
        if case .hosts(let current) = defaults.jumpPolicy {
            ids = current
        } else {
            ids = []
        }
        if on {
            guard !ids.contains(id) else { return }
            guard ids.count < 3 else {
                jumpMessage = L("最多只能串联 3 台跳板机")
                return
            }
            ids.append(id)
            jumpQuery = ""
        } else {
            ids.removeAll { $0 == id }
        }
        jumpMessage = nil
        defaults.jumpPolicy = .hosts(ids)
        defaults.proxyPolicy = RouteRules.proxyPolicy(
            afterSelectingJump: defaults.jumpPolicy,
            current: defaults.proxyPolicy
        )
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func jumpNames(_ ids: [UUID]) -> String {
        ids.map { app.host(id: $0)?.name ?? L("已失效的跳板机") }
            .joined(separator: " → ")
    }

    private var inheritedJumpText: String {
        var visited: Set<UUID> = [group.id]
        var currentID = group.parentID
        while let id = currentID, let ancestor = app.group(id: id), visited.insert(id).inserted {
            switch ancestor.defaults.jumpPolicy {
            case .direct:
                return L("当前继承自「%@」：直连", ancestor.name)
            case .hosts(let ids) where !ids.isEmpty:
                return L("当前继承自「%@」：%@", ancestor.name, jumpNames(ids))
            case .hosts:
                return L("当前继承自「%@」：直连", ancestor.name)
            case .inherit:
                currentID = ancestor.parentID
            }
        }
        return L("上级分组未设置跳板机，等同直连")
    }

    // MARK: - Bindings

    private var proxySelection: Binding<String> {
        Binding(get: {
            switch defaults.proxyPolicy {
            case .inherit: return "inherit"
            case .direct: return "direct"
            case .use(let id): return id.uuidString
            }
        }, set: { value in
            switch value {
            case "inherit":
                defaults.proxyPolicy = .inherit
            case "direct":
                defaults.proxyPolicy = .direct
            default:
                guard let id = UUID(uuidString: value) else { return }
                defaults.proxyPolicy = .use(id)
                // Proxy and jump chain are alternatives, never two stages.
                defaults.jumpPolicy = RouteRules.jumpPolicy(
                    afterSelectingProxy: .use(id),
                    current: defaults.jumpPolicy
                )
                jumpQuery = ""
                jumpMessage = nil
            }
        })
    }

    private var jumpSelection: Binding<String> {
        Binding(get: {
            switch defaults.jumpPolicy {
            case .inherit: return "inherit"
            case .direct: return "direct"
            case .hosts: return "custom"
            }
        }, set: { value in
            jumpQuery = ""
            jumpMessage = nil
            switch value {
            case "inherit":
                defaults.jumpPolicy = .inherit
            case "custom":
                if case .hosts = defaults.jumpPolicy { return }
                defaults.jumpPolicy = .hosts([])
            default:
                defaults.jumpPolicy = .direct
            }
        })
    }

    // MARK: - Saving

    private func save() {
        if case .hosts(let ids) = defaults.jumpPolicy, ids.isEmpty {
            jumpMessage = L("请选择至少一台跳板机，或选择直连")
            return
        }
        let route = RouteRules.normalized(proxy: defaults.proxyPolicy, jump: defaults.jumpPolicy)
        defaults.proxyPolicy = route.proxy
        defaults.jumpPolicy = route.jump
        var updated = group
        updated.defaults = defaults
        if let onSave {
            onSave(updated)
        } else {
            app.saveGroup(updated)
        }
    }

    private func cancel() {
        if let onCancel {
            onCancel()
        } else {
            app.editingGroup = nil
        }
    }

    private var availableParents: [HostGroup] {
        let blocked = blockedGroupIDs(startingAt: group.id)
        return app.groups.filter { !blocked.contains($0.id) }
    }

    /// A group may not be re-parented under itself or any of its descendants.
    private func blockedGroupIDs(startingAt rootID: UUID) -> Set<UUID> {
        var blocked: Set<UUID> = [rootID]
        var didAdd = true
        while didAdd {
            didAdd = false
            for candidate in app.groups {
                guard let parentID = candidate.parentID, blocked.contains(parentID) else { continue }
                if blocked.insert(candidate.id).inserted { didAdd = true }
            }
        }
        return blocked
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
