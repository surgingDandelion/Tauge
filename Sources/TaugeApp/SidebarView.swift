import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TaugeKit

struct SidebarView: View {
    @EnvironmentObject private var app: AppState
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if app.hosts.isEmpty && app.groups.isEmpty {
                emptyState
            } else if !app.searchText.isEmpty {
                searchResults
            } else {
                browser
            }
            Divider()
            footer
        }
        .background(Theme.sidebarBackground)
    }

    private var searchBar: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(searchFocused ? Theme.accent : Theme.secondary)
                .font(.system(size: 9.5, weight: .semibold))
            TextField(L("搜索主机、地址、标签（支持拼音）"), text: $app.searchText)
                .textFieldStyle(.plain)
                .font(TechFont.mono(10))
                .focused($searchFocused)
            if !app.searchText.isEmpty {
                Button {
                    app.searchText = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 14, height: 14)
                        .background(
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(Theme.secondary.opacity(0.10))
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.fieldBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(searchFocused ? Theme.accent.opacity(0.5) : Theme.hairline.opacity(0.8),
                              lineWidth: 0.7)
        )
        .padding(.horizontal, 8)
        .frame(height: 34)
        .onExitCommand {
            if app.searchText.isEmpty { searchFocused = false } else { app.searchText = "" }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "server.rack")
                .font(.system(size: 28))
                .foregroundStyle(Theme.secondary)
            Text(L("还没有主机"))
                .font(.system(size: 13, weight: .medium))
            Text(L("新建一台主机，或从 ~/.ssh/config 导入已有配置。"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
            TechActionButton(systemName: "plus", title: L("新建主机"), kind: .primary) {
                app.editingHost = SSHHost(name: L("新主机"))
            }
            TechActionButton(title: L("从 ~/.ssh/config 导入"), kind: .ghost) {
                app.importSSHConfig()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var searchResults: some View {
        let results = app.hosts.filter { app.matchesSearch($0, query: app.searchText) }
        return List {
            if results.isEmpty {
                Text(L("没有匹配的主机"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            } else {
                Section(L("搜索结果")) {
                    ForEach(results) { host in
                        HostRowView(host: host)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var browser: some View {
        List {
            if !app.favoriteHosts.isEmpty {
                Section(L("收藏")) {
                    ForEach(app.favoriteHosts) { host in
                        HostRowView(host: host)
                    }
                }
            }

            Section(L("分组")) {
                ForEach(app.sidebarTree) { node in
                    GroupNodeView(node: node)
                }
                ForEach(app.ungroupedHosts) { host in
                    HostRowView(host: host)
                }
                if app.sidebarTree.isEmpty && app.ungroupedHosts.isEmpty {
                    Button(L("新建第一个分组")) { app.beginNewGroup() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
            .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                loadDroppedHost(providers) { host in
                    app.moveHost(host, toGroup: nil)
                }
                return true
            }

            if !app.recentHosts.isEmpty {
                Section(L("最近")) {
                    ForEach(app.recentHosts) { host in
                        HostRowView(host: host)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu {
            Button(L("新建主机")) { app.editingHost = SSHHost(name: L("新主机")) }
            Button(L("新建分组")) { app.beginNewGroup() }
            Divider()
            Button(L("从 ~/.ssh/config 导入")) { app.importSSHConfig() }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            PaneMenuButton(systemName: "plus", help: L("新建")) {
                Button(L("新建主机")) { app.editingHost = SSHHost(name: L("新主机")) }
                Button(L("新建分组")) { app.beginNewGroup() }
                Divider()
                Button(L("新建代理")) { app.editingProxy = ProxyConfig(name: L("新代理")) }
                Button(L("导入私钥")) { app.showingKeyImporter = true }
            }

            PaneMenuButton(systemName: "square.and.arrow.down", help: L("导入或导出")) {
                Button(L("从 ~/.ssh/config 导入")) { app.importSSHConfig() }
                Button(L("从 Termius 导入…")) { app.beginTermiusImport() }
                Button(L("导入 Tauge 配置文件")) { app.importCatalog() }
                Button(L("导出 Tauge 配置文件")) { app.exportCatalog() }
            }

            Spacer()

            PaneIconButton(systemName: "gearshape", help: L("设置")) {
                app.showingSettings = true
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: 30)
    }

    private func loadDroppedHost(_ providers: [NSItemProvider], handler: @escaping (SSHHost) -> Void) {
        guard let provider = providers.first else { return }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, let id = UUID(uuidString: text) else { return }
            Task { @MainActor in
                if let host = app.host(id: id) { handler(host) }
            }
        }
    }
}

struct GroupNodeView: View {
    @EnvironmentObject private var app: AppState
    let node: SidebarGroupNode

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { app.expandedGroups.contains(node.group.id) },
            set: { app.setGroupExpanded(node.group, expanded: $0) }
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            ForEach(node.hosts) { host in
                HostRowView(host: host)
            }
            ForEach(node.children) { child in
                AnyView(GroupNodeView(node: child))
            }
        } label: {
            groupLabel
        }
        .onDrop(of: [UTType.text], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let text = object as? String, let id = UUID(uuidString: text) else { return }
                Task { @MainActor in
                    if let host = app.host(id: id) { app.moveHost(host, toGroup: node.group.id) }
                }
            }
            return true
        }
    }

    private var groupLabel: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color(hex: node.group.colorHex) ?? Theme.secondary)
                .frame(width: 2, height: 16)
            Image(systemName: "folder")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color(hex: node.group.colorHex) ?? Theme.secondary)
            Text(node.group.name)
                .font(.system(size: 12, weight: .medium))
                .tracking(0.1)
            Spacer()
            TechTag(text: String(subtreeHostCount(node)))
        }
        .contextMenu {
            Button(L("在此分组新建主机")) {
                app.editingHost = SSHHost(groupID: node.group.id, name: L("新主机"))
            }
            Button(L("连接分组内全部主机")) { app.openTabs(for: allHosts) }
            Button(L("新建子分组")) { app.beginNewGroup(parentID: node.group.id) }
            Button(L("编辑分组…")) { app.editingGroup = node.group }
            Button(L("删除分组"), role: .destructive) {
                let confirmed = Prompt.confirm(title: L("删除分组“") + node.group.name + "”？",
                                               message: L("分组内的主机会移动到“未分组”，子分组会一并删除。此操作不可撤销。"),
                                               destructiveTitle: L("删除"))
                if confirmed { app.deleteGroup(node.group.id) }
            }
        }
    }

    private func subtreeHostCount(_ node: SidebarGroupNode) -> Int {
        node.hosts.count + node.children.reduce(0) { partial, child in
            partial + subtreeHostCount(child)
        }
    }

    private var allHosts: [SSHHost] {
        subtreeHosts(node)
    }

    private func subtreeHosts(_ node: SidebarGroupNode) -> [SSHHost] {
        node.hosts + node.children.flatMap { subtreeHosts($0) }
    }
}

struct HostRowView: View {
    @EnvironmentObject private var app: AppState
    let host: SSHHost

    @ViewState private var hovering = false

    private var isSelected: Bool { app.selectedSidebarHostID == host.id }

    private var openTab: TerminalTab? {
        app.tabs.first { $0.hostID == host.id }
    }

    private var resolvedColor: Color? {
        app.resolvedColorHex(for: host).flatMap(Color.init(hex:))
    }

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(resolvedColor ?? Theme.secondary.opacity(0.35))
                .frame(width: 3, height: 20)
                .opacity(resolvedColor == nil ? (isSelected ? 0.7 : 0.4) : 1)
                .shadow(color: (isSelected ? resolvedColor?.opacity(0.55) : nil) ?? .clear,
                        radius: 3)
            HostPlatformIcon(platform: app.platform(for: host.id),
                             detail: app.platformInfo(for: host.id)?.detail,
                             size: 12)
            VStack(alignment: .leading, spacing: 0.5) {
                Text(host.name)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .tracking(0.1)
                    .foregroundStyle(resolvedColor ?? Color.primary)
                    .lineLimit(1)
                Text(host.displayAddress)
                    .font(TechFont.mono(8.5))
                    .foregroundStyle(Theme.secondary.opacity(0.9))
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            if let openTab {
                TechStatusDot(color: openTab.connectionState.isConnected
                              ? Theme.success
                              : Theme.secondary.opacity(0.6),
                              size: 5)
            }
            if host.tags.contains(where: { $0 == "favorite" || $0 == "收藏" }) {
                Image(systemName: "star.fill")
                    .font(.system(size: 7.5))
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected
                      ? AnyShapeStyle(LinearGradient(colors: [Theme.accent.opacity(0.17),
                                                               Theme.accent.opacity(0.07)],
                                                       startPoint: .leading,
                                                       endPoint: .trailing))
                      : (hovering ? AnyShapeStyle(Theme.rowHover)
                                  : AnyShapeStyle(Color.clear)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.32) : Color.clear, lineWidth: 0.7)
        )
        .shadow(color: isSelected ? Theme.accent.opacity(0.08) : Color.clear,
                radius: 3, y: 0.5)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.1)) { hovering = inside }
        }
        .onTapGesture(count: 2) { app.openTab(for: host) }
        .onTapGesture { app.selectedSidebarHostID = host.id }
        .onDrag { NSItemProvider(object: host.id.uuidString as NSString) }
        .contextMenu(menuItems: menu)
        .help(host.displayAddress + (host.username.isEmpty ? "" : " · " + host.username))
    }

    @ViewBuilder
    private func menu() -> some View {
        Button(L("连接")) { app.openTab(for: host) }
        Button(L("连接并打开 SFTP")) { app.openTab(for: host, showsSFTP: true) }
                                Button(L("新建 SFTP 标签")) { app.openSFTPTab(for: host) }
        Button(L("在工作区中打开")) { app.openInBoard(hostID: host.id) }
        Divider()
        Button(L("编辑主机…")) { app.editingHost = host }
        if app.platformInfo(for: host.id) != nil {
            Button(L("重新识别操作系统")) { app.redetectPlatform(hostID: host.id) }
        }
        Button(L("复制主机…")) { app.duplicateHost(host) }
        Button(host.tags.contains("favorite") ? L("取消收藏") : L("收藏")) { app.toggleFavorite(host) }
        Menu(L("移动至分组")) {
            Button(L("未分组")) { app.moveHost(host, toGroup: nil) }
            ForEach(app.groups) { group in
                Button(group.name) { app.moveHost(host, toGroup: group.id) }
            }
        }
        Divider()
        Button(L("删除主机"), role: .destructive) {
            let confirmed = Prompt.confirm(title: L("删除主机“") + host.name + "”？",
                                           message: L("主机的连接配置、保存的密码和私钥引用都会被删除。此操作不可撤销。"),
                                           destructiveTitle: L("删除"))
            if confirmed { app.deleteHost(host.id) }
        }
    }
}

extension Color {
    init?(hex: String?) {
        guard let hex, !hex.isEmpty else { return nil }
        var value = hex
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: Double((number >> 16) & 0xFF) / 255.0,
            green: Double((number >> 8) & 0xFF) / 255.0,
            blue: Double(number & 0xFF) / 255.0
        )
    }
}
