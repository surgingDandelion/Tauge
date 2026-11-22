import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TaugeKit

struct WorkspaceView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            // The strip's hover hints hang below its edge, so it has to paint
            // over the board header and panes that follow it.
            TabStripView()
                .zIndex(1)
            Divider()
            if app.isWorkspaceSelected {
                BoardWorkspaceView()
            } else if let tab = app.selectedTab {
                // The tab object owns showsSFTP/connectionState, so the tab content has to
                // observe it directly: AppState only publishes the tab list, and mutating a
                // tab in place would otherwise never re-render the workspace (the SFTP pane
                // simply would not appear when toggled).
                TabWorkspaceView(tab: tab)
            } else {
                StartPageView()
            }
        }
        .background(Theme.windowGradient)
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
    @ViewState private var dragBase: Double = 0

    init(tab: TerminalTab) {
        self.tab = tab
        _fraction = ViewState(wrappedValue: tab.sftpSplitFraction)
    }

    var body: some View {
        if tab.showsSFTP {
            GeometryReader { proxy in
                let usable = max(1, proxy.size.height - BoardSplitMetrics.gutter)
                let share = clamped(fraction, usable: usable)
                // The browser needs a floor: in a short board pane the split
                // fraction alone can leave ~110pt, and the panel's own header
                // row would be clipped away completely.
                let bottomFloor = min(150, usable * 0.55)
                let terminalHeight = min(usable * share, max(40, usable - bottomFloor))
                VStack(spacing: 0) {
                    TerminalPane(tab: tab)
                        .frame(height: terminalHeight)
                    BoardSplitHandle(
                        axis: .vertical,
                        onBegin: { dragBase = fraction },
                        onMove: { delta in
                            fraction = clamped(dragBase + Double(delta) / Double(usable), usable: usable)
                        },
                        onEnd: { _ in tab.sftpSplitFraction = fraction },
                        onReset: {
                            fraction = 0.5
                            tab.sftpSplitFraction = 0.5
                        }
                    )
                    .frame(height: BoardSplitMetrics.gutter)
                    SFTPBrowserView(tab: tab)
                        .frame(maxHeight: .infinity)
                }
            }
        } else {
            TerminalPane(tab: tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        HStack(spacing: 0) {
            // The start page lives at the left edge of the strip and never
            // scrolls away with the tabs.
            StartPageChipView()
                .padding(.leading, 6)
            Divider().frame(height: 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(app.tabs) { tab in
                        TabChipView(tab: tab)
                    }
                    ForEach(app.openBoards) { board in
                        BoardChipView(board: board)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            Divider().frame(height: 18)
            HStack(spacing: 2) {
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

                StripButton(systemName: "house", help: L("起始页：所有主机和工作区（⇧⌘H）"), tip: L("起始页"), keys: ["⇧⌘H"]) {
                    app.showStartPage()
                }

                StripMenu(systemName: "rectangle.grid.2x2", title: L("工作区"), help: L("工作区：一块窗口里放多个分屏终端，和普通连接一样是顶部标签（⇧⌘B 新建）"), tip: L("工作区"), keys: ["⇧⌘B"]) {
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

                if let tab = app.selectedTab, !app.isWorkspaceSelected, tab.kind == .terminal {
                    SftpToggleButton(tab: tab)
                }

                StripButton(systemName: "arrow.clockwise", help: L("重新连接"), tip: L("重新连接"), keys: ["⌘R"], isEnabled: app.selectedTab != nil) {
                    if app.isWorkspaceSelected {
                        app.connectAllBoardSessions()
                    } else if let tab = app.selectedTab {
                        app.reconnect(tab)
                    }
                }

                Rectangle().fill(Theme.separator.opacity(0.6)).frame(width: 1, height: 14).padding(.horizontal, 3)

                StripButton(systemName: "arrow.up.arrow.down", title: L("传输"), help: L("传输中心（⇧⌘J）"), tip: L("传输中心"), keys: ["⇧⌘J"], badge: app.activeTransferCount) {
                    app.showingTransferCenter = true
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 44)
        .background(Theme.headerBackground)
        .overlay(alignment: .top) {
            LinearGradient(colors: [Theme.insetHighlight.opacity(0.45), .clear],
                           startPoint: .leading,
                           endPoint: .trailing)
                .frame(height: 0.8)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator.opacity(0.55)).frame(height: 0.5)
        }
    }
}

private struct SftpToggleButton: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var tab: TerminalTab

    var body: some View {
        Button {
            app.toggleSFTP(tab)
        } label: {
            Image(systemName: tab.showsSFTP ? "folder.fill" : "folder")
                .font(.system(size: 12))
                .foregroundStyle(tab.showsSFTP ? Theme.accent : Theme.secondary)
        }
        .buttonStyle(.plain)
        .shortcutTip(tab.showsSFTP ? L("隐藏 SFTP 面板") : L("显示 SFTP 面板"), keys: ["⇧⌘O"])
    }
}

/// The permanent "start page" chip pinned to the left of the tab strip. It is
/// not a tab (nothing to close, it never scrolls) but it shares the chip look so
/// the strip still reads as one row of destinations.
struct StartPageChipView: View {
    @EnvironmentObject private var app: AppState
    @ViewState private var hovering = false

    private var isSelected: Bool { app.isStartPageSelected }

    var body: some View {
        HStack(spacing: 6) {
            TechAppLogo(size: 17)
            Text(L("起始页"))
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .tracking(0.1)
                .lineLimit(1)
        }
        .padding(.leading, 9)
        .padding(.trailing, 9)
        .padding(.vertical, 6)
        .background(chipBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.38) : Color.clear, lineWidth: 0.7)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isSelected ? Theme.accent.opacity(0.9) : Color.clear)
                .frame(height: 1.5)
                .padding(.horizontal, 7)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .shadow(color: isSelected ? Theme.shadow.opacity(0.8) : Color.clear, radius: 1.5, y: 0.5)
        .contentShape(Rectangle())
        .frame(minHeight: 32)
        .onTapGesture { app.showStartPage() }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .shortcutTip(L("起始页：所有主机和工作区"), keys: ["⇧⌘H", "⌘0"], align: .leading)
    }

    private var chipBackground: Color {
        if isSelected { return Theme.cardTop }
        return hovering ? Theme.secondary.opacity(0.09) : Color.clear
    }
}

struct TabChipView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var tab: TerminalTab
    @ViewState private var hovering = false
    @ViewState private var isDropTarget = false

    private var isSelected: Bool { app.selectedTabID == tab.id }

    var body: some View {
        HStack(spacing: 6) {
            if tab.kind == .sftp {
                Image(systemName: "folder")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(color)
            } else {
                TechStatusDot(color: color, size: 6)
            }
            // Derived straight from the host so the strip can never show a
            // cached or remote-supplied title instead of the user's own name.
            Text(TerminalTab.label(for: tab.host))
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .tracking(0.1)
                .lineLimit(1)
                .frame(maxWidth: 160)
            if hovering || isSelected {
                Button {
                    app.closeTab(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(Theme.secondary)
                        .frame(width: 14, height: 14)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(hovering ? Theme.secondary.opacity(0.14) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("关闭标签（⌘W）"))
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .background(chipBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(isDropTarget ? Theme.accent
                                           : (isSelected ? Theme.accent.opacity(0.38) : Color.clear),
                              lineWidth: isDropTarget ? 1.2 : 0.7)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(selectedUnderlineColor)
                .frame(height: 1.5)
                .padding(.horizontal, 7)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .shadow(color: isSelected ? Theme.shadow.opacity(0.8) : Color.clear, radius: 1.5, y: 0.5)
        .contentShape(Rectangle())
        .frame(minHeight: 32)
        .onTapGesture { app.selectTab(tab) }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .onDrag {
            NSItemProvider(object: tab.id.uuidString as NSString)
        }
        // Dropping one tab on another splits both terminals into a workspace;
        // the accent border is the whole affordance for that.
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

    private var chipBackground: Color {
        if isDropTarget { return Theme.accent.opacity(0.12) }
        if isSelected { return Theme.cardTop }
        return hovering ? Theme.secondary.opacity(0.09) : Color.clear
    }

    private var color: Color {
        if let custom = tab.host.colorHex.flatMap({ Color(hex: $0) }) {
            return custom
        }
        switch tab.connectionState {
        case .connected: return Theme.success
        case .connecting: return Theme.warning
        case .failed, .disconnected: return Theme.danger
        case .idle: return Theme.secondary.opacity(0.5)
        }
    }

    private var selectedUnderlineColor: Color {
        isSelected ? color.opacity(0.95) : Color.clear
    }
}

/// A workspace (multi-pane) tab. It sits in the same strip as single connections,
/// so both are ordinary tabs.
struct BoardChipView: View {
    @EnvironmentObject private var app: AppState
    let board: BoardDefinition
    @ViewState private var hovering = false
    @ViewState private var isDropTarget = false

    private var isSelected: Bool { app.currentBoard?.id == board.id && app.selectedBoardID == board.id }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(accentColor)
            Text(board.name)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .tracking(0.1)
                .lineLimit(1)
                .frame(maxWidth: 160)
            if hovering || isSelected {
                Button {
                    app.closeBoardTab(board.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(Theme.secondary)
                        .frame(width: 14, height: 14)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(hovering ? Theme.secondary.opacity(0.14) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("关闭工作区标签（终端会断开，工作区配置保留）"))
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .background(chipBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(isDropTarget ? Theme.accent
                                           : (isSelected ? accentColor.opacity(0.7) : Color.clear),
                              lineWidth: isDropTarget ? 1.2 : 0.7)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isSelected ? accentColor.opacity(0.95) : Color.clear)
                .frame(height: 1.5)
                .padding(.horizontal, 7)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .shadow(color: isSelected ? Theme.shadow.opacity(0.8) : Color.clear, radius: 1.5, y: 0.5)
        .contentShape(Rectangle())
        .frame(minHeight: 32)
        .onTapGesture { app.selectBoardTab(board.id) }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
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

    private var chipBackground: Color {
        if isDropTarget { return Theme.accent.opacity(0.12) }
        if isSelected { return accentColor.opacity(0.16) }
        return hovering ? Theme.secondary.opacity(0.09) : Color.clear
    }

    private var accentColor: Color {
        Color(hex: board.colorHex) ?? Theme.secondary
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


/// Shared 22pt control used by the tab strip, so the icon buttons and the two
/// menus line up instead of each having its own intrinsic size.
private struct StripLabel: View {
    var systemName: String? = nil
    var title: String? = nil
    var badge: Int = 0
    var isEnabled: Bool = true
    var hovering: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemName {
                Image(systemName: systemName).font(.system(size: 10, weight: .medium))
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
                         ? (hovering ? Theme.accent : Theme.secondary)
                         : Theme.secondary.opacity(0.35))
        .frame(height: 22)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .fill(hovering && isEnabled ? Theme.rowHover : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .strokeBorder(hovering && isEnabled ? Theme.accent.opacity(0.28) : Color.clear,
                              lineWidth: 0.7)
        )
        .contentShape(Rectangle())
    }
}

private struct StripButton: View {
    var systemName: String? = nil
    var title: String? = nil
    var help: String
    /// Short name + key chord for the hover hint. Controls that have a shortcut
    /// use the app's own bubble instead of the system tooltip.
    var tip: String? = nil
    var keys: [String] = []
    var isEnabled: Bool = true
    var badge: Int = 0
    var action: () -> Void

    @ViewState private var hovering = false

    var body: some View {
        let button = Button(action: action) {
            StripLabel(systemName: systemName, title: title, badge: badge, isEnabled: isEnabled, hovering: hovering)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering = $0 }

        if let tip {
            button.shortcutTip(tip, keys: keys)
        } else {
            button.help(help)
        }
    }
}

private struct StripMenu<Content: View>: View {
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
        .onHover { hovering = $0 }

        if let tip {
            menu.shortcutTip(tip, keys: keys)
        } else {
            menu.help(help)
        }
    }
}
