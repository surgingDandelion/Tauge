import AppKit
import SwiftUI
import TaugeKit

/// The full catalog search shares Quick Open's ranking but keeps a selected
/// result visible for inspecting its connection settings before opening it.
struct CatalogSearchView: View {
    @EnvironmentObject private var app: AppState
    @ViewState private var category: Category = .all
    @ViewState private var selectedID: String?
    @ViewState private var focusRequest = 0

    private enum Category: CaseIterable, Hashable {
        case all, hosts, workspaces, commands

        var title: String {
            switch self {
            case .all: return L("全部")
            case .hosts: return L("主机")
            case .workspaces: return L("工作区")
            case .commands: return L("命令")
            }
        }

        func includes(_ item: CommandPaletteItem) -> Bool {
            switch self {
            case .all: return true
            case .hosts: return item.host != nil
            case .workspaces: return item.isWorkspaceResult
            case .commands: return item.host == nil && !item.isWorkspaceResult
            }
        }
    }

    private var query: String { app.catalogSearchQuery }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var items: [CommandPaletteItem] {
        let results = app.commandPaletteResults(query: query)
        guard category == .all, !isSearching else { return results.filter(category.includes) }

        let frequent = results.enumerated().filter { $0.element.host != nil }.sorted { left, right in
            if left.element.weight != right.element.weight { return left.element.weight > right.element.weight }
            return left.offset < right.offset
        }
        // Other hosts are still available in the Hosts tab and every typed
        // query searches the full catalog.
        return frequent.prefix(3).map(\.element) + results.filter { $0.host == nil }
    }

    var body: some View {
        let results = items
        let selected = selectedItem(in: results)
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                header(resultCount: results.count)
                Divider()
                if let selected {
                    let width = geometry.size.width - 36
                    if width >= 610 {
                        HStack(alignment: .top, spacing: 14) {
                            resultList(results, selected: selected)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            Rectangle()
                                .fill(Theme.separator)
                                .frame(width: 1)
                                .accessibilityHidden(true)
                            ScrollView {
                                preview(for: selected)
                                    .padding(.vertical, 8)
                            }
                            .frame(width: min(290, width * 0.37))
                        }
                    } else {
                        resultList(results, selected: selected, includesPreview: true)
                    }
                } else {
                    emptyState
                }
                Divider()
                hints
            }
            .padding(.horizontal, 18)
            .padding(.top, 13)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panelBackground)
        .onChange(of: app.showingCommandPalette) { isShowing in
            if !isShowing, !app.hasPresentedSheet { focusRequest += 1 }
        }
        .onChange(of: app.hasPresentedSheet) { hasSheet in
            if !hasSheet, !app.showingCommandPalette { focusRequest += 1 }
        }
    }

    private func header(resultCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                TechIconButton(systemName: "chevron.left",
                               help: L("返回"),
                               tint: Theme.secondary) {
                    app.dismissCatalogSearch()
                }
                .accessibilityLabel(L("返回"))

                Text(L("全局搜索"))
                    .font(.system(size: 20, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                QuickOpenSearchField(query: query, onChange: setQuery, onKeyDown: handleKey,
                                     requiresActiveEditor: true, focusRequest: focusRequest)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .accessibilityIdentifier("catalog-search-field")
                if !query.isEmpty {
                    Button { setQuery("") } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("清空搜索"))
                    .accessibilityLabel(L("清空搜索"))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            HStack(spacing: 4) {
                ForEach(Category.allCases, id: \.self) { filter in
                    Button {
                        category = filter
                        selectedID = nil
                        focusRequest += 1
                    } label: {
                        Text(filter.title)
                            .font(.system(size: 11, weight: category == filter ? .semibold : .regular))
                            .lineLimit(1)
                            .foregroundStyle(category == filter ? Color.primary : Theme.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(category == filter ? Theme.tagBackground : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(category == filter ? .isSelected : [])
                }
                Spacer(minLength: 4)
                Text(L("%d 项", resultCount))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize()
            }
        }
        .padding(.bottom, 8)
    }

    private func resultList(_ results: [CommandPaletteItem],
                            selected: CommandPaletteItem,
                            includesPreview: Bool = false) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if includesPreview {
                        preview(for: selected)
                            .padding(.bottom, 5)
                    }

                    ForEach(SearchResultSection.grouped(results, title: sectionTitle(for:))) { section in
                        if let title = section.title {
                            SearchSectionTitle(title: title)
                                .padding(.horizontal, 6)
                                .padding(.top, 3)
                        }
                        ForEach(section.items) { item in
                            resultRow(item, selected: selected.id == item.id)
                                .id(item.id)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: selectedID) { id in
                if let id { proxy.scrollTo(id) }
            }
            .onChange(of: query) { _ in
                if let first = results.first, !includesPreview { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
    }

    private func sectionTitle(for item: CommandPaletteItem) -> String? {
        if isSearching { return nil }
        if category == .all, item.host != nil { return L("常用主机") }
        return item.groupTitle
    }

    private func resultRow(_ item: CommandPaletteItem, selected: Bool) -> some View {
        Button { selectedID = item.id } label: {
            HStack(spacing: 7) {
                SearchResultMark(item: item, size: 25)
                SearchResultText(item: item)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(selected ? Theme.rowSelection : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { activate(item) })
        .accessibilityIdentifier("catalog-\(item.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func preview(for item: CommandPaletteItem) -> some View {
        CatalogSearchPreview(item: item, open: { activate(item) }, openSFTP: { activate(item, prefersSFTP: true) },
                             edit: { if let host = item.host { app.editingHost = host } })
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 23, weight: .light))
            Text(L("没有匹配的主机、工作区或命令"))
                .foregroundStyle(Color.primary)
                .font(.system(size: 13, weight: .medium))
            Text(L("试着输入名称、地址、分组或标签的一部分"))
                .font(.system(size: 11))
        }
        .foregroundStyle(Theme.secondary)
        .multilineTextAlignment(.center)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hints: some View {
        HStack(spacing: 11) {
            SearchShortcutHint(keys: "↑↓", title: L("选择"))
            SearchShortcutHint(keys: "↩", title: L("打开"))
            SearchShortcutHint(keys: "⌘↩", title: "SFTP")
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.secondary)
        .frame(height: 29)
    }

    private func setQuery(_ text: String) {
        guard query != text else { return }
        selectedID = nil
        app.catalogSearchQuery = text
    }

    private func selectedItem(in results: [CommandPaletteItem]) -> CommandPaletteItem? {
        results.first { $0.id == selectedID } ?? results.first
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard app.showingCatalogSearch, !app.showingCommandPalette, !app.hasPresentedSheet, app.alert == nil else {
            return false
        }
        if event.keyCode == 53 {
            app.dismissCatalogSearch()
            return true
        }

        guard [125, 126, 36, 76].contains(event.keyCode) else { return false }
        let results = items
        guard let selected = selectedItem(in: results) else { return true }
        switch event.keyCode {
        case 125, 126:
            guard let index = results.firstIndex(where: { $0.id == selected.id }) else { return true }
            let next = QuickOpen.movedSelection(from: index, by: event.keyCode == 125 ? 1 : -1, count: results.count)
            selectedID = results[next].id
        default:
            activate(selected, prefersSFTP: event.modifierFlags.contains(.command))
        }
        return true
    }

    private func activate(_ item: CommandPaletteItem, prefersSFTP: Bool = false) {
        if item.host != nil || item.isWorkspaceResult {
            app.dismissCatalogSearch()
        }
        app.activateCommand(item, prefersSFTP: prefersSFTP)
    }
}

private struct CatalogSearchPreview: View {
    @EnvironmentObject private var app: AppState
    let item: CommandPaletteItem
    let open: () -> Void
    let openSFTP: () -> Void
    let edit: () -> Void

    var body: some View {
        let resolved = item.host.flatMap { HostColor.resolve(host: $0, groups: app.groups) }
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 8) {
                SearchResultMark(item: item, size: 35)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(resolved.flatMap { Color(hex: $0.hex) } ?? Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let host = item.host {
                        Text(platformLabel(for: host))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.secondary)
                    } else if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }

            if let host = item.host {
                facts(for: host, color: resolved)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { hostActions }
                    VStack(alignment: .leading, spacing: 4) { hostActions }
                }
            } else {
                TechActionButton(systemName: item.resultSymbol, title: L("打开"), action: open)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .techCard(cornerRadius: 9, glow: false)
    }

    private var hostActions: some View {
        Group {
            TechActionButton(systemName: "terminal", title: "SSH", action: open)
            TechActionButton(systemName: "folder", title: "SFTP", action: openSFTP)
            TechActionButton(systemName: "pencil", title: L("编辑"), action: edit)
        }
    }

    private func facts(for host: SSHHost, color: HostColor.Resolution?) -> some View {
        let tags = host.tags.filter { $0.lowercased() != "favorite" && $0 != "收藏" }
        return VStack(spacing: 0) {
            fact(L("连接地址")) {
                Text(address(for: host))
                    .font(TechFont.mono(10.5))
            }
            fact(L("分组")) {
                Text(app.groupPath(for: host.groupID))
            }
            if !tags.isEmpty {
                fact(L("主机标签")) { Text(tags.joined(separator: " · ")) }
            }
            fact(L("连接路径")) { Text(route(for: host)) }
            fact(L("配色")) {
                HStack(spacing: 4) {
                    if let color, let tint = Color(hex: color.hex) {
                        Circle().fill(tint).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                    Text(colorLabel(for: color))
                }
            }
        }
        .textSelection(.enabled)
    }

    private func fact<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(title)
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 76, alignment: .leading)
                value()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 10.5))
            .padding(.vertical, 5)
        }
    }

    private func address(for host: SSHHost) -> String {
        guard host.port != 22, !host.hostname.isEmpty else { return host.displayAddress }
        let hostname = host.hostname.contains(":") && !host.hostname.hasPrefix("[")
            ? "[\(host.hostname)]" : host.hostname
        let endpoint = "\(hostname):\(host.port)"
        return host.username.isEmpty ? endpoint : "\(host.username)@\(endpoint)"
    }

    private func platformLabel(for host: SSHHost) -> String {
        guard let info = app.platformInfo(for: host.id) else { return L("登录后自动识别操作系统") }
        return info.detail.isEmpty ? info.platform.displayName : info.detail
    }

    private func route(for host: SSHHost) -> String {
        let resolver = ConfigResolver(catalog: Catalog(groups: app.groups, hosts: app.hosts,
                                                       proxies: app.proxies, keys: app.keys))
        guard let config = try? resolver.effective(for: host) else { return L("连接设置无效") }
        var route: [String] = []
        if let proxy = config.proxy { route.append(L("代理 %@", proxy.name)) }
        if !config.jumps.isEmpty {
            route.append(L("跳板 ×") + String(config.jumps.count))
        }
        return route.isEmpty ? L("直连") : route.joined(separator: " · ")
    }

    private func colorLabel(for resolution: HostColor.Resolution?) -> String {
        guard let resolution else { return L("默认配色") }
        switch resolution.source {
        case .host: return L("主机自定义")
        case .group(_, let name): return L("继承「%@」", name)
        }
    }
}

private extension CommandPaletteItem {
    var isWorkspaceResult: Bool { id.hasPrefix("board-") }
    var resultSymbol: String {
        if isWorkspaceResult { return "square.grid.2x2" }
        return host == nil ? "command" : "server.rack"
    }
}

struct SearchResultSection: Identifiable {
    let id: String
    let title: String?
    var items: [CommandPaletteItem]

    static func grouped(_ items: [CommandPaletteItem],
                        title sectionTitle: (CommandPaletteItem) -> String?) -> [Self] {
        var sections: [Self] = []
        for item in items {
            let title = sectionTitle(item)
            if let last = sections.indices.last, sections[last].title == title {
                sections[last].items.append(item)
            } else {
                sections.append(Self(id: item.id, title: title, items: [item]))
            }
        }
        return sections
    }
}

struct SearchSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

struct SearchResultMark: View {
    @EnvironmentObject private var app: AppState
    let item: CommandPaletteItem
    let size: CGFloat

    var body: some View {
        let host = item.host
        let tint = host.flatMap { app.resolvedColorHex(for: $0) }.flatMap(Color.init(hex:)) ?? Theme.secondary
        Group {
            if let host {
                HostPlatformIcon(platform: app.platform(for: host.id),
                                 detail: app.platformInfo(for: host.id)?.detail,
                                 size: size * 0.54,
                                 fallbackColor: tint)
            } else {
                Image(systemName: item.resultSymbol)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .background(tint.opacity(host == nil ? 0.07 : 0.10), in: RoundedRectangle(cornerRadius: size * 0.24))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.24)
                .strokeBorder(tint.opacity(0.17), lineWidth: 0.7)
        }
        .accessibilityHidden(true)
    }
}

struct SearchResultText: View {
    let item: CommandPaletteItem

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(item.host == nil ? .system(size: 10) : TechFont.mono(10))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
        }
        .help(item.subtitle.isEmpty ? item.title : item.title + "\n" + item.subtitle)
    }
}

struct SearchKeycap: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(TechFont.mono(9, .medium))
            .fixedSize()
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Theme.cardStroke, lineWidth: 0.6)
            }
    }
}

struct SearchShortcutHint: View {
    let keys: String
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            SearchKeycap(keys: keys)
            Text(title).lineLimit(1).fixedSize()
        }
    }
}
