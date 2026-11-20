import AppKit
import TaugeKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Board workspace

struct BoardWorkspaceView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            BoardHeader()
            Divider().opacity(0.6)
            content
        }
        .background(Theme.windowBackground)
    }

    @ViewBuilder
    private var content: some View {
        // The host list is always visible: it is the only place that shows which
        // machines live in the workspace, and it is where a host can be edited.
        HStack(spacing: 0) {
            BoardSessionList()
            Divider().opacity(0.6)
            if let board = app.currentBoard, board.isGrid, let tree = board.tree {
                BoardSplitView(node: tree, path: [])
            } else if let session = app.focusedBoardSession {
                BoardPaneView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                BoardEmptyView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Header

private struct BoardHeader: View {
    @EnvironmentObject private var app: AppState

    private var board: BoardDefinition? { app.currentBoard }

    var body: some View {
        HStack(spacing: 10) {
            boardMenu

            BoardLayoutToggle(isGrid: board?.isGrid ?? false) { grid in
                app.setBoardLayout(grid)
            }

            Divider().frame(height: 16)

            splitMenu
            addHostsMenu

            broadcastControl

            Spacer(minLength: 8)

            if let board {
                saveControl
                Text(L("%d 个窗格", board.panes.count))
                    .font(.system(size: 11))
                    .foregroundColor(Theme.secondary)
            }

            iconButton("bolt.horizontal.circle", help: L("连接全部窗格")) {
                app.connectAllBoardSessions()
            }
            iconButton("square.grid.2x2", help: L("自动网格排列")) {
                app.autoGridBoard()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Theme.panelBackground.opacity(0.55))
        // Hover hints hang under the header; keep them above the panes.
        .zIndex(1)
    }

    private var boardMenu: some View {
        Menu {
            Button(L("新建工作区…")) { app.promptCreateBoard() }
            if let board {
                Button(L("编辑工作区…")) {
                    app.editingBoard = board
                }
                Button(L("重命名工作区…")) {
                    if let name = Prompt.text(title: L("重命名工作区"), message: L("输入新的工作区名称。"), defaultValue: board.name) {
                        app.renameBoard(board.id, name: name)
                    }
                }
                Button(L("删除工作区…"), role: .destructive) {
                    guard app.boards.count > 1 else {
                        app.presentMessage(L("无法删除"), L("至少保留一个工作区。"))
                        return
                    }
                    if Prompt.confirm(title: L("删除「%@」？", board.name),
                                      message: L("工作区里的终端会断开，主机配置不受影响。"),
                                      destructiveTitle: L("删除")) {
                        app.deleteBoard(board.id)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.split.3x3")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: board?.colorHex) ?? Theme.secondary)
                Text(board?.name ?? L("工作区"))
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Theme.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var splitMenu: some View {
        Menu {
            let focusedID = app.currentBoard?.focusedPaneID ?? app.currentBoard?.panes.first?.id
            ForEach(app.hosts) { host in
                Menu(host.name) {
                    Button(L("右侧切分")) { split(host, axis: .horizontal, newFirst: false, focusedID) }
                    Button(L("左侧切分")) { split(host, axis: .horizontal, newFirst: true, focusedID) }
                    Divider()
                    Button(L("下方切分")) { split(host, axis: .vertical, newFirst: false, focusedID) }
                    Button(L("上方切分")) { split(host, axis: .vertical, newFirst: true, focusedID) }
                }
                .disabled(focusedID == nil)
            }
        } label: {
            Label(L("切分"), systemImage: "rectangle.split.2x1")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(app.currentBoard?.panes.isEmpty != false)
    }

    private func split(_ host: SSHHost,
                       axis: BoardSplitAxis,
                       newFirst: Bool,
                       _ focusedID: UUID?) {
        guard let paneID = focusedID else { return }
        app.splitBoardPane(paneID, axis: axis, hostID: host.id, newFirst: newFirst)
    }

    private var addHostsMenu: some View {
        Menu {
            BoardAddHostMenuItems()
            Divider()
            Button(L("新建工作区（选服务器）…")) { app.promptCreateBoard() }
        } label: {
            Label(L("添加主机"), systemImage: "plus.rectangle.on.rectangle")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Command broadcast lives in the header instead of a settings pane: it is a
    /// per-moment decision ("type this on all four boxes"), and the pill stays
    /// lit while it is on so a shared prompt can never be entered by accident.
    private var broadcastControl: some View {
        let on = app.settings.broadcastInput
        let peers = app.broadcastPeerCount
        return Button {
            app.toggleBroadcastingInput()
            // The click moved focus out of the terminal; give it back so the
            // next keystroke goes to the pane the user was working in.
            app.scheduleTerminalFocus(0.05)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .semibold))
                Text(on ? (peers > 0 ? L("广播中 · %d", peers) : L("广播中")) : L("广播"))
                    .font(.system(size: 11, weight: on ? .medium : .regular))
                    .monospacedDigit()
            }
            .foregroundColor(on ? Theme.accent : Theme.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(on ? Theme.accent.opacity(0.15) : Color.clear)
            )
            .overlay(
                Capsule().strokeBorder(on ? Theme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(app.boardSessions.isEmpty)
        .shortcutTip(on ? L("命令广播已开启 · 点按关闭") : L("命令广播 · 在一个窗格输入，其他窗格同步输入"),
                     keys: ["⌥⌘B"])
    }

    /// “未保存” doubles as the save button; ⌘S commits the same thing.
    private var saveControl: some View {
        Button {
            app.requestSaveCurrentBoard()
        } label: {
            HStack(spacing: 4) {
                if app.boardDirty {
                    Circle()
                        .fill(Theme.warning)
                        .frame(width: 6, height: 6)
                    Text(L("未保存"))
                        .font(.system(size: 11, weight: .medium))
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                    Text(L("已保存"))
                        .font(.system(size: 11))
                }
            }
            .foregroundColor(app.boardDirty ? Theme.warning : Theme.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(app.boardDirty ? Theme.warning.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!app.boardDirty)
        .shortcutTip(app.boardDirty ? L("保存工作区") : L("工作区已保存"), keys: app.boardDirty ? ["⌘S"] : [])
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundColor(Theme.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct BoardLayoutToggle: View {
    let isGrid: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 2) {
            segment("list.bullet.rectangle", active: !isGrid, help: L("单窗格")) { onChange(false) }
            segment("square.split.2x1", active: isGrid, help: L("分屏")) { onChange(true) }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.secondary.opacity(0.12))
        )
    }

    private func segment(_ symbol: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(active ? Theme.windowBackground : Theme.secondary)
                .frame(width: 26, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(active ? Theme.accent : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Add-to-workspace menu items grouped exactly like the sidebar: one submenu
/// per group (nested groups nest here too), so adding a machine is a tree walk
/// instead of one long alphabetical list.
private struct BoardAddHostMenuItems: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ForEach(app.sidebarTree) { node in
            groupMenu(node)
        }
        if !app.ungroupedHosts.isEmpty {
            Menu(L("未分组")) {
                ForEach(app.ungroupedHosts) { host in
                    Button(host.name) { app.addHostsToBoard([host.id]) }
                }
            }
        }
    }

    @ViewBuilder
    private func groupMenu(_ node: SidebarGroupNode) -> some View {
        Menu(node.group.name) {
            if !node.hosts.isEmpty {
                Button(L("添加全部 ") + String(node.hosts.count) + L(" 台")) {
                    app.addHostsToBoard(node.hosts.map(\.id))
                }
                Divider()
                ForEach(node.hosts) { host in
                    Button(host.name) { app.addHostsToBoard([host.id]) }
                }
                if !node.children.isEmpty { Divider() }
            }
            ForEach(node.children) { child in
                AnyView(groupMenu(child))
            }
        }
    }
}

// MARK: - Session list

private struct BoardSessionList: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(L("终端"))
                    .font(.system(size: 11, weight: .semibold))
                Text("\(app.boardSessions.count)")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.secondary.opacity(0.15)))
                    .foregroundColor(Theme.secondary)
                Spacer()
                Menu {
                    BoardAddHostMenuItems()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 18)
                .help(L("添加主机到工作区"))
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.separator.opacity(0.7)).frame(height: 0.5)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(app.boardSessions) { session in
                        BoardSessionRow(session: session)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
        }
        .frame(width: 208)
        .background(Theme.sidebarBackground)
        // A hairline instead of a deep fill: the list is a rail next to the
        // terminal, not a second window.
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.separator).frame(width: 1)
        }
    }
}

private struct BoardSessionRow: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var session: TerminalTab
    @ViewState private var hovering = false

    private var isFocused: Bool { app.currentBoard?.focusedPaneID == session.id }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.host.name)
                    .font(.system(size: 11, weight: isFocused ? .semibold : .regular))
                    .lineLimit(1)
                Text(session.host.displayAddress)
                    .font(.system(size: 9.5))
                    .foregroundColor(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovering {
                Button {
                    app.closeBoardPane(session.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Theme.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("关闭窗格"))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isFocused ? Theme.cardBackground : (hovering ? Theme.rowHover : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isFocused ? Theme.accent.opacity(0.40) : Color.clear, lineWidth: 1)
        )
        .shadow(color: isFocused ? Theme.shadow : Color.clear, radius: 2, y: 0.5)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .onDrag {
            NSItemProvider(object: session.id.uuidString as NSString)
        }
        .onTapGesture(count: 2) {
            app.focusBoardPane(session.id)
            app.connectBoardSession(session)
        }
        .onTapGesture {
            app.focusBoardPane(session.id)
            if session.connectionState == .idle { app.connectBoardSession(session) }
        }
        .contextMenu {
            Button(L("连接")) { app.connectBoardSession(session) }
            Button(L("编辑主机…")) { app.editingHost = app.host(id: session.host.id) }
            Button(session.showsSFTP ? L("隐藏文件面板") : L("显示文件面板")) {
                app.focusBoardPane(session.id)
                app.toggleSFTP(session)
                app.scheduleBoardPersist()
            }
            Divider()
            Button(L("关闭窗格")) { app.closeBoardPane(session.id) }
        }
    }

    private var statusColor: Color {
        switch session.connectionState {
        case .connected: return Theme.success
        case .connecting: return Theme.warning
        case .failed: return Theme.danger
        case .disconnected: return Theme.warning
        case .idle: return Theme.secondary.opacity(0.5)
        }
    }
}

// MARK: - Split tree

struct BoardSplitView: View {
    @EnvironmentObject private var app: AppState
    let node: BoardSplitNode
    let path: [Int]

    var body: some View {
        switch node {
        case .pane(let id):
            if let session = app.boardSession(id: id) {
                BoardPaneView(session: session)
            } else {
                Color.clear
            }
        case .split(let axis, let fraction, let first, let second):
            BoardSplitContainer(axis: axis,
                                fraction: fraction,
                                path: path,
                                first: first,
                                second: second)
        }
    }
}

private struct BoardSplitContainer: View {
    @EnvironmentObject private var app: AppState
    let axis: BoardSplitAxis
    let fraction: Double
    let path: [Int]
    let first: BoardSplitNode
    let second: BoardSplitNode

    @ViewState private var liveFraction: Double?
    @ViewState private var dragBase: Double?
    @ViewState private var isDragging = false
    @ViewState private var snapHint: Double?

    private var current: Double {
        let value = liveFraction ?? fraction
        return min(max(value, 0.04), 0.96)
    }

    var body: some View {
        GeometryReader { proxy in
            let total = axis == .horizontal ? proxy.size.width : proxy.size.height
            let usable = max(total - BoardSplitMetrics.gutter, 1)
            let firstLength = max(usable * current, 1)

            ZStack(alignment: .center) {
                if axis == .horizontal {
                    HStack(spacing: 0) {
                        BoardSplitView(node: first, path: path + [0])
                            .frame(width: firstLength)
                        handle(usable: usable)
                            .frame(width: BoardSplitMetrics.gutter)
                        BoardSplitView(node: second, path: path + [1])
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        BoardSplitView(node: first, path: path + [0])
                            .frame(height: firstLength)
                        handle(usable: usable)
                            .frame(height: BoardSplitMetrics.gutter)
                        BoardSplitView(node: second, path: path + [1])
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                if isDragging {
                    HStack(spacing: 4) {
                        if snapHint != nil {
                            Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right.fill")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        Text("\(Int((current * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .foregroundColor(snapHint == nil ? Theme.secondary : Theme.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(snapHint == nil ? Theme.secondary.opacity(0.25)
                                                                    : Theme.accent.opacity(0.55),
                                                    lineWidth: 0.5))
                    .shadow(color: Color.black.opacity(0.18), radius: 6, y: 2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.08), value: snapHint)
                }
            }
        }
    }

    private func handle(usable: CGFloat) -> some View {
        BoardSplitHandle(
            axis: axis,
            onBegin: {
                dragBase = current
                isDragging = true
            },
            onMove: { delta in
                let proposed = clamped(base: dragBase ?? current, delta: delta, usable: usable)
                // Magnetism: inside a narrow band the divider jumps onto the
                // guide while the pointer keeps moving, so the snap is felt
                // during the drag instead of only after the mouse is released.
                let magnetic = BoardSplitTree.snapped(proposed, tolerance: 0.018)
                liveFraction = magnetic
                snapHint = abs(magnetic - proposed) < 0.0001 ? nil : magnetic
            },
            onEnd: { delta in
                let proposed = clamped(base: dragBase ?? current, delta: delta, usable: usable)
                liveFraction = nil
                dragBase = nil
                isDragging = false
                snapHint = nil
                app.setSplitFraction(path: path,
                                     fraction: BoardSplitTree.snapped(proposed),
                                     animated: true)
            },
            onReset: {
                app.setSplitFraction(path: path, fraction: 0.5, animated: true)
            }
        )
    }

    private func clamped(base: Double, delta: CGFloat, usable: CGFloat) -> Double {
        let minimumShare = min(0.45, Double(BoardSplitMetrics.minimumPane) / Double(max(usable, 1)))
        let proposed = base + Double(delta) / Double(max(usable, 1))
        return min(max(proposed, minimumShare), 1 - minimumShare)
    }
}

// MARK: - Pane

private struct BoardPaneView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var session: TerminalTab

    @ViewState private var hovering = false
    @ViewState private var dropZone: BoardDropZone?

    private var isFocused: Bool { app.currentBoard?.focusedPaneID == session.id }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                header
                Divider().opacity(0.35)
                content
            }
            .background(Color(nsColor: TerminalPalette.background))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isFocused ? Theme.accent.opacity(0.70) : Theme.cardStroke,
                                  lineWidth: isFocused ? 1.4 : 1)
            )
            .shadow(color: Theme.shadow,
                    radius: isFocused ? 7 : 3,
                    y: isFocused ? 1.5 : 1)
            .overlay(dropPreview)
            .padding(3)
            .onDrop(of: [UTType.text],
                    delegate: BoardPaneDropDelegate(paneID: session.id,
                                                    size: proxy.size,
                                                    onZoneChange: { zone in
                                                        if dropZone != zone { dropZone = zone }
                                                    },
                                                    onDrop: { id, zone in
                                                        dropZone = nil
                                                        app.handleBoardDrop(id, onto: session.id, zone: zone)
                                                    }))
            .onAppear {
                // A restored board should be typeable right away.
                if isFocused { app.scheduleTerminalFocus(0.3) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 0) {
                Text(session.host.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(session.host.displayAddress)
                    .font(.system(size: 9))
                    .foregroundColor(Theme.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // A permanently visible reminder, not a hover-only affordance: while
            // broadcast is on this pane's keys reach every other pane.
            if app.settings.broadcastInput {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(session.connectionState.isConnected ? Theme.accent : Theme.secondary)
                    .help(L("命令广播已开启：此窗格的输入会同步到工作区其他已连接窗格"))
            }

            if hovering || session.showsSFTP || isFocused {
                paneButton(session.showsSFTP ? "folder.fill" : "folder",
                           active: session.showsSFTP,
                           help: session.showsSFTP ? L("隐藏文件面板") : L("显示文件面板")) {
                    app.toggleSFTP(session)
                    app.scheduleBoardPersist()
                }
                paneButton("xmark", help: L("关闭窗格")) {
                    app.closeBoardPane(session.id)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(headerBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.separator)
                .frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .onTapGesture(count: 2) {
            app.toggleBoardMaximize(session.id)
        }
        .onTapGesture {
            app.focusBoardPane(session.id)
        }
        .onDrag {
            NSItemProvider(object: session.id.uuidString as NSString)
        }
        .help(L("拖动标题栏可移动窗格，双击最大化"))
    }

    /// Opaque so the title bar never picks up a shell colour drawn under it.
    /// Unfocused panes use the shared header band; the focused one is a step
    /// brighter and keeps the accent border, so focus reads without a tint.
    private var headerBackground: Color {
        isFocused ? Theme.paneHeader : Theme.headerBackground
    }

    private func paneButton(_ symbol: String, active: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(active ? Theme.accent : Theme.secondary)
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(active ? Theme.accent.opacity(0.15) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var content: some View {
        TerminalSFTPStack(tab: session)
    }

    private var statusColor: Color {
        switch session.connectionState {
        case .connected: return Theme.success
        case .connecting: return Theme.warning
        case .failed: return Theme.danger
        case .disconnected: return Theme.warning
        case .idle: return Theme.secondary.opacity(0.5)
        }
    }

    @ViewBuilder
    private var dropPreview: some View {
        if let zone = dropZone {
            GeometryReader { proxy in
                let rect = dropRect(for: zone, in: proxy.size)
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.accent.opacity(0.12))
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.85),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    Text(zone.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }

    private func dropRect(for zone: BoardDropZone, in size: CGSize) -> CGRect {
        switch zone {
        case .center:
            return CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
        case .left:
            return CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .right:
            return CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top:
            return CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom:
            return CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
    }
}

// MARK: - Drop delegate

/// Zone-aware drop target. SwiftUI gives no location in the closure form of
/// onDrop, so a delegate is used; it only touches plain values and hops the
/// actual mutation back to the main actor.
private struct BoardPaneDropDelegate: DropDelegate {
    let paneID: UUID
    let size: CGSize
    let onZoneChange: (BoardDropZone?) -> Void
    let onDrop: (UUID, BoardDropZone) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.text])
    }

    func dropEntered(info: DropInfo) {
        onZoneChange(zone(at: info.location))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onZoneChange(zone(at: info.location))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        onZoneChange(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = zone(at: info.location)
        guard let provider = info.itemProviders(for: [UTType.text]).first else {
            onZoneChange(nil)
            return false
        }
        onZoneChange(nil)
        let onDrop = self.onDrop
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, let id = UUID(uuidString: string) else { return }
            Task { @MainActor in onDrop(id, target) }
        }
        return true
    }

    /// Middle band swaps panes; the outer band splits on that edge.
    private func zone(at point: CGPoint) -> BoardDropZone {
        guard size.width > 1, size.height > 1 else { return .center }
        let dx = point.x / size.width
        let dy = point.y / size.height
        let margin: CGFloat = 0.3
        if dx < margin { return .left }
        if dx > 1 - margin { return .right }
        if dy < margin { return .top }
        if dy > 1 - margin { return .bottom }
        return .center
    }
}

// MARK: - Empty state

private struct BoardEmptyView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.split.3x3")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(Theme.secondary.opacity(0.7))
            Text(L("这个工作区还没有终端"))
                .font(.system(size: 15, weight: .semibold))
            Text(L("从侧边栏拖一台主机到窗口里，或用下面的菜单添加。"))
                .font(.system(size: 11))
                .foregroundColor(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            HStack(spacing: 10) {
                Menu(L("添加主机")) {
                    ForEach(app.hosts) { host in
                        Button(host.name) { app.addHostsToBoard([host.id]) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(app.hosts.isEmpty)

            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.windowBackground)
    }
}
