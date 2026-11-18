import Foundation
import ShellXKit
import SwiftUI


/// Where a dragged pane lands inside another pane.
enum BoardDropZone: Equatable {
    case left
    case right
    case top
    case bottom
    case center

    var label: String {
        switch self {
        case .left: return L("左侧分屏")
        case .right: return L("右侧分屏")
        case .top: return L("上方分屏")
        case .bottom: return L("下方分屏")
        case .center: return L("交换窗格")
        }
    }
}

// MARK: - Board state

extension AppState {
    /// Boards reuse `TerminalTab` for their panes, so a board pane gets exactly the
    /// same terminal, find bar, SFTP browser, drag-and-drop and transfer plumbing
    /// as a tab. The only difference is that board panes live in
    /// `boardSessions` instead of the tab strip.
    func makeBoardTab(pane: BoardPaneDefinition, host: SSHHost) -> TerminalTab {
        let tab = TerminalTab(id: pane.id,
                              host: host,
                              localFiles: environment.localFiles,
                              startRemoteDirectory: lastSFTPPath(for: host.id) ?? host.startDirectory,
                              localStartDirectory: settings.lastLocalDirectory,
                              showsSFTP: pane.showsSFTP)
        tab.local.onDirectoryChange = { [weak self] path in self?.recordLocalDirectory(path) }
        configureSFTPHistory(for: tab.remote)
        tab.local.showHidden = settings.showHiddenFiles
        tab.remote.showHidden = settings.showHiddenFiles
        return tab
    }

    // MARK: Restore and persistence

    func restoreBoards() {
        var loaded = (try? store.boards()) ?? []
        if loaded.isEmpty {
            let fresh = BoardDefinition(name: L("工作区 1"))
            try? store.save(board: fresh)
            loaded = [fresh]
        }
        boards = loaded

        // Which workspaces were open as tabs last time. On the first run there is no
        // record at all: keep the workspace the user last worked in open, so upgrading
        // does not silently hide the panes they had. Once "board.open" exists an empty
        // array is a deliberate state (the user closed the tabs) and is respected.
        let known = Set(loaded.map { $0.id })
        let savedOpen = savedOpenBoardIDs()
        var ids = (savedOpen ?? []).filter { known.contains($0) }
        let savedID = ((try? store.setting(key: "board.current")) ?? nil).flatMap(UUID.init(uuidString:))
        if savedOpen == nil {
            ids = [savedID ?? loaded[0].id]
        }
        if ids.isEmpty, settings.navigationMode == "board" {
            ids = [savedID ?? loaded[0].id]
        }
        openBoardIDs = ids

        // Last focused view: a workspace tab or a plain terminal tab. Restoring it
        // means a restart lands where the user left off.
        let lastSelectedBoard = ((try? store.setting(key: "board.selected")) ?? nil)
            .flatMap(UUID.init(uuidString:))
            .flatMap { ids.contains($0) ? $0 : nil }

        guard let activeID = savedID.flatMap({ ids.contains($0) ? $0 : nil }) ?? ids.first,
              let board = loaded.first(where: { $0.id == activeID }) else { return }
        activateBoard(board, connecting: false)
        // Focus the workspace tab when the user was last looking at one, when there is
        // nothing else to show, or when the legacy "board mode" flag says so.
        if let lastSelectedBoard {
            openBoardTab(lastSelectedBoard, connect: false)
        } else if settings.navigationMode == "board" {
            selectedBoardID = board.id
            selectedTabID = nil
        }
        persistOpenBoardIDs()
        persistSelectedBoard()
    }

    /// Remembers whether a workspace tab or a plain terminal tab had focus.
    func persistSelectedBoard() {
        try? store.setSetting(key: "board.selected", value: selectedBoardID?.uuidString ?? "")
    }

    private func savedOpenBoardIDs() -> [UUID]? {
        guard let raw = (try? store.setting(key: "board.open")) ?? nil,
              let data = raw.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return values.compactMap(UUID.init(uuidString:))
    }

    private func persistOpenBoardIDs() {
        let values = openBoardIDs.map { $0.uuidString }
        let data = (try? JSONEncoder().encode(values)) ?? Data("[]".utf8)
        try? store.setSetting(key: "board.open", value: String(decoding: data, as: UTF8.self))
    }

    /// Opens (or focuses) a workspace in the tab strip and dials its panes.
    func openBoardTab(_ id: UUID, connect: Bool = true) {
        guard let board = boards.first(where: { $0.id == id }) else { return }
        if !openBoardIDs.contains(id) {
            openBoardIDs.append(id)
            persistOpenBoardIDs()
        }
        if currentBoard?.id != id || boardSessions.isEmpty {
            activateBoard(board, connecting: false)
        }
        selectedBoardID = id
        selectedTabID = nil
        if connect { connectAllBoardSessions() }
        persistOpenBoardIDs()
        persistSelectedBoard()
    }

    /// Switches the tab strip selection to a workspace already open as a tab.
    ///
    /// The panes are dialed here too: a workspace restored from the catalog has
    /// its layout but no sessions, and switching to it used to leave every pane
    /// blank. Panes that are already connected or connecting are skipped.
    func selectBoardTab(_ id: UUID) {
        openBoardTab(id, connect: true)
    }

    func closeBoardTab(_ id: UUID) {
        guard let index = openBoardIDs.firstIndex(of: id) else { return }
        if currentBoard?.id == id { saveCurrentBoardIfDirty() }
        // A workspace that was never saved is not in the catalog either, so
        // closing its tab drops it instead of leaving a placeholder behind.
        if draftBoardIDs.remove(id) != nil {
            boards.removeAll { $0.id == id }
        }
        openBoardIDs.remove(at: index)
        // Tear the panes down: a closed workspace tab should not keep SSH sessions.
        if let sessions = boardSessionCache[id] {
            for session in sessions.values { session.close() }
            boardSessionCache[id] = nil
        }
        if selectedBoardID == id {
            selectedBoardID = nil
            if currentBoard?.id == id {
                boardSessions = []
                currentBoard = nil
            }
            selectedTabID = tabs.last?.id
            if let nextBoardID = openBoardIDs.first,
               let next = boards.first(where: { $0.id == nextBoardID }) {
                activateBoard(next, connecting: false)
            }
        }
        persistOpenBoardIDs()
        persistWorkspace()
    }

    func activateBoard(_ board: BoardDefinition, connecting: Bool) {
        // Switching workspaces commits whatever the previous one had pending.
        saveCurrentBoardIfDirty()
        stashCurrentSessions()
        var sanitized = board
        let knownHosts = Set(hosts.map { $0.id })
        sanitized.panes = board.panes.filter { knownHosts.contains($0.hostID) }
        let paneSet = Set(sanitized.panes.map { $0.id })
        sanitized.tree = sanitized.tree.flatMap { BoardSplitTree.pruning($0, keeping: paneSet) }
        if let focused = sanitized.focusedPaneID, !paneSet.contains(focused) {
            sanitized.focusedPaneID = nil
        }
        if sanitized.focusedPaneID == nil { sanitized.focusedPaneID = sanitized.panes.first?.id }
        currentBoard = sanitized
        boardDirty = false

        let cache = boardSessionCache[sanitized.id] ?? [:]
        var sessions: [TerminalTab] = []
        for pane in sanitized.panes {
            if let existing = cache[pane.id] {
                existing.host = host(id: pane.hostID) ?? existing.host
                existing.title = TerminalTab.label(for: existing.host)
                sessions.append(existing)
            } else if let host = host(id: pane.hostID) {
                sessions.append(makeBoardTab(pane: pane, host: host))
            }
        }
        boardSessions = sessions
        boardSessionCache[sanitized.id] = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        if connecting { connectAllBoardSessions() }
        try? store.setSetting(key: "board.current", value: sanitized.id.uuidString)
    }

    private func stashCurrentSessions() {
        guard let id = currentBoard?.id else { return }
        boardSessionCache[id] = Dictionary(uniqueKeysWithValues: boardSessions.map { ($0.id, $0) })
    }

    /// Writes the current board to the catalog (debounced: dragging a divider
    /// fires a lot of changes). Layout-only edits save themselves; once the pane
    /// list is dirty this waits for ⌘S, otherwise the "未保存" marker would
    /// disappear while the user was still editing.
    func scheduleBoardPersist() {
        boardSaveTask?.cancel()
        guard !boardDirty, var board = currentBoard else { return }
        for index in board.panes.indices {
            if let tab = boardSessions.first(where: { $0.id == board.panes[index].id }) {
                board.panes[index].showsSFTP = tab.showsSFTP
            }
        }
        let store = self.store
        boardSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            try? store.save(board: board)
        }
    }

    /// A pane was added or removed: the header switches to 未保存 until ⌘S.
    func markBoardDirty() {
        guard currentBoard != nil else { return }
        boardDirty = true
    }

    /// Commits the workspace exactly as it is on screen (⌘S or the header button).
    func saveCurrentBoard() {
        boardSaveTask?.cancel()
        boardSaveTask = nil
        guard var board = currentBoard else {
            boardDirty = false
            return
        }
        // Drafts are not written until the user names them: an automatic save
        // (switching away, quitting) must not put the placeholder in the catalog.
        guard !draftBoardIDs.contains(board.id) else { return }
        for index in board.panes.indices {
            if let tab = boardSessions.first(where: { $0.id == board.panes[index].id }) {
                board.panes[index].showsSFTP = tab.showsSFTP
            }
        }
        do {
            try store.save(board: board)
            currentBoard = board
            if let index = boards.firstIndex(where: { $0.id == board.id }) {
                boards[index] = board
            }
            boardDirty = false
        } catch {
            present(error, title: L("保存工作区失败"))
        }
    }

    /// Never lose unsaved panes when switching away or quitting.
    func saveCurrentBoardIfDirty() {
        guard boardDirty else { return }
        saveCurrentBoard()
    }

    // MARK: Board CRUD

    func createBoard(name: String,
                     hostIDs: [UUID] = [],
                     isGrid: Bool = false,
                     connect: Bool = false) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var board = BoardDefinition(name: trimmed.isEmpty ? L("新工作区") : trimmed)
        if isGrid { board.layout = "grid" }
        try? store.save(board: board)
        boards.append(board)
        openBoardIDs.append(board.id)
        selectedBoardID = board.id
        selectedTabID = nil
        activateBoard(board, connecting: false)
        persistOpenBoardIDs()
        persistSelectedBoard()
        if !hostIDs.isEmpty {
            addHostsToBoard(hostIDs, connect: connect)
            // Picking the servers in the creation sheet *is* the edit, so commit
            // it right away; only later pane changes need the 未保存 marker.
            saveCurrentBoard()
        }
    }

    /// Sheet entry point: creates a workspace with the servers picked in the
    /// "new workspace" form (name + layout + server list).
    func createBoardFromSheet(name: String, hostIDs: [UUID], isGrid: Bool, connect: Bool) {
        createBoard(name: name, hostIDs: hostIDs, isGrid: isGrid, connect: connect)
        showingBoardCreate = false
    }

    /// Menu entry point: opens the new-workspace form so a whole group of
    /// servers can be picked at once instead of one by one.
    func promptCreateBoard() {
        showingBoardCreate = true
    }

    func selectBoard(_ id: UUID) {
        openBoardTab(id)
    }

    func renameBoard(_ id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let index = boards.firstIndex(where: { $0.id == id }) {
            boards[index].name = trimmed
            try? store.save(board: boards[index])
        }
        if currentBoard?.id == id {
            currentBoard?.name = trimmed
            scheduleBoardPersist()
        }
    }

    func deleteBoard(_ id: UUID) {
        guard boards.count > 1 else { return }
        for session in (boardSessionCache[id] ?? [:]).values { session.close() }
        boardSessionCache[id] = nil
        try? store.deleteBoard(id: id)
        boards.removeAll { $0.id == id }
        if openBoardIDs.contains(id) {
            openBoardIDs.removeAll { $0 == id }
            persistOpenBoardIDs()
        }
        if currentBoard?.id == id {
            boardSessions = []
            currentBoard = nil
            selectedBoardID = nil
            if let nextID = openBoardIDs.first, let next = boards.first(where: { $0.id == nextID }) {
                activateBoard(next, connecting: false)
            }
            selectedTabID = tabs.last?.id
        }
    }

    /// Opens a host as a pane of a workspace tab, creating one if needed.
    func openInBoard(hostID: UUID) {
        if selectedBoardID == nil, let current = currentBoard, openBoardIDs.contains(current.id) {
            openBoardTab(current.id, connect: false)
        } else if selectedBoardID == nil {
            if let first = boards.first {
                openBoardTab(first.id, connect: false)
            } else {
                createBoard(name: L("工作区 1"))
            }
        }
        addHostsToBoard([hostID])
    }

    // MARK: Pane lifecycle

    func boardSession(id: UUID) -> TerminalTab? {
        boardSessions.first { $0.id == id }
    }

    var focusedBoardSession: TerminalTab? {
        guard let board = currentBoard else { return nil }
        let id = board.focusedPaneID ?? board.panes.first?.id
        return id.flatMap { boardSession(id: $0) }
    }

    func focusBoardPane(_ id: UUID) {
        guard currentBoard?.focusedPaneID != id else { return }
        currentBoard?.focusedPaneID = id
        scheduleBoardPersist()
        // Clicking anywhere in another pane must hand it the keyboard, the same
        // way tab selection does.
        scheduleTerminalFocus(0.02)
    }

    /// Adds hosts to the current board. In grid mode the first new pane splits
    /// the focused pane so the layout stays intentional.
    func addHostsToBoard(_ hostIDs: [UUID], connect: Bool = true) {
        let newHosts = hostIDs.compactMap { host(id: $0) }
        guard !newHosts.isEmpty else { return }
        var added: [UUID] = []
        for host in newHosts {
            let pane = BoardPaneDefinition(hostID: host.id)
            currentBoard?.panes.append(pane)
            let session = makeBoardTab(pane: pane, host: host)
            boardSessions.append(session)
            if let boardID = currentBoard?.id {
                boardSessionCache[boardID, default: [:]][pane.id] = session
            }
            added.append(pane.id)
        }
        if let first = added.first { currentBoard?.focusedPaneID = first }
        if currentBoard?.isGrid == true {
            let panes = currentBoard?.panes.map { $0.id } ?? []
            if currentBoard?.tree == nil {
                currentBoard?.tree = BoardSplitTree.grid(for: panes)
            } else if added.count == 1, let paneID = added.first,
                      let anchor = boardSessions.first(where: { $0.id != paneID })?.id {
                currentBoard?.tree = BoardSplitTree.splitting(currentBoard?.tree ?? .pane(anchor),
                                                              leaf: anchor,
                                                              axis: .vertical,
                                                              newPane: paneID)
            } else {
                currentBoard?.tree = BoardSplitTree.grid(for: panes)
            }
        }
        markBoardDirty()
        if connect {
            for id in added { if let session = boardSession(id: id) { connectBoardSession(session) } }
        }
    }

    func closeBoardPane(_ paneID: UUID) {
        guard let board = currentBoard else { return }
        if let session = boardSession(id: paneID) { session.close() }
        boardSessions.removeAll { $0.id == paneID }
        let boardID = board.id
        boardSessionCache[boardID]?[paneID] = nil
        currentBoard?.panes.removeAll { $0.id == paneID }
        currentBoard?.tree = board.tree.flatMap { BoardSplitTree.removing($0, leaf: paneID) }
        if currentBoard?.tree == nil, currentBoard?.isGrid == true {
            currentBoard?.layout = "list"
        }
        if currentBoard?.focusedPaneID == paneID {
            currentBoard?.focusedPaneID = currentBoard?.panes.first?.id
        }
        markBoardDirty()
    }

    func setBoardLayout(_ grid: Bool) {
        guard currentBoard != nil else { return }
        currentBoard?.layout = grid ? "grid" : "list"
        if grid, currentBoard?.tree == nil {
            currentBoard?.tree = BoardSplitTree.grid(for: currentBoard?.panes.map { $0.id } ?? [])
        }
        scheduleBoardPersist()
    }

    func autoGridBoard() {
        guard currentBoard != nil else { return }
        currentBoard?.tree = BoardSplitTree.grid(for: currentBoard?.panes.map { $0.id } ?? [])
        currentBoard?.layout = "grid"
        scheduleBoardPersist()
    }

    /// Splits a pane, placing a session to `hostID` next to it.
    func splitBoardPane(_ paneID: UUID,
                        axis: BoardSplitAxis,
                        hostID: UUID,
                        newFirst: Bool = false) {
        guard let board = currentBoard, board.panes.contains(where: { $0.id == paneID }),
              let host = host(id: hostID) else { return }
        let pane = BoardPaneDefinition(hostID: host.id)
        currentBoard?.panes.append(pane)
        let session = makeBoardTab(pane: pane, host: host)
        boardSessions.append(session)
        let boardID = board.id
        boardSessionCache[boardID, default: [:]][pane.id] = session
        let existing: BoardSplitNode = currentBoard?.tree
            ?? BoardSplitTree.grid(for: board.panes.map { $0.id })
            ?? .pane(paneID)
        currentBoard?.tree = BoardSplitTree.splitting(existing,
                                                      leaf: paneID,
                                                      axis: axis,
                                                      newPane: pane.id,
                                                      newFirst: newFirst)
        currentBoard?.layout = "grid"
        currentBoard?.focusedPaneID = pane.id
        markBoardDirty()
        connectBoardSession(session)
    }

    /// Dropped a host from the sidebar (or the session list) onto a pane edge.
    func dropHost(_ hostID: UUID, onto target: UUID, zone: BoardDropZone) {
        guard let host = host(id: hostID),
              let board = currentBoard,
              board.panes.contains(where: { $0.id == target }) else { return }
        switch zone {
        case .center, .right:
            splitBoardPane(target, axis: .horizontal, hostID: host.id, newFirst: false)
        case .left:
            splitBoardPane(target, axis: .horizontal, hostID: host.id, newFirst: true)
        case .bottom:
            splitBoardPane(target, axis: .vertical, hostID: host.id, newFirst: false)
        case .top:
            splitBoardPane(target, axis: .vertical, hostID: host.id, newFirst: true)
        }
    }

    /// Routes a dropped item to the right operation: an existing pane moves,
    /// a host opens a new pane on that edge.
    func handleBoardDrop(_ droppedID: UUID, onto target: UUID, zone: BoardDropZone) {
        if boardSessions.contains(where: { $0.id == droppedID }) {
            moveBoardPane(droppedID, onto: target, zone: zone)
        } else {
            dropHost(droppedID, onto: target, zone: zone)
        }
    }

    func setSplitFraction(path: [Int], fraction: Double, animated: Bool = false, persist: Bool = true) {
        guard let tree = currentBoard?.tree else { return }
        let updated = BoardSplitTree.settingFraction(tree, path: path, fraction: fraction)
        if animated {
            withAnimation(.easeOut(duration: 0.14)) { currentBoard?.tree = updated }
        } else {
            currentBoard?.tree = updated
        }
        if persist { scheduleBoardPersist() }
    }

    /// Dropping a pane onto a neighbour: the middle swaps the two, the edges
    /// splice the dragged pane in on that side.
    func moveBoardPane(_ source: UUID, onto target: UUID, zone: BoardDropZone) {
        guard source != target,
              let board = currentBoard,
              var tree = board.tree,
              board.panes.contains(where: { $0.id == source }),
              board.panes.contains(where: { $0.id == target }) else { return }
        switch zone {
        case .center:
            tree = BoardSplitTree.swapping(tree, source, target)
        case .left:
            tree = BoardSplitTree.moving(tree, source: source, onto: target, axis: .horizontal, newFirst: true)
        case .right:
            tree = BoardSplitTree.moving(tree, source: source, onto: target, axis: .horizontal, newFirst: false)
        case .top:
            tree = BoardSplitTree.moving(tree, source: source, onto: target, axis: .vertical, newFirst: true)
        case .bottom:
            tree = BoardSplitTree.moving(tree, source: source, onto: target, axis: .vertical, newFirst: false)
        }
        currentBoard?.tree = tree
        currentBoard?.layout = "grid"
        currentBoard?.focusedPaneID = source
        scheduleBoardPersist()
    }

    /// Double-clicking a pane header zooms it: grid -> that pane alone -> grid.
    func toggleBoardMaximize(_ paneID: UUID) {
        guard let board = currentBoard else { return }
        if board.isGrid {
            currentBoard?.layout = "list"
            currentBoard?.focusedPaneID = paneID
        } else {
            currentBoard?.layout = "grid"
            if board.tree == nil || BoardSplitTree.leaves(board.tree ?? .pane(paneID)) != board.paneIDs {
                currentBoard?.tree = BoardSplitTree.grid(for: board.paneIDs)
            }
        }
        scheduleBoardPersist()
    }

    func swapBoardPanes(_ first: UUID, _ second: UUID) {
        guard let tree = currentBoard?.tree, first != second else { return }
        currentBoard?.tree = BoardSplitTree.swapping(tree, first, second)
        scheduleBoardPersist()
    }

    // MARK: Connections

    func connectAllBoardSessions() {
        for session in boardSessions where !session.connectionState.isBusy && !session.connectionState.isConnected {
            connectBoardSession(session)
        }
    }

    func connectBoardSession(_ session: TerminalTab) {
        guard !session.connectionState.isBusy else { return }
        session.isClosing = false
        connect(tab: session)
    }
}
