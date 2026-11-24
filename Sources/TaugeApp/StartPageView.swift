import SwiftUI
import UniformTypeIdentifiers
import TaugeKit

/// Which collection the start page's right column shows.
///
/// It lives on `AppState` rather than in the view: opening a host in another tab
/// tears the start page down, and a view-local selection came back as “全部主机”
/// every time the page was shown again.
enum StartPageSelection: Hashable {
    case all
    case favorites
    case recent
    case group(UUID)
    case ungrouped
}

/// The landing surface shown when no terminal or workspace tab is selected.
struct StartPageView: View {
    @EnvironmentObject private var app: AppState
    @ViewState private var isAreaDropTarget = false

    typealias Selection = StartPageSelection

    private var query: String {
        app.startPageQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selection: Selection {
        get { app.startPageSelection }
        nonmutating set {
            if app.showingCatalogSearch { app.showStartPage() }
            app.startPageSelection = newValue
        }
    }

    /// A group includes all descendant hosts by default. The toggle is kept
    /// beside the selection so leaving the page and coming back preserves the
    /// user's choice between the complete subtree and the selected group only.
    private var showsDescendants: Bool {
        get { app.startPageShowsDescendants }
        nonmutating set { app.startPageShowsDescendants = newValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            if app.settings.startPageSidebarVisible {
                collectionList
                    .frame(width: 216)
                Rectangle()
                    .fill(Theme.separator)
                    .frame(width: 1)
            }
            Group {
                if app.showingCatalogSearch {
                    CatalogSearchView()
                } else {
                    hostArea
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.cardBackground)
        .onChange(of: selection) { _ in
            showsDescendants = true
            revealSelection()
        }
        .onAppear {
            if case .group(let id) = selection, app.group(id: id) == nil {
                app.startPageSelection = .all
            }
            revealSelection()
        }
    }

    // MARK: - Navigation

    private struct GroupRow: Identifiable {
        let group: HostGroup
        let depth: Int
        let count: Int
        let hasChildren: Bool
        var id: UUID { group.id }
    }

    private var groupRows: [GroupRow] {
        var counts: [UUID: Int] = [:]
        var result: [GroupRow] = []

        func count(_ node: SidebarGroupNode) -> Int {
            if let cached = counts[node.id] { return cached }
            let total = node.children.reduce(node.hosts.count) {
                $0 + count($1)
            }
            counts[node.id] = total
            return total
        }

        func walk(_ branch: [SidebarGroupNode], depth: Int) {
            for node in branch {
                result.append(GroupRow(group: node.group, depth: depth, count: count(node),
                                       hasChildren: !node.children.isEmpty))
                if !app.startPageCollapsedGroups.contains(node.id) {
                    walk(node.children, depth: depth + 1)
                }
            }
        }

        walk(app.catalogTree, depth: 0)
        return result
    }

    private func ancestors(of groupID: UUID) -> [HostGroup] {
        var result: [HostGroup] = []
        var visited: Set<UUID> = [groupID]
        var next = app.group(id: groupID)?.parentID
        while let id = next, visited.insert(id).inserted, let group = app.group(id: id) {
            result.append(group)
            next = group.parentID
        }
        return result.reversed()
    }

    private var selectedGroupDescendants: Int {
        guard case .group(let id) = selection else { return 0 }
        let groupsByParent = Dictionary(grouping: app.groups, by: \.parentID)
        var visited: Set<UUID> = [id]
        var remaining: [UUID] = [id]
        while let parent = remaining.popLast() {
            for child in groupsByParent[parent, default: []] where visited.insert(child.id).inserted {
                remaining.append(child.id)
            }
        }
        return visited.count - 1
    }

    private func revealSelection() {
        guard case .group(let id) = selection else { return }
        let ancestorIDs = ancestors(of: id).map(\.id)
        let collapsed = app.startPageCollapsedGroups.subtracting(ancestorIDs)
        if collapsed != app.startPageCollapsedGroups {
            app.startPageCollapsedGroups = collapsed
        }
    }

    private func toggleGroup(_ groupID: UUID) {
        if app.startPageCollapsedGroups.remove(groupID) != nil { return }
        app.startPageCollapsedGroups.insert(groupID)
        if case .group(let id) = selection, ancestors(of: id).contains(where: { $0.id == groupID }) {
            app.startPageSelection = .group(groupID)
        }
    }

    private var collectionList: some View {
        let ungrouped = app.catalogUngroupedHosts
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                sectionLabel(L("工作区"), addHelp: L("新建工作区")) { app.promptCreateBoard() }
                ForEach(app.boards) { board in
                    StartListRow(symbol: "rectangle.split.2x2",
                                 title: board.name,
                                 detail: String(board.panes.count),
                                 isSelected: false,
                                 accent: board.colorHex.flatMap { Color(hex: $0) },
                                 isWorkspace: true,
                                 action: { app.openBoardTab(board.id) })
                        .contextMenu {
                            Button(L("编辑工作区…")) { app.editingBoard = board }
                            Button(L("连接全部窗格")) { app.openBoardTab(board.id) }
                            Button(L("关闭工作区标签")) { app.closeBoardTab(board.id) }
                        }
                }

                Rectangle()
                    .fill(Theme.separator.opacity(0.75))
                    .frame(height: 1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 12)

                sectionLabel(L("连接库"))
                StartListRow(symbol: "square.grid.2x2",
                             title: L("全部主机"),
                             detail: String(app.hosts.count),
                             isSelected: selection == .all,
                             action: { selection = .all })
                if !app.favoriteHosts.isEmpty {
                    StartListRow(symbol: "star",
                                 title: L("收藏"),
                                 detail: String(app.favoriteHosts.count),
                                 isSelected: selection == .favorites,
                                 action: { selection = .favorites })
                }
                if !app.recentHosts.isEmpty {
                    StartListRow(symbol: "clock",
                                 title: L("最近连接"),
                                 detail: String(app.recentHosts.count),
                                 isSelected: selection == .recent,
                                 action: { selection = .recent })
                }

                sectionLabel(L("分组"), addHelp: L("新建分组")) { app.beginNewGroup() }
                    .padding(.top, 14)
                ForEach(groupRows, content: groupRow)
                if !ungrouped.isEmpty {
                    StartListRow(symbol: "tray",
                                 title: L("未分组"),
                                 detail: String(ungrouped.count),
                                 isSelected: selection == .ungrouped,
                                 onDropHost: { app.moveHost($0, onto: nil, in: nil) },
                                 action: { selection = .ungrouped })
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 14)
        }
        .background(Theme.cardBackground)
        .accessibilityLabel(L("分组"))
    }

    private func groupRow(_ row: GroupRow) -> some View {
        let isExpanded = !app.startPageCollapsedGroups.contains(row.id)
        return StartListRow(symbol: row.hasChildren && isExpanded ? "folder.fill" : "folder",
                            title: row.group.name,
                            detail: String(row.count),
                            isSelected: selection == .group(row.id),
                            depth: row.depth,
                            accent: row.group.colorHex.flatMap { Color(hex: $0) },
                            disclosure: row.hasChildren
                                ? StartListRow.Disclosure(isExpanded: isExpanded, action: { toggleGroup(row.id) })
                                : nil,
                            onDropHost: { app.moveHost($0, onto: nil, in: row.id) },
                            action: { selection = .group(row.id) })
            .contextMenu {
                Button(L("连接组内全部主机")) { app.openTabs(for: app.hosts(inGroup: row.id)) }
                Button(L("新建主机到此分组")) { newHost(in: row.id) }
                Divider()
                Button(L("新建子分组")) { app.beginNewGroup(parentID: row.id) }
                Button(L("编辑分组…")) { app.editingGroup = app.group(id: row.id) ?? row.group }
                Button(L("删除分组"), role: .destructive) {
                    let confirmed = Prompt.confirm(
                        title: L("删除分组“") + row.group.name + "”？",
                        message: L("分组内的主机会移动到“未分组”，子分组会一并删除。此操作不可撤销。"),
                        destructiveTitle: L("删除"))
                    if confirmed { app.deleteGroup(row.id) }
                }
            }
    }

    private func sectionLabel(_ title: String,
                              addHelp: String? = nil,
                              addAction: (() -> Void)? = nil) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let addHelp, let addAction {
                Button(action: addAction) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 23, height: 23)
                        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.separator, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .help(addHelp)
                .accessibilityLabel(addHelp)
            }
        }
        .padding(.horizontal, 7)
        .padding(.bottom, 4)
    }

    private func newHost(in groupID: UUID) {
        var host = SSHHost(name: L("新主机"))
        host.groupID = groupID
        app.editingHost = host
    }

    // MARK: - Right column

    private var currentHosts: [SSHHost] {
        switch selection {
        case .all: return app.hosts
        case .favorites: return app.favoriteHosts
        case .recent: return app.recentHosts
        case .group(let id): return app.hosts(inGroup: id, includingDescendants: showsDescendants)
        case .ungrouped: return app.catalogUngroupedHosts
        }
    }

    private var visibleHosts: [SSHHost] {
        let base = currentHosts
        guard !query.isEmpty else { return base }
        return base.filter { app.matchesSearch($0, query: query) }
    }

    private struct HostGroupSection: Identifiable {
        let group: HostGroup?
        let hosts: [SSHHost]
        var id: UUID? { group?.id }
    }

    private func hostGroupSections(for hosts: [SSHHost]) -> [HostGroupSection] {
        let rootID: UUID?
        switch selection {
        case .all:
            rootID = nil
        case .group(let id) where showsDescendants && selectedGroupDescendants > 0:
            rootID = id
        default:
            return []
        }

        let groups = app.groups.sorted {
            $0.sortIndex == $1.sortIndex ? $0.name < $1.name : $0.sortIndex < $1.sortIndex
        }
        let groupsByParent = Dictionary(grouping: groups, by: \.parentID)
        let groupIDs = Set(groups.map(\.id))
        let hostsByGroup = Dictionary(grouping: hosts) { host in
            host.groupID.flatMap { groupIDs.contains($0) ? $0 : nil }
        }
        var sections: [HostGroupSection] = []
        var visited = Set<UUID>()

        func walk(_ group: HostGroup) {
            guard visited.insert(group.id).inserted else { return }
            if let directHosts = hostsByGroup[group.id] {
                sections.append(HostGroupSection(group: group, hosts: directHosts))
            }
            for child in groupsByParent[group.id] ?? [] {
                walk(child)
            }
        }

        if let rootID {
            if let root = app.group(id: rootID) { walk(root) }
        } else {
            for root in groupsByParent[nil] ?? [] { walk(root) }
            // An imported group may be disconnected from the root tree.
            for group in groups where !visited.contains(group.id) { walk(group) }
            if let ungrouped = hostsByGroup[nil] {
                sections.append(HostGroupSection(group: nil, hosts: ungrouped))
            }
        }
        return sections
    }

    private var selectionTitle: String {
        switch selection {
        case .all: return L("全部主机")
        case .favorites: return L("收藏")
        case .recent: return L("最近连接")
        case .group(let id): return app.group(id: id)?.name ?? L("分组")
        case .ungrouped: return L("未分组")
        }
    }

    /// Flat collections show the group path on each card.
    private var showsGroupCaption: Bool {
        switch selection {
        case .favorites, .recent: return true
        default: return false
        }
    }

    /// Where a drop on the empty area should append the host. Mixed views
    /// (全部/收藏/最近) have no single destination, so they reject the drop.
    private enum DropScope {
        case none
        case group(UUID?)
    }

    private var dropScope: DropScope {
        switch selection {
        case .group(let id): return .group(id)
        case .ungrouped: return .group(nil)
        case .all, .favorites, .recent: return .none
        }
    }

    private var hostArea: some View {
        let hosts = visibleHosts
        let sections = hostGroupSections(for: hosts)
        return VStack(alignment: .leading, spacing: 0) {
            scopeHeader(hostCount: hosts.count)
                .padding(.horizontal, 26)
                .padding(.top, 24)
                .padding(.bottom, 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if app.hosts.isEmpty {
                        emptyHosts
                    } else if hosts.isEmpty {
                        emptySelection
                    } else if sections.isEmpty {
                        hostGrid(hosts)
                    } else {
                        groupedHostSections(sections)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .overlay {
                if isAreaDropTarget {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.text], isTargeted: $isAreaDropTarget) { providers in
                guard case .group(let groupID) = dropScope else { return false }
                HostDropLoader.load(providers) { dragged in
                    app.moveHost(dragged, onto: nil, in: groupID)
                }
                return true
            }
        }
    }

    private func scopeHeader(hostCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            let path: [HostGroup] = {
                guard case .group(let id) = selection else { return [] }
                return ancestors(of: id)
            }()
            ViewThatFits(in: .horizontal) {
                breadcrumb(path).fixedSize(horizontal: true, vertical: false)
                breadcrumb(Array(path.suffix(1)))
            }
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(query.isEmpty ? selectionTitle : L("搜索结果"))
                    .font(.system(size: 29, weight: .bold))
                    .tracking(-0.8)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(String(hostCount) + L(query.isEmpty ? " 台主机" : " 个结果"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize()
                Spacer(minLength: 6)
                if !query.isEmpty {
                    Text(selectionTitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                } else if case .group(let id) = selection {
                    if selectedGroupDescendants > 0 {
                        TechActionButton(systemName: "list.bullet.indent",
                                         title: showsDescendants
                                             ? L("仅本组")
                                             : L("含子分组（") + String(selectedGroupDescendants) + "）",
                                         height: 29) { showsDescendants.toggle() }
                    }
                    groupActions(id)
                }
            }
        }
    }

    private func breadcrumb(_ path: [HostGroup]) -> some View {
        HStack(spacing: 7) {
            crumb(L("连接库")) { selection = .all }
            ForEach(path) { group in
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .accessibilityHidden(true)
                crumb(group.name) { selection = .group(group.id) }
            }
        }
    }

    private func crumb(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func groupActions(_ groupID: UUID) -> some View {
        Menu {
            Button(L("全部连接")) {
                app.openTabs(for: app.hosts(inGroup: groupID, includingDescendants: showsDescendants))
            }
            Button(L("新建主机到此分组")) { newHost(in: groupID) }
            Divider()
            Button(L("分组设置")) { app.editingGroup = app.group(id: groupID) }
            Button(L("新建子分组")) { app.beginNewGroup(parentID: groupID) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 28, height: 29)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.separator, lineWidth: 1)
                }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("更多"))
        .accessibilityLabel(L("更多"))
    }

    private func groupedHostSections(_ sections: [HostGroupSection]) -> some View {
        LazyVStack(alignment: .leading, spacing: 21) {
            ForEach(sections) { section in
                let title = selection == .all ? app.groupPath(for: section.id) : (section.group?.name ?? L("未分组"))
                let identity = HostColor.inheritedHex(forGroupID: section.id, groups: app.groups)
                    .flatMap(Color.init(hex:))
                    .map(Theme.quietIdentity)
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(identity ?? Theme.secondary.opacity(0.6))
                            .frame(width: 3, height: 12)
                            .accessibilityHidden(true)
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .help(title)
                            .accessibilityAddTraits(.isHeader)
                        Text(String(section.hosts.count) + L(" 台"))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .fixedSize()
                        Spacer(minLength: 0)
                    }
                    hostGrid(section.hosts)
                }
            }
        }
    }

    private func hostGrid(_ hosts: [SSHHost]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 218, maximum: 420),
                                     spacing: 14,
                                     alignment: .top)],
                  alignment: .leading,
                  spacing: 14) {
            ForEach(hosts) { host in
                StartHostCard(host: host,
                              caption: showsGroupCaption ? groupPath(for: host) : nil)
            }
        }
    }

    private var emptySelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(query.isEmpty ? L("这里还没有主机") : L("没有匹配的主机"))
                .font(.system(size: 12.5, weight: .medium))
            Text(query.isEmpty
                 ? L("可以从其他分组拖动主机进来，或直接在这里新建一台。")
                 : L("换个关键词试试，搜索会匹配名称、地址、用户名、标签与备注。"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            if case .group(let id) = selection, query.isEmpty {
                if selectedGroupDescendants > 0, !showsDescendants {
                    Text(L("这个分组下还有 ") + String(selectedGroupDescendants)
                         + L(" 个子分组；点右上角「含子分组」可以一起查看。"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.secondary)
                }
                Button(L("新建主机到此分组")) { newHost(in: id) }
                .controlSize(.small)
            }
        }
        .padding(.top, 8)
    }

    private var emptyHosts: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("还没有主机"))
                    .font(.system(size: 13, weight: .semibold))
                Text(L("先加一台服务器，之后就能在左侧按分组浏览。"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 12) {
                setupCard(L("新建主机"), L("地址、认证与终端设置"), "plus.circle") {
                    app.editingHost = SSHHost(name: L("新主机"))
                }
                setupCard(L("导入 ~/.ssh/config"), L("复用已有的主机配置与跳板"), "square.and.arrow.down") {
                    app.importSSHConfig()
                }
                setupCard(L("新建工作区"), L("一次铺开一组服务器"), "rectangle.split.3x3") {
                    app.promptCreateBoard()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .techCard(cornerRadius: 10, glow: false)
    }

    private func setupCard(_ title: String,
                           _ detail: String,
                           _ symbol: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary.opacity(0.75))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.cardTop, Theme.cardBottom],
                                         startPoint: .top,
                                         endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.hairline.opacity(0.8), lineWidth: 0.7)
            )
        }
        .buttonStyle(TechButtonStyle(kind: .ghost))
        .help(title)
    }

    private func groupPath(for host: SSHHost) -> String {
        guard let groupID = host.groupID else { return L("未分组") }
        return app.groupPath(for: groupID)
    }

}

// MARK: - Rows

private struct StartListRow: View {
    struct Disclosure {
        let isExpanded: Bool
        let action: () -> Void
    }

    let symbol: String
    let title: String
    var detail: String = ""
    var isSelected: Bool
    var depth: Int = 0
    var accent: Color? = nil
    var isWorkspace = false
    var disclosure: Disclosure? = nil
    var onDropHost: ((UUID) -> Void)? = nil
    let action: () -> Void

    @ViewState private var hovering = false
    @ViewState private var isDropTarget = false
    @Environment(\.colorScheme) private var colorScheme

    private var iconTint: Color {
        guard let accent else { return Theme.secondary }
        return colorScheme == .dark ? Theme.quietIdentity(accent) : accent
    }

    var body: some View {
        if let onDropHost {
            row.onDrop(of: [UTType.text], isTargeted: $isDropTarget) { providers in
                HostDropLoader.load(providers, into: onDropHost)
                return true
            }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 0) {
            // Indent each level while leaving enough space for the name and
            // host count even when imported groups are nested unusually deeply.
            ForEach(0..<min(depth, 7), id: \.self) { _ in
                Rectangle()
                    .fill(Theme.separator)
                    .frame(width: 1, height: 30)
                    .frame(width: 13, alignment: .trailing)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 0) {
                if let disclosure {
                    let label = disclosure.isExpanded ? L("收起") : L("展开")
                    Button(action: disclosure.action) {
                        Image(systemName: disclosure.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 18, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(label)
                    .accessibilityLabel(label + " " + title)
                } else if !isWorkspace {
                    Color.clear
                        .frame(width: 18)
                        .accessibilityHidden(true)
                }

                Button(action: action) {
                    HStack(spacing: isWorkspace ? 8 : 7) {
                        Image(systemName: symbol)
                            .font(.system(size: isWorkspace ? 13 : 11.5, weight: .regular))
                            .foregroundStyle(iconTint)
                            .frame(width: isWorkspace ? 23 : 15, height: isWorkspace ? 23 : nil)
                            .background {
                                if isWorkspace {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(iconTint.opacity(0.12))
                                }
                            }
                            .accessibilityHidden(true)
                        Text(title)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if !detail.isEmpty {
                            Text(detail)
                                .font(TechFont.mono(10.5))
                                .foregroundStyle(Theme.secondary)
                                .fixedSize()
                        }
                    }
                    .padding(.leading, isWorkspace ? 7 : 2)
                    .padding(.trailing, 7)
                    .frame(height: isWorkspace ? 35 : 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(title)
                .accessibilityLabel(title)
                .accessibilityValue(detail)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Theme.tagBackground : (hovering ? Theme.rowHover : .clear))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isDropTarget ? Theme.accent.opacity(0.6)
                                  : (isSelected ? Theme.separator : .clear), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering = $0 }
    }
}

/// Reads the UUID a host drag carries. Providers are loaded off the main
/// thread, so the callback hops back before touching AppState.
enum HostDropLoader {
    static func load(_ providers: [NSItemProvider], into handler: @escaping @MainActor (UUID) -> Void) {
        for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let string = object as? String, let id = UUID(uuidString: string) else { return }
                Task { @MainActor in handler(id) }
            }
            return
        }
    }
}

// MARK: - Host card

private struct StartHostCard: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.colorScheme) private var colorScheme
    let host: SSHHost
    var caption: String?
    @ViewState private var hovering = false
    @ViewState private var isDropTarget = false

    private static let cornerRadius: CGFloat = 11
    private static let titleInk = Theme.dynamic(light: 0x28313C, dark: 0xE7EBF1)
    private static let tileBase = Theme.dynamic(light: 0xF9FAFC, dark: 0x22252C)
    private static let iconWell = Theme.dynamic(light: 0xEFF2F6, dark: 0x2C3038)
    private static let activeEdge = Theme.dynamic(light: 0xA7B1BF, dark: 0x525C69)

    private var isFavorite: Bool {
        host.tags.contains { $0 == "favorite" || $0 == "收藏" }
    }

    private var isSelected: Bool {
        app.selectedSidebarHostID == host.id
    }

    private var jumpCount: Int? {
        if case .hosts(let ids) = host.jumpPolicy, !ids.isEmpty { return ids.count }
        return nil
    }

    private var proxyChip: String? {
        guard case .use(let id) = host.proxyPolicy else { return nil }
        let name = app.proxies.first { $0.id == id }?.name
        return name.map { L("代理 %@", $0) } ?? L("代理")
    }

    private var lastUsedText: String {
        guard let date = host.lastUsedAt else { return L("尚未连接") }
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return L("刚刚连接") }
        if seconds < 3600 { return L("上次连接 %d 分钟前", Int(seconds / 60)) }
        if seconds < 86400 { return L("上次连接 %d 小时前", Int(seconds / 3600)) }
        if seconds < 86400 * 30 {
            let days = Int(seconds / 86400)
            // "%d days ago" reads wrong for a single day; English has no
            // plural rule in the flat key/value table, so give it its own key.
            if days == 1 { return L("上次连接昨天") }
            return L("上次连接 %d 天前", days)
        }
        let formatter = DateFormatter()
        formatter.locale = TaugeL10n.shared.locale
        formatter.dateFormat = "yyyy-MM-dd"
        return L("上次连接 %@", formatter.string(from: date))
    }

    private var visibleTags: [String] {
        host.tags.filter { $0 != "favorite" && $0 != "收藏" }
    }

    private var identityColor: Color? {
        app.resolvedColorHex(for: host).flatMap(Color.init(hex:))
    }

    private var cardContentBase: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                platformTile
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(host.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Self.titleInk)
                            .lineLimit(1)
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.quietIdentity(Theme.warning))
                                .accessibilityLabel(L("收藏"))
                        }
                    }
                    Text(host.displayAddress)
                        .font(TechFont.mono(11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            metadata
                .padding(.trailing, showsActions ? 71 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 24)
                .overlay(alignment: .trailing) { cardActions }

            Rectangle()
                .fill(Theme.separator.opacity(0.8))
                .frame(height: 1)

            HStack(spacing: 5) {
                Text(lastUsedText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if host.useCount > 0 {
                    Text(host.useCount == 1
                         ? L("用过 1 次")
                         : L("用过 ") + String(host.useCount) + L(" 次"))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [Theme.cardBackground, Self.tileBase],
                                     startPoint: .top, endPoint: .bottom))
                .silverHoverSheen(hovered: hovering, cornerRadius: Self.cornerRadius)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(isSelected || isDropTarget ? Self.activeEdge
                              : hovering ? Theme.hairline : Theme.cardStroke,
                              lineWidth: isDropTarget ? 1.6 : 1)
                .allowsHitTesting(false)
        }
        .shadow(color: Theme.shadow.opacity(0.45), radius: 2, y: 1)
    }

    private var platformTile: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let identity = identityColor
        let tint = identity ?? .clear
        let strength = colorScheme == .dark ? 0.16 : 0.24
        let outline = identity.map { Theme.quietIdentity($0).opacity(0.28) } ?? Theme.separator

        return HostPlatformIcon(platform: app.platform(for: host.id),
                                detail: app.platformInfo(for: host.id)?.detail,
                                size: 22,
                                fallbackColor: Theme.secondary,
                                subdued: true)
            .frame(width: 41, height: 41)
            .background {
                shape.fill(Self.iconWell)
                    .overlay {
                        shape.fill(LinearGradient(colors: [tint.opacity(strength * 0.55), tint.opacity(strength)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
            }
            .overlay {
                shape.strokeBorder(outline, lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
    }

    private var metadata: some View {
        HStack(spacing: 5) {
            if let caption, !caption.isEmpty {
                chip(caption, systemName: "folder")
            }
            if let jumpCount {
                chip(L("跳板 ×") + String(jumpCount), systemName: "arrow.triangle.branch", isRoute: true)
            }
            if let proxyChip {
                chip(proxyChip, systemName: "network", isRoute: true)
            }
            ForEach(visibleTags.prefix(2), id: \.self) { tag in
                chip(tag, systemName: "tag")
            }
        }
    }

    private enum CardAction: Hashable {
        case connect, sftp, edit
    }

    @FocusState private var focusedAction: CardAction?

    private var showsActions: Bool { hovering || isSelected || focusedAction != nil }

    private var cardActions: some View {
        HStack(spacing: 0) {
            cardAction(.connect, systemName: "play", title: L("连接")) {
                app.openTab(for: host)
            }
            cardAction(.sftp, systemName: "arrow.up.arrow.down", title: L("新建 SFTP 标签")) {
                app.openSFTPTab(for: host)
            }
            cardAction(.edit, systemName: "pencil", title: L("编辑主机")) {
                app.editingHost = host
            }
        }
        .padding(1)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.hairline.opacity(0.7), lineWidth: 0.8)
                .allowsHitTesting(false)
        }
        .opacity(showsActions ? 1 : 0)
        .allowsHitTesting(showsActions)
    }

    private func cardAction(_ kind: CardAction, systemName: String, title: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 21, height: 21)
                .contentShape(Rectangle())
        }
        .buttonStyle(TechButtonStyle(kind: .ghost))
        .focused($focusedAction, equals: kind)
        .help(title)
        .accessibilityLabel(title)
    }

    var body: some View {
        interactiveCard
            .contextMenu { HostContextMenu(app: app, host: host) }
            .help(host.name + "  " + host.displayAddress + (host.notes.isEmpty ? "" : "\n" + host.notes))
    }

    private var interactiveCard: some View {
        cardContentBase
            .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(object: host.id.uuidString as NSString)
        }
        .onDrop(of: [UTType.text], isTargeted: $isDropTarget) { providers in
            handleHostDrop(providers)
        }
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            app.openTab(for: host)
        }
        .onTapGesture {
            app.selectedSidebarHostID = host.id
        }
    }

    private func handleHostDrop(_ providers: [NSItemProvider]) -> Bool {
        HostDropLoader.load(providers) { dragged in
            app.moveHost(dragged, onto: host.id, in: host.groupID)
        }
        return true
    }

    private func chip(_ text: String, systemName: String, isRoute: Bool = false) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemName)
                .font(.system(size: 9.5))
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 10.5))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(isRoute ? Color.primary : Theme.secondary)
        .padding(.horizontal, isRoute ? 4 : 0)
        .padding(.vertical, isRoute ? 2 : 0)
        .background(isRoute ? Theme.tagBackground : .clear, in: RoundedRectangle(cornerRadius: 4))
        .help(text)
    }
}

/// A separate view so the card body's modifier chain stays small enough for
/// the SwiftUI type-checker to solve quickly on every toolchain we support.
private struct HostContextMenu: View {
    let app: AppState
    let host: SSHHost

    private var isFavorite: Bool {
        host.tags.contains { $0 == "favorite" || $0 == "收藏" }
    }

    var body: some View {
        connectionItems
        Divider()
        editItems
        Divider()
        Button(L("删除主机…"), role: .destructive) { confirmDelete() }
    }

    @ViewBuilder
    private var connectionItems: some View {
        Button(L("连接")) { app.openTab(for: host) }
        Button(L("连接并打开 SFTP")) { app.openTab(for: host, showsSFTP: true) }
        Button(L("新建 SFTP 标签")) { app.openSFTPTab(for: host) }
        Button(L("在工作区中打开")) { app.openInBoard(hostID: host.id) }
    }

    @ViewBuilder
    private var editItems: some View {
        Button(L("编辑主机…")) { app.editingHost = host }
        Button(L("复制主机…")) { app.duplicateHost(host) }
        Button(isFavorite ? L("取消收藏") : L("收藏")) { app.toggleFavorite(host) }
    }

    private func confirmDelete() {
        if Prompt.confirm(title: L("删除「") + host.name + "」？",
                          message: L("会同时关闭它的终端。"),
                          destructiveTitle: L("删除")) {
            app.deleteHost(host.id)
        }
    }
}

