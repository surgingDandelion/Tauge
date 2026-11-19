import SwiftUI
import UniformTypeIdentifiers
import ShellXKit

/// The landing surface shown when no tab and no workspace is selected.
///
/// Two columns only: a scrollable list of workspaces and host groups on the
/// left, the cards of the selected group on the right. Groups no longer stack
/// down the page, so a catalog with twenty groups still fits one screen.
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

struct StartPageView: View {
    @EnvironmentObject private var app: AppState
    @ViewState private var query = ""
    @ViewState private var isAreaDropTarget = false
    @FocusState private var searchFocused: Bool

    typealias Selection = StartPageSelection

    private var selection: Selection {
        get { app.startPageSelection }
        nonmutating set { app.startPageSelection = newValue }
    }

    /// A group includes all descendant hosts by default. The toggle is kept
    /// beside the selection so leaving the page and coming back preserves the
    /// user's choice between the complete subtree and the selected group only.
    private var showsDescendants: Bool {
        get { app.startPageShowsDescendants }
        nonmutating set { app.startPageShowsDescendants = newValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                collectionList
                    .frame(width: 210)
                Divider().opacity(0.5)
                hostArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider().opacity(0.5)
            footer
        }
        .background(Theme.windowGradient)
        .onChange(of: selection) { _ in
            showsDescendants = true
        }
        .onAppear {
            // A group can be deleted while the page is away; do not come back to
            // an empty list.
            if case .group(let id) = app.startPageSelection, app.group(id: id) == nil {
                app.startPageSelection = .all
            }
        }
    }

    // MARK: - Header

    private var headerSummary: String {
        [L(app.hosts.count, " 台主机"),
         L(app.groups.count, " 个分组"),
         L(app.boards.count, " 个工作区")].joined(separator: " · ")
    }

    private var header: some View {
        HStack(spacing: 10) {
            TechAppLogo(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("起始页"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .tracking(0.2)
                Text(headerSummary)
                    .font(TechFont.mono(9, .medium))
                    .foregroundStyle(Theme.secondary.opacity(0.92))
            }
            Spacer(minLength: 12)
            searchField
            TechActionButton(systemName: "arrow.up.arrow.down",
                             title: L("新建 SFTP"),
                             isEnabled: !app.hosts.isEmpty) {
                app.beginNewSFTPTab()
            }
            .help(L("选择一台或多台服务器，打开 SFTP 标签"))
            TechActionButton(systemName: "plus", title: L("新建主机")) {
                app.editingHost = SSHHost(name: L("新主机"))
            }
            .help(L("新建一台主机"))
            Menu {
                Button(L("新建分组…")) { app.beginNewGroup() }
                Button(L("新建工作区…")) { app.promptCreateBoard() }
                Divider()
                Button(L("导入 ~/.ssh/config")) { app.importSSHConfig() }
                Button(L("从 Termius 导入…")) { app.beginTermiusImport() }
                Divider()
                Button(L("快速打开…")) { app.showQuickOpen() }
                Button(L("传输中心")) { app.showingTransferCenter = true }
                Button(L("设置…")) { app.showingSettings = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 26, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .fill(LinearGradient(colors: [Theme.cardTop, Theme.cardBottom],
                                                 startPoint: .top,
                                                 endPoint: .bottom))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .strokeBorder(Theme.hairline.opacity(0.85), lineWidth: 0.8)
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            .help(L("更多"))
        }
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(searchFocused ? Theme.accent : Theme.secondary)
            TextField(L("搜索主机、地址、标签"), text: $query)
                .textFieldStyle(.plain)
                .font(TechFont.mono(10.5))
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 16, height: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Theme.secondary.opacity(0.10))
                        )
                }
                .buttonStyle(.plain)
                .help(L("清空搜索"))
            }
        }
        .padding(.horizontal, 7)
        .frame(width: 210, height: 26)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.fieldBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(searchFocused ? Theme.accent.opacity(0.55) : Theme.hairline.opacity(0.9),
                              lineWidth: 0.8)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(searchFocused ? Theme.accent.opacity(0.8) : Color.clear)
                .frame(height: 1)
                .padding(.horizontal, 5)
        }
        .shadow(color: searchFocused ? Theme.accent.opacity(0.12) : Color.clear,
                radius: 4, y: 0)
        .onExitCommand {
            if query.isEmpty { searchFocused = false } else { query = "" }
        }
    }

    // MARK: - Left column

    private struct GroupRow: Identifiable {
        let group: HostGroup
        let depth: Int
        /// Hosts that live in this group itself — the same set the grid shows,
        /// so the number next to the name always matches what you see.
        let count: Int
        /// Every group below this one (direct children and deeper).
        let descendantCount: Int
        var id: UUID { group.id }
    }

    private var groupRows: [GroupRow] {
        var result: [GroupRow] = []
        func walk(_ nodes: [SidebarGroupNode], depth: Int) {
            for node in nodes {
                result.append(GroupRow(group: node.group,
                                       depth: depth,
                                       count: app.hosts(inGroup: node.group.id,
                                                        includingDescendants: true).count,
                                       descendantCount: countDescendants(node)))
                walk(node.children, depth: depth + 1)
            }
        }
        walk(app.sidebarTree, depth: 0)
        return result
    }

    private func countDescendants(_ node: SidebarGroupNode) -> Int {
        node.children.reduce(0) { $0 + 1 + countDescendants($1) }
    }

    private var selectedGroupDescendants: Int {
        guard case .group(let id) = selection else { return 0 }
        return groupRows.first { $0.id == id }?.descendantCount ?? 0
    }

    private var collectionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if !app.boards.isEmpty {
                    sectionLabel(L("工作区"), addHelp: L("新建工作区"), addAction: { app.promptCreateBoard() })
                    ForEach(app.boards) { board in
                        StartListRow(symbol: "rectangle.split.3x3",
                                     title: board.name,
                                     detail: String(board.panes.count),
                                     isSelected: false,
                                     accent: board.colorHex.flatMap { Color(hex: $0) },
                                     action: { app.openBoardTab(board.id) })
                            .contextMenu {
                                Button(L("编辑工作区…")) { app.editingBoard = board }
                                Button(L("连接全部窗格")) { app.openBoardTab(board.id) }
                                Button(L("关闭工作区标签")) { app.closeBoardTab(board.id) }
                            }
                    }
                }

                sectionLabel(L("分组"), addHelp: L("新建分组"), addAction: { app.beginNewGroup() })
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
                ForEach(groupRows) { row in
                    // The sidebar is hidden by default, so the list carries the
                    // whole group lifecycle: create a child, rename, delete.
                    StartListRow(symbol: row.depth == 0 ? "folder" : "folder.badge.minus",
                                 title: row.group.name,
                                 detail: String(row.count),
                                 isSelected: selection == .group(row.group.id),
                                 indentation: CGFloat(row.depth) * 12,
                                 accent: row.group.colorHex.flatMap { Color(hex: $0) },
                                 onDropHost: { app.moveHost($0, onto: nil, in: row.group.id) },
                                 action: { selection = .group(row.group.id) })
                        .contextMenu {
                            Button(L("连接组内全部主机")) {
                                app.openTabs(for: app.hosts(inGroup: row.group.id))
                            }
                            Button(L("新建主机到此分组")) {
                                var host = SSHHost(name: L("新主机"))
                                host.groupID = row.group.id
                                app.editingHost = host
                            }
                            Divider()
                            Button(L("新建子分组")) { app.beginNewGroup(parentID: row.group.id) }
                            Button(L("重命名分组")) {
                                app.editingGroup = app.group(id: row.group.id) ?? row.group
                            }
                            Button(L("删除分组"), role: .destructive) {
                                let confirmed = Prompt.confirm(
                                    title: L("删除分组“") + row.group.name + "”？",
                                    message: L("分组内的主机会移动到“未分组”，子分组会一并删除。此操作不可撤销。"),
                                    destructiveTitle: L("删除"))
                                if confirmed { app.deleteGroup(row.group.id) }
                            }
                        }
                }
                if !app.ungroupedHosts.isEmpty {
                    StartListRow(symbol: "tray",
                                 title: L("未分组"),
                                 detail: String(app.ungroupedHosts.count),
                                 isSelected: selection == .ungrouped,
                                 onDropHost: { app.moveHost($0, onto: nil, in: nil) },
                                 action: { selection = .ungrouped })
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(Theme.sidebarBackground)
    }

    private func addButton(_ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16, height: 14)
                .background(
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(Theme.tagBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(Theme.hairline.opacity(0.7), lineWidth: 0.6)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func sectionLabel(_ title: String, addHelp: String? = nil, addAction: (() -> Void)? = nil) -> some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Theme.accent.opacity(0.75))
                .frame(width: 2, height: 7)
            Text(title)
                .font(TechFont.mono(9, .semibold))
                .tracking(0.4)
                .foregroundStyle(Theme.secondary)
            Rectangle()
                .fill(Theme.hairline.opacity(0.7))
                .frame(height: 0.5)
            if let addHelp, let addAction {
                addButton(addHelp, action: addAction)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }

    // MARK: - Right column

    private var currentHosts: [SSHHost] {
        switch selection {
        case .all: return app.hosts
        case .favorites: return app.favoriteHosts
        case .recent: return app.recentHosts
        case .group(let id): return app.hosts(inGroup: id, includingDescendants: showsDescendants)
        case .ungrouped: return app.ungroupedHosts
        }
    }

    private var visibleHosts: [SSHHost] {
        let base = currentHosts
        guard !query.isEmpty else { return base }
        return base.filter { app.matchesSearch($0, query: query) }
    }

    private var selectionTitle: String {
        switch selection {
        case .all: return L("全部主机")
        case .favorites: return L("收藏")
        case .recent: return L("最近连接")
        case .group(let id): return app.groupPath(for: id)
        case .ungrouped: return L("未分组")
        }
    }

    /// Groups are listed separately, so the group path only shows as a caption
    /// when the grid mixes several groups.
    private var showsGroupCaption: Bool {
        switch selection {
        case .all, .favorites, .recent: return true
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(query.isEmpty ? selectionTitle : L("搜索结果"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .tracking(0.2)
                TechTag(text: query.isEmpty
                        ? String(visibleHosts.count) + L(" 台")
                        : String(visibleHosts.count) + L(" 个结果"))
                if query.isEmpty, !showsDescendants, selectedGroupDescendants > 0,
                   case .group = selection {
                    Text(L("不含 ") + String(selectedGroupDescendants) + L(" 个子分组"))
                        .font(TechFont.mono(9))
                        .foregroundStyle(Theme.secondary.opacity(0.8))
                }
                Spacer(minLength: 8)
                if !query.isEmpty {
                    Text(L("在整个目录中搜索"))
                        .font(TechFont.mono(9))
                        .foregroundStyle(Theme.secondary.opacity(0.8))
                } else if case .group(let id) = selection {
                    if selectedGroupDescendants > 0 {
                        areaButton(showsDescendants
                                   ? L("仅本组")
                                   : L("含子分组（") + String(selectedGroupDescendants) + "）") {
                            showsDescendants.toggle()
                        }
                    }
                    areaButton(L("全部连接")) {
                        app.openTabs(for: app.hosts(inGroup: id,
                                                    includingDescendants: showsDescendants))
                    }
                    areaButton(L("新建主机")) {
                        var host = SSHHost(name: L("新主机"))
                        host.groupID = id
                        app.editingHost = host
                    }
                    areaButton(L("新建子分组")) { app.beginNewGroup(parentID: id) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if app.hosts.isEmpty {
                        emptyHosts
                    } else if visibleHosts.isEmpty {
                        emptySelection
                    } else {
                        hostGrid(visibleHosts)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .overlay(alignment: .top) {
                    if isAreaDropTarget {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.35),
                                          style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
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
            .background { TechDotGrid() }
        }
    }

    /// Neutral pill used for the small actions in the header row. The old
    /// `.link` style painted every one of them system blue.
    private func areaButton(_ title: String, action: @escaping () -> Void) -> some View {
        TechActionButton(title: title, kind: .ghost, height: 20, action: action)
    }

    private func hostGrid(_ hosts: [SSHHost]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 420),
                                     spacing: 12,
                                     alignment: .top)],
                  alignment: .leading,
                  spacing: 12) {
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
                Button(L("新建主机到此分组")) {
                    var host = SSHHost(name: L("新主机"))
                    host.groupID = id
                    app.editingHost = host
                }
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

    // MARK: - Footer

    /// The bottom row is the only place the start page advertises shortcuts, so
    /// the two toolbar actions (new SFTP / new host) lead it. The drag-help
    /// sentence on the right is the first thing to drop when the window gets
    /// narrow: the hints are the point of the row, the sentence is a bonus.
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            footerRow(showsDragHelp: true)
            footerRow(showsDragHelp: false)
        }
        .padding(.horizontal, 18)
        .frame(height: 26)
    }

    private func footerRow(showsDragHelp: Bool) -> some View {
        HStack(spacing: 14) {
            hint("⇧⌘T", L("新建 SFTP"))
            hint("⌘N", L("新建主机"))
            hint("⌘T", L("新建标签"))
            hint("⇧⌘B", L("新建工作区"))
            hint("⌘K", L("快速打开"))
            hint("⌘F", L("终端查找"))
            Spacer(minLength: 0)
            if showsDragHelp {
                Text(L("双击连接 · 拖动卡片可排序，拖到左侧分组即移动"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private func hint(_ keys: String, _ title: String) -> some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(TechFont.mono(8.5, .semibold))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(Theme.tagBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .strokeBorder(Theme.hairline.opacity(0.7), lineWidth: 0.6)
                )
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.secondary)
        }
        .fixedSize()
    }
}

// MARK: - Rows

private struct StartListRow: View {
    let symbol: String
    let title: String
    var detail: String = ""
    var isSelected: Bool
    var indentation: CGFloat = 0
    var accent: Color? = nil
    /// Set to nil when the row cannot receive hosts (收藏 / 最近连接).
    var onDropHost: ((UUID) -> Void)? = nil
    let action: () -> Void

    @ViewState private var hovering = false
    @ViewState private var isDropTarget = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? (accent ?? Theme.accent) : (accent ?? Theme.secondary))
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                TechTag(text: detail, tint: isSelected ? Theme.accent : nil)
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? (accent ?? Theme.accent).opacity(0.11)
                              : (hovering ? Color.primary.opacity(0.05) : Color.clear))
                    Rectangle()
                        .fill(isSelected ? (accent ?? Theme.accent) : Color.clear)
                        .frame(width: 2, height: 12)
                        .padding(.leading, 2)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isDropTarget ? Theme.accent.opacity(0.55) : Color.clear,
                                  lineWidth: 1)
            )
            .padding(.leading, indentation)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onDrop(of: [UTType.text], isTargeted: $isDropTarget) { providers in
            guard let onDropHost else { return false }
            HostDropLoader.load(providers) { onDropHost($0) }
            return true
        }
    }
}

/// Muted, light/dark friendly tints. Kept away from the system blue on
/// purpose: eighteen blue tiles read like a 2015 admin console.
enum HostPalette {
    private static let colors: [Color] = [
        Color(red: 0.26, green: 0.47, blue: 0.48),
        Color(red: 0.36, green: 0.41, blue: 0.53),
        Color(red: 0.55, green: 0.45, blue: 0.32),
        Color(red: 0.46, green: 0.37, blue: 0.51),
        Color(red: 0.35, green: 0.46, blue: 0.34),
        Color(red: 0.55, green: 0.36, blue: 0.33),
        Color(red: 0.38, green: 0.44, blue: 0.49),
        Color(red: 0.50, green: 0.42, blue: 0.40),
    ]

    static func tint(for id: UUID) -> Color {
        // Stable across launches: hashValue is seeded per process.
        let sum = id.uuidString.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return colors[sum % colors.count]
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
    let host: SSHHost
    var caption: String?
    @ViewState private var hovering = false
    @ViewState private var isDropTarget = false

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

    /// Hosts can carry their own color; the rest get a stable muted tint so the
    /// grid stays scannable without falling back to system blue.
    private var customTint: Color {
        host.colorHex.flatMap { Color(hex: $0) } ?? HostPalette.tint(for: host.id)
    }

    private var iconColor: Color {
        customTint
    }

    private var cardContentBase: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: [customTint.opacity(hovering ? 0.26 : 0.18),
                                                      customTint.opacity(hovering ? 0.15 : 0.10)],
                                             startPoint: .top,
                                             endPoint: .bottom))
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(customTint.opacity(hovering ? 0.55 : 0.35), lineWidth: 0.8)
                    // Generic server glyph until the host has been logged into at
                    // least once; then the detected OS logo takes its place.
                    HostPlatformIcon(platform: app.platform(for: host.id),
                                     detail: app.platformInfo(for: host.id)?.detail,
                                     size: 16,
                                     fallbackColor: iconColor)
                        .frame(width: 30, height: 30)
                    Rectangle()
                        .fill(customTint.opacity(hovering ? 0.9 : 0.5))
                        .frame(width: 4, height: 1)
                        .padding(.top, 3)
                        .padding(.trailing, 4)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(host.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .tracking(0.1)
                            .lineLimit(1)
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 7.5))
                                .foregroundStyle(Theme.warning)
                        }
                    }
                    Text(host.displayAddress)
                        .font(TechFont.mono(10, .medium))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                // Reserve the action width even when hidden: inserting the
                // buttons into the stack on hover shortened the name field and
                // made long host names visibly truncate under the pointer.
                HStack(spacing: 4) {
                    TechIconButton(systemName: "play.fill",
                                   help: L("连接"),
                                   tint: Theme.accent) {
                        app.openTab(for: host)
                    }
                    TechIconButton(systemName: "arrow.up.arrow.down",
                                   help: L("新建 SFTP 标签"),
                                   tint: Theme.secondary) {
                        app.openSFTPTab(for: host)
                    }
                }
                .frame(width: 48, alignment: .trailing)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .animation(.easeOut(duration: 0.1), value: hovering)
            }

            // The chip row is always laid out, even when a host has no caption,
            // jump host, proxy or tags. Without the reserved height a card
            // without chips was ~16pt shorter than its neighbours, so the grid
            // looked ragged.
            HStack(spacing: 4) {
                if let caption, !caption.isEmpty {
                    chip(caption)
                }
                if let jumpCount {
                    chip(L("跳板 ×") + String(jumpCount), systemName: "arrow.triangle.branch")
                }
                if let proxyChip {
                    chip(proxyChip, systemName: "network")
                }
                ForEach(visibleTags.prefix(2), id: \.self) { tag in
                    chip(tag, systemName: "tag")
                }
                Spacer(minLength: 0)
            }
            .frame(height: Self.chipRowHeight, alignment: .leading)
            HStack(spacing: 6) {
                Text(lastUsedText)
                    .font(TechFont.mono(8.5))
                    .foregroundStyle(Theme.secondary.opacity(0.82))
                Spacer(minLength: 0)
                if host.useCount > 0 {
                    Text(host.useCount == 1
                         ? L("用过 1 次")
                         : L("用过 ") + String(host.useCount) + L(" 次"))
                        .font(TechFont.mono(8.5))
                        .foregroundStyle(Theme.secondary.opacity(0.82))
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: Self.cardMinHeight, alignment: .topLeading)
        .techCard(cornerRadius: 9,
                  hovered: hovering || isDropTarget,
                  selected: isSelected || isDropTarget,
                  accent: isDropTarget ? Color.primary : customTint)
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

    /// Reserved height of the chip/metadata row and the smallest height a card
    /// is allowed to take, both in points. Equal values keep every card in a
    /// grid row identical no matter what metadata the host carries.
    private static let chipRowHeight: CGFloat = 16
    private static let cardMinHeight: CGFloat = 96

    private func handleHostDrop(_ providers: [NSItemProvider]) -> Bool {
        HostDropLoader.load(providers) { dragged in
            app.moveHost(dragged, onto: host.id, in: host.groupID)
        }
        return true
    }

    private func chip(_ text: String, systemName: String? = nil) -> some View {
        TechTag(text: text, systemName: systemName, maxCharacters: 26)
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

