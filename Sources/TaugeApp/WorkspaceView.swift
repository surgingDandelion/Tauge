import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TaugeKit

struct WorkspaceView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            // The strip's hover hints hang below its edge.
            TabStripView()
                .zIndex(1)
            if !app.showingCatalogSearch, app.isWorkspaceSelected {
                BoardWorkspaceView()
            } else if !app.showingCatalogSearch, let tab = app.selectedTab {
                // The tab object owns showsSFTP/connectionState, so the tab content has to
                // observe it directly: AppState only publishes the tab list, and mutating a
                // tab in place would otherwise never re-render the workspace (the SFTP pane
                // simply would not appear when toggled).
                TabWorkspaceView(tab: tab)
            } else {
                StartPageView()
            }
        }
        .background(Theme.windowBackground)
    }
}

struct TabWorkspaceView: View {
    @ObservedObject var tab: TerminalTab

    var body: some View {
        // An SFTP tab is a browser on its own: no shell to split with.
        if tab.kind == .sftp {
            SFTPBrowserView(tab: tab)
        } else {
            TerminalSFTPStack(tab: tab)
        }
    }
}

/// Terminal above, SFTP browser below, separated by the same AppKit divider the
/// board uses. A plain `VSplitView` collapsed to zero height once the pane got
/// narrow enough, which looked exactly like "the SFTP panel disappeared".
struct TerminalSFTPStack: View {
    @ObservedObject var tab: TerminalTab
    @ViewState private var fraction: Double

    init(tab: TerminalTab) {
        self.tab = tab
        _fraction = ViewState(wrappedValue: tab.sftpSplitFraction)
    }

    var body: some View {
        TerminalSFTPLayout(showsSFTP: tab.showsSFTP, fraction: $fraction,
                           onFractionCommitted: { tab.sftpSplitFraction = $0 }) {
            TerminalPane(tab: tab)
        } browser: {
            SFTPBrowserView(tab: tab)
        }
    }
}

struct TerminalSFTPLayout<TerminalContent: View, BrowserContent: View>: View {
    let showsSFTP: Bool
    @Binding var fraction: Double
    let onFractionCommitted: (Double) -> Void
    @ViewBuilder let terminal: () -> TerminalContent
    @ViewBuilder let browser: () -> BrowserContent
    @ViewState private var dragBase: Double = 0

    var body: some View {
        GeometryReader { proxy in
            let usable = max(1, proxy.size.height - BoardSplitMetrics.gutter)
            let share = clamped(fraction, usable: usable)
            // Keep the browser header visible in short workspace panes.
            let bottomFloor = min(150, usable * 0.55)
            let terminalHeight = min(usable * share, max(40, usable - bottomFloor))
            VStack(spacing: 0) {
                // Both sizes share one AppKit host for the live terminal.
                terminal()
                    .frame(maxWidth: .infinity)
                    .frame(height: showsSFTP ? terminalHeight : proxy.size.height)
                if showsSFTP {
                    BoardSplitHandle(
                        axis: .vertical,
                        onBegin: { dragBase = fraction },
                        onMove: { delta in
                            fraction = clamped(dragBase + Double(delta) / Double(usable), usable: usable)
                        },
                        onEnd: { _ in onFractionCommitted(fraction) },
                        onReset: {
                            fraction = 0.5
                            onFractionCommitted(0.5)
                        }
                    )
                    .frame(height: BoardSplitMetrics.gutter)
                    browser()
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }

    private func clamped(_ value: Double, usable: CGFloat) -> Double {
        let minShare = Double(min(0.42, BoardSplitMetrics.minimumPane / usable))
        return min(max(value, minShare), 1 - minShare)
    }
}

struct TabStripView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        HStack(spacing: 7) {
            StartPageChipView()
                .fixedSize()
            ScrollViewReader { scroll in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(app.tabs) { tab in
                            TabChipView(tab: tab)
                                .id(tab.id)
                        }
                        ForEach(app.openBoards) { board in
                            BoardChipView(board: board)
                                .id(board.id)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 1)
                }
                .onChange(of: app.selectedTabID) { id in
                    if let id { scroll.scrollTo(id) }
                }
                .onChange(of: app.selectedBoardID) { id in
                    if let id { scroll.scrollTo(id) }
                }
            }
            stripDivider
            HStack(spacing: 3) {
                newTabMenu
                workspaceMenu

                if !app.showingCatalogSearch {
                    if app.isWorkspaceSelected {
                        stripDivider
                        BoardStripTools()
                    } else if let tab = app.selectedTab {
                        stripDivider
                        if tab.kind == .terminal {
                            SftpToggleButton(tab: tab)
                        }
                        StripButton(systemName: "pencil", help: L("编辑主机…"), isEnabled: app.host(id: tab.hostID) != nil) {
                            app.editingHost = app.host(id: tab.hostID)
                        }
                        StripButton(systemName: "arrow.clockwise", help: L("重新连接"), tip: L("重新连接"), keys: ["⌘R"]) {
                            app.reconnect(tab)
                        }
                    }
                }

                stripDivider
                StripButton(systemName: "arrow.up.arrow.down", help: L("传输中心（⇧⌘J）"), tip: L("传输中心"), keys: ["⇧⌘J"], badge: app.activeTransferCount) {
                    app.showingTransferCenter = true
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(Theme.tabRailBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.separator)
                .frame(height: 0.5)
        }
    }

    private var newTabMenu: some View {
        StripMenu(systemName: "plus", help: L("新建标签：SFTP 标签可以在一个窗口里同时连多个服务器"), tip: L("新建标签"), keys: ["⌘T", "⇧⌘T"]) {
            Button(L("新建 SFTP 标签…（选择主机，可多选）")) { app.beginNewSFTPTab() }
            Button(L("新建 SFTP 标签（当前主机）")) { app.openSFTPTabForSelection() }
            Button(L("新建终端标签（当前主机）")) {
                if let id = app.selectedSidebarHostID, let host = app.host(id: id) {
                    app.openTab(for: host)
                }
            }
            Divider()
            Menu(L("为指定主机新建 SFTP 标签")) {
                ForEach(app.hosts) { host in
                    Button(host.name) { app.openSFTPTab(for: host) }
                }
            }
        }
    }

    private var workspaceMenu: some View {
        StripMenu(systemName: "rectangle.grid.2x2", help: L("工作区：一块窗口里放多个分屏终端，和普通连接一样是顶部标签（⇧⌘B 新建）"), tip: L("工作区"), keys: ["⇧⌘B"]) {
            Button(L("新建工作区…")) { app.promptCreateBoard() }
            if !app.boards.isEmpty {
                Divider()
                ForEach(app.boards) { board in
                    Button {
                        app.openBoardTab(board.id)
                    } label: {
                        if app.openBoards.contains(where: { $0.id == board.id }) {
                            Label(board.name, systemImage: "checkmark")
                        } else {
                            Text(board.name)
                        }
                    }
                }
            }
        }
    }

    private var stripDivider: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(width: 1, height: 14)
            .padding(.horizontal, 3)
    }
}

struct SftpToggleButton: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var tab: TerminalTab
    var persistsBoard = false

    var body: some View {
        let title = tab.showsSFTP ? L("隐藏 SFTP 面板") : L("显示 SFTP 面板")
        StripButton(systemName: tab.showsSFTP ? "folder.fill" : "folder",
                    help: title, tip: title, keys: persistsBoard ? [] : ["⇧⌘O"],
                    isActive: tab.showsSFTP) {
            app.toggleSFTP(tab)
            if persistsBoard { app.scheduleBoardPersist() }
        }
    }
}

struct StartPageChipView: View {
    @EnvironmentObject private var app: AppState
    @ViewState private var hovering = false

    private var isSelected: Bool { app.isStartPageSelected }

    var body: some View {
        Button {
            app.showStartPage()
        } label: {
            HStack(spacing: 6) {
                TechAppLogo(size: 18)
                Text(L("起始页"))
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .modifier(TabRailChrome(selected: isSelected, hovering: hovering))
        .onHover { hovering = $0 }
        .shortcutTip(L("起始页：所有主机和工作区"), keys: ["⇧⌘H", "⌘0"], align: .leading)
    }
}

struct TabChipView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var tab: TerminalTab
    @ViewState private var hovering = false
    @ViewState private var isDropTarget = false

    private var isSelected: Bool { app.selectedTabID == tab.id && !app.showingCatalogSearch }
    private var name: String { TerminalTab.label(for: tab.host) }
    private var kind: String { tab.kind == .sftp ? "SFTP" : "SSH" }

    var body: some View {
        HStack(spacing: 1) {
            Button {
                app.selectTab(tab)
            } label: {
                HStack(spacing: 6) {
                    TabRailGlyph(symbol: tab.kind == .sftp ? "folder" : "terminal",
                                 tint: identityTint, status: connectionIndicator)
                    Text(name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: 145, alignment: .leading)
                }
                .padding(.leading, 7)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(name) · \(kind)"))
            .accessibilityValue(Text(tab.connectionState.label))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .help("\(name) · \(kind)")

            TabRailClose(visible: hovering || isSelected, help: L("关闭标签（⌘W）")) {
                app.closeTab(tab)
            }
        }
        .padding(.trailing, 3)
        .modifier(TabRailChrome(selected: isSelected, hovering: hovering, dropTarget: isDropTarget))
        .onHover { hovering = $0 }
        .onDrag {
            NSItemProvider(object: tab.id.uuidString as NSString)
        }
        // Dropping one tab on another splits both terminals into a workspace.
        .onDrop(of: [UTType.text], isTargeted: $isDropTarget) { providers in
            app.handleTabDrop(providers: providers, onto: tab)
        }
        .contextMenu {
            Button(L("重新连接")) { app.reconnect(tab) }
            Button(L("关闭标签")) { app.closeTab(tab) }
            Button(L("关闭其他标签")) {
                for other in app.tabs where other.id != tab.id { app.closeTab(other) }
            }
        }
    }

    private var identityTint: Color? {
        let host = app.host(id: tab.hostID) ?? tab.host
        return Color(hex: app.resolvedColorHex(for: host))
    }

    private var connectionIndicator: Color? {
        switch tab.connectionState {
        case .connected: return Theme.success
        case .connecting: return Theme.warning
        case .failed, .disconnected: return Theme.danger
        case .idle: return nil
        }
    }
}

struct BoardChipView: View {
    @EnvironmentObject private var app: AppState
    let board: BoardDefinition
    @ViewState private var hovering = false
    @ViewState private var isDropTarget = false

    private var isSelected: Bool { app.isWorkspaceSelected && app.selectedBoardID == board.id && !app.showingCatalogSearch }

    var body: some View {
        HStack(spacing: 1) {
            Button {
                app.selectBoardTab(board.id)
            } label: {
                HStack(spacing: 6) {
                    TabRailGlyph(symbol: "rectangle.grid.2x2", tint: Color(hex: board.colorHex))
                    Text(board.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: 145, alignment: .leading)
                }
                .padding(.leading, 7)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .help(board.name)

            TabRailClose(visible: hovering || isSelected, help: L("关闭工作区标签（终端会断开，工作区配置保留）")) {
                app.closeBoardTab(board.id)
            }
        }
        .padding(.trailing, 3)
        .modifier(TabRailChrome(selected: isSelected, hovering: hovering, dropTarget: isDropTarget))
        .onHover { hovering = $0 }
        // Dropping a terminal here adds it to this workspace as a pane.
        .onDrop(of: [UTType.text], isTargeted: $isDropTarget) { providers in
            app.handleTabDrop(providers: providers, ontoBoard: board.id)
        }
        .contextMenu {
            Button(L("编辑工作区…")) { app.editingBoard = board }
            Button(L("连接全部窗格")) { app.openBoardTab(board.id) }
            Button(L("关闭工作区标签")) { app.closeBoardTab(board.id) }
        }
    }
}

private struct TabRailChrome: ViewModifier {
    let selected: Bool
    let hovering: Bool
    var dropTarget = false

    func body(content: Content) -> some View {
        let cornerRadius: CGFloat = 7
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .foregroundStyle(selected ? Color.primary : Theme.secondary)
            .background {
                shape.fill(surface)
                    .overlay { shape.strokeBorder(edge, lineWidth: 0.75) }
                    .silverHoverSheen(hovered: hovering && !dropTarget, cornerRadius: cornerRadius)
                    .shadow(color: selected ? Theme.shadow.opacity(0.65) : .clear, radius: 1.5, y: 0.75)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
    }

    private var surface: LinearGradient {
        let colors: [Color]
        if dropTarget {
            colors = [Theme.accent.opacity(0.11), Theme.accent.opacity(0.07)]
        } else if selected {
            colors = [Theme.dynamic(light: 0xFCFDFF, dark: 0x303540),
                      Theme.dynamic(light: 0xEDF1F5, dark: 0x272C35)]
        } else if hovering {
            colors = [Theme.dynamic(light: 0xF8FAFC, dark: 0x2C313B),
                      Theme.dynamic(light: 0xEDF1F5, dark: 0x252A33)]
        } else {
            colors = [.clear, .clear]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private var edge: Color {
        if dropTarget { return Theme.accent.opacity(0.62) }
        return selected ? Theme.hairline.opacity(0.75) : .clear
    }
}

private struct TabRailGlyph: View {
    let symbol: String
    let tint: Color?
    var status: Color? = nil

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint.map { Theme.quietIdentity($0) } ?? Theme.secondary)
            .frame(width: 20, height: 20)
            .overlay(alignment: .bottomTrailing) {
                if let status {
                    Circle()
                        .fill(status.opacity(0.85))
                        .frame(width: 4, height: 4)
                        .padding(.bottom, 2)
                }
            }
            .accessibilityHidden(true)
    }
}

private struct TabRailClose: View {
    let visible: Bool
    let help: String
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 20, height: 21)
                .background(hovering ? Theme.rowHover : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .accessibilityLabel(help)
        .accessibilityHidden(!visible)
        .help(help)
    }
}

struct TerminalPane: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var tab: TerminalTab
    @ViewState private var showsFindBar = false
    @ViewState private var findQuery = ""
    @ViewState private var findIndex = 0
    @ViewState private var findTotal = 0
    @FocusState private var findFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TerminalContainer(
                bridge: tab.bridge,
                settings: app.settings,
                initialColumns: tab.terminalColumns,
                initialRows: tab.terminalRows,
                // One funnel for typed keys, pastes and drops, so command
                // broadcast sees every byte that leaves this pane.
                onSend: { data in app.sendInput(data, from: tab) },
                onFilesDropped: { urls in
                    handleDroppedFiles(urls)
                },
                onFocus: {
                    // Only meaningful in a board: a plain tab always owns the window.
                    guard app.isWorkspaceSelected else { return }
                    app.focusBoardPane(tab.id)
                }
            )
            .id(tab.id)
            // Text inset only: the terminal still fills the pane edge to edge (no card,
            // no rounded corners), but the glyphs keep a small margin. The padding ring
            // is painted in the terminal's own background colour so it reads as one surface.
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: TerminalPalette.background))

            if showsFindBar {
                findBar
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if !tab.connectionState.isConnected {
                connectionOverlay
            }

            Button("") { toggleFindBar() }
                .keyboardShortcut("f", modifiers: .command)
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .opacity(0)
        }
        .background(Color(nsColor: TerminalPalette.background))
    }

    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
            TextField(L("在终端中查找"), text: $findQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(width: 160)
                .focused($findFocused)
                .onSubmit { findNext() }
                .onExitCommand { closeFindBar() }
                .onChange(of: findQuery) { _ in findNext() }
            if findTotal > 0 {
                Text("\(findIndex)/\(findTotal)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
            Button {
                findPrevious()
            } label: {
                Image(systemName: "chevron.up").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            Button {
                findNext()
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            Button {
                closeFindBar()
            } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func toggleFindBar() {
        showsFindBar.toggle()
        if showsFindBar {
            findFocused = true
            findNext()
        } else {
            closeFindBar()
        }
    }

    private func findNext() {
        guard let view = tab.bridge.view, !findQuery.isEmpty else {
            findTotal = 0
            return
        }
        _ = view.findNext(findQuery)
        let summary = view.searchMatchSummary(findQuery, limit: 999)
        findIndex = summary.index
        findTotal = summary.total
    }

    private func findPrevious() {
        guard let view = tab.bridge.view, !findQuery.isEmpty else { return }
        _ = view.findPrevious(findQuery)
        let summary = view.searchMatchSummary(findQuery, limit: 999)
        findIndex = summary.index
        findTotal = summary.total
    }

    private func closeFindBar() {
        showsFindBar = false
        tab.bridge.view?.clearSearch()
        // The search field owned the keyboard; give it back to the shell so the
        // user can keep typing without clicking the terminal.
        tab.bridge.view?.takeFocus()
    }

    private func handleDroppedFiles(_ urls: [URL]) {
        let directory = tab.lastRemoteDirectory ?? tab.remote.path
        app.uploadDropped(urls: urls, to: tab, destination: directory)
        var quoted: [String] = []
        for url in urls {
            quoted.append(shellQuote(POSIXPath.join(directory, url.lastPathComponent)))
        }
        if !quoted.isEmpty {
            tab.write(quoted.joined(separator: " ") + " ")
        }
    }

    private func shellQuote(_ path: String) -> String {
        if path.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-@%+:=,")).inverted) == nil {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @ViewBuilder
    private var connectionOverlay: some View {
        switch tab.connectionState {
        case .connecting(let stage):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(stage).font(.system(size: 12))
            }
            .padding(10)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(12)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(L("连接失败")).font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(4)
                HStack {
                    Button(L("重试")) { app.reconnect(tab) }
                    Button(L("编辑主机")) { app.editingHost = tab.host }
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: 420, alignment: .leading)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(16)
        case .disconnected(let reason):
            VStack(alignment: .leading, spacing: 8) {
                Text(L("连接已断开")).font(.system(size: 13, weight: .semibold))
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                Text(L("提示：重连后如需恢复会话，可在终端执行 tmux attach 或 screen -r"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                HStack {
                    Button(L("重新连接")) { app.reconnect(tab) }
                    Text(L("终端内容已保留，可滚动查看")).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                .controlSize(.small)
            }
            .padding(12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(16)
        case .idle:
            // A tab restored from the workspace snapshot has no session until
            // something dials it. Never leave that as an unexplained blank pane.
            VStack(alignment: .leading, spacing: 8) {
                Text(L("尚未连接")).font(.system(size: 13, weight: .semibold))
                Text(L("这个标签是上次退出时保存的，会话已经结束。"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                HStack {
                    Button(L("连接")) { app.connect(tab: tab) }
                    Button(L("编辑主机")) { app.editingHost = tab.host }
                }
                .controlSize(.small)
            }
            .padding(12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(16)
        case .connected:
            EmptyView()
        }
    }
}


/// Shared control for the session strip's buttons and menus.
private struct StripLabel: View {
    var systemName: String? = nil
    var title: String? = nil
    var badge: Int = 0
    var isEnabled: Bool = true
    var isActive: Bool = false
    var hovering: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemName {
                Image(systemName: systemName).font(.system(size: 11, weight: .medium))
            }
            if let title {
                Text(title).font(.system(size: 10.5, weight: .medium))
            }
            if badge > 0 {
                Text(String(badge))
                    .font(TechFont.mono(8, .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Theme.accent)
                    )
            }
        }
        .foregroundStyle(isEnabled
                         ? (hovering || isActive ? Theme.accent : Theme.secondary)
                         : Theme.secondary.opacity(0.35))
        .frame(minWidth: 14, minHeight: 25)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .fill(isActive ? Theme.accent.opacity(0.08) : (hovering && isEnabled ? Theme.rowHover : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .strokeBorder(isActive ? Theme.accent.opacity(0.24) : Color.clear,
                              lineWidth: 0.7)
        )
        .contentShape(Rectangle())
    }
}

struct StripButton: View {
    var systemName: String? = nil
    var title: String? = nil
    var help: String
    /// Short name + key chord for the hover hint. Controls that have a shortcut
    /// use the app's own bubble instead of the system tooltip.
    var tip: String? = nil
    var keys: [String] = []
    var isEnabled: Bool = true
    var isActive: Bool = false
    var badge: Int = 0
    var action: () -> Void

    @ViewState private var hovering = false

    var body: some View {
        let button = Button(action: action) {
            StripLabel(systemName: systemName, title: title, badge: badge, isEnabled: isEnabled, isActive: isActive, hovering: hovering)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(tip ?? help)
        .onHover { hovering = $0 }

        if let tip {
            button.shortcutTip(tip, keys: keys)
        } else {
            button.help(help)
        }
    }
}

struct StripMenu<Content: View>: View {
    var systemName: String? = nil
    var title: String? = nil
    var help: String
    var tip: String? = nil
    var keys: [String] = []
    @ViewBuilder var content: () -> Content

    @ViewState private var hovering = false

    var body: some View {
        let menu = Menu { content() } label: {
            StripLabel(systemName: systemName, title: title, hovering: hovering)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(tip ?? help)
        .onHover { hovering = $0 }

        if let tip {
            menu.shortcutTip(tip, keys: keys)
        } else {
            menu.help(help)
        }
    }
}
