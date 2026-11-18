import AppKit
import Foundation
import ShellXKit

/// Asking for the name of a workspace that was assembled by dragging one tab
/// onto another. Such a workspace starts as a draft: it lives in the tab strip
/// but not in the catalog, and the first save is what names (and keeps) it.
struct BoardNamePrompt: Identifiable, Equatable {
    let boardID: UUID
    var name: String
    var id: UUID { boardID }
}

extension AppState {
    // MARK: Dropping a tab on the tab strip

    /// A tab was dropped on another tab: split the two terminals side by side in
    /// a new workspace. Holding ⌥ keeps the plain reorder instead.
    @discardableResult
    func handleTabDrop(providers: [NSItemProvider], onto tab: TerminalTab) -> Bool {
        guard let provider = providers.first else { return false }
        // Modifier state has to be read now: the provider loads asynchronously.
        let reorder = NSEvent.modifierFlags.contains(.option)
        provider.loadObject(ofClass: NSString.self) { [weak self] value, _ in
            guard let identifier = value as? String, let sourceID = UUID(uuidString: identifier) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !reorder, self.mergeTabsIntoSplit(draggedID: sourceID, onto: tab.id) { return }
                self.reorderTab(sourceID, onto: tab.id)
            }
        }
        return true
    }

    /// A tab was dropped on a workspace chip: it joins that workspace as a pane
    /// instead of creating a second one.
    @discardableResult
    func handleTabDrop(providers: [NSItemProvider], ontoBoard boardID: UUID) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { [weak self] value, _ in
            guard let identifier = value as? String, let sourceID = UUID(uuidString: identifier) else { return }
            Task { @MainActor [weak self] in
                _ = self?.addTabToBoard(tabID: sourceID, boardID: boardID)
            }
        }
        return true
    }

    // MARK: Merging

    /// Turns two live tabs into one workspace split side by side and switches to
    /// it. The tabs themselves become the panes, so their SSH sessions and
    /// scrollback carry over instead of dialing again.
    @discardableResult
    func mergeTabsIntoSplit(draggedID: UUID, onto targetID: UUID) -> Bool {
        guard draggedID != targetID,
              let source = tabs.first(where: { $0.id == draggedID }),
              let target = tabs.first(where: { $0.id == targetID }),
              source.kind == .terminal, target.kind == .terminal else { return false }
        let left = BoardPaneDefinition(id: target.id, hostID: target.host.id, showsSFTP: target.showsSFTP)
        let right = BoardPaneDefinition(id: source.id, hostID: source.host.id, showsSFTP: source.showsSFTP)
        let board = BoardDefinition.sideBySide(
            left,
            right,
            name: BoardNaming.split(first: TerminalTab.label(for: target.host),
                                    second: TerminalTab.label(for: source.host))
        )
        boards.append(board)
        draftBoardIDs.insert(board.id)
        boardSessionCache[board.id] = [left.id: target, right.id: source]
        // The two chips are panes now: drop them from the strip without closing
        // their connections.
        tabs.removeAll { $0.id == draggedID || $0.id == targetID }
        selectedTabID = nil
        // Opens the new tab, activates the workspace from the session cache and
        // records both the open list and the selection.
        openBoardTab(board.id, connect: false)
        // The layout is a draft, so the header has to offer ⌘S: that is the
        // gesture that asks for the workspace name.
        boardDirty = true
        persistWorkspace()
        scheduleTerminalFocus(0.12)
        return true
    }

    /// Adds an existing tab to an existing workspace as a new pane, split off
    /// the focused one. The pane keeps the tab's live session.
    @discardableResult
    func addTabToBoard(tabID: UUID, boardID: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              tab.kind == .terminal,
              boards.contains(where: { $0.id == boardID }) else { return false }
        if currentBoard?.id != boardID || boardSessions.isEmpty {
            openBoardTab(boardID, connect: false)
        }
        guard var current = currentBoard, current.id == boardID else { return false }
        let pane = BoardPaneDefinition(id: tab.id, hostID: tab.host.id, showsSFTP: tab.showsSFTP)
        current.panes.append(pane)
        if current.isGrid {
            let anchor = current.focusedPaneID ?? current.panes.first?.id
            if let anchor {
                current.tree = BoardSplitTree.splitting(current.tree ?? .pane(anchor),
                                                        leaf: anchor,
                                                        axis: .horizontal,
                                                        newPane: pane.id)
            }
        }
        current.focusedPaneID = pane.id
        currentBoard = current
        boardSessions.append(tab)
        boardSessionCache[boardID, default: [:]][pane.id] = tab
        tabs.removeAll { $0.id == tab.id }
        if selectedTabID == tab.id { selectedTabID = nil }
        markBoardDirty()
        persistWorkspace()
        scheduleTerminalFocus(0.12)
        return true
    }

    /// Old drop behaviour, still available with ⌥ held.
    func reorderTab(_ sourceID: UUID, onto targetID: UUID) {
        guard let from = tabs.firstIndex(where: { $0.id == sourceID }),
              let to = tabs.firstIndex(where: { $0.id == targetID }),
              from != to else { return }
        moveTab(from: from, to: to)
    }

    // MARK: Saving a draft

    /// ⌘S and the header button. A draft workspace asks for its name first;
    /// everything else saves straight away.
    func requestSaveCurrentBoard() {
        guard let board = currentBoard else { return }
        guard draftBoardIDs.contains(board.id) else {
            saveCurrentBoard()
            return
        }
        boardNamePrompt = BoardNamePrompt(boardID: board.id, name: board.name)
    }

    func cancelBoardNamePrompt() {
        boardNamePrompt = nil
    }

    /// Commits the name and finally writes the workspace to the catalog.
    func commitBoardNamePrompt() {
        guard let prompt = boardNamePrompt else { return }
        let trimmed = prompt.name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        boardNamePrompt = nil
        draftBoardIDs.remove(prompt.boardID)
        if let index = boards.firstIndex(where: { $0.id == prompt.boardID }) {
            boards[index].name = trimmed
        }
        if currentBoard?.id == prompt.boardID {
            currentBoard?.name = trimmed
            saveCurrentBoard()
        } else if let board = boards.first(where: { $0.id == prompt.boardID }) {
            try? store.save(board: board)
        }
    }
}
