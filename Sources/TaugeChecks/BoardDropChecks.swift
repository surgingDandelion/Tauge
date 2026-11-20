import Foundation
import TaugeKit

/// Covers the workspace that dragging one tab onto another produces: the layout
/// it starts with and the name it is born with. The drop gesture itself is UI,
/// but everything it decides is these two pure functions.
func runBoardDropChecks() {
    let leftHost = UUID(), rightHost = UUID()
    let leftPane = BoardPaneDefinition(hostID: leftHost, showsSFTP: true)
    let rightPane = BoardPaneDefinition(hostID: rightHost)

    run("dropping a tab on another splits the two terminals side by side") {
        let board = BoardDefinition.sideBySide(leftPane, rightPane, name: "A + B")
        expectEqual(board.panes.map(\.id), [leftPane.id, rightPane.id], "both panes, in drop order")
        expectEqual(board.layout, "grid", "a split workspace needs the grid layout")
        expectEqual(board.isGrid, true, "isGrid follows the layout string")
        expectEqual(board.focusedPaneID, rightPane.id, "the dragged terminal takes focus")
        expectEqual(board.tree.map(BoardSplitTree.leaves), [leftPane.id, rightPane.id], "tree leaves match the panes")
        guard case .split(let axis, let fraction, _, _)? = board.tree else {
            expect(false, "the tree should be a split")
            return
        }
        expectEqual(axis, .horizontal, "the panes sit left and right")
        expect(fraction == 0.5, "they get equal width")
        expectEqual(board.hostID(forPane: rightPane.id), rightHost, "each pane keeps its own host")
        expectEqual(board.pane(id: leftPane.id)?.showsSFTP, true, "an open SFTP browser carries over")
        expectEqual(board.id == leftPane.id || board.id == rightPane.id, false, "the workspace is its own object")
    }

    run("a split workspace is saved and restored with both panes") {
        let board = BoardDefinition.sideBySide(leftPane, rightPane, name: "pair")
        let data = try JSONEncoder().encode(board)
        let back = try JSONDecoder().decode(BoardDefinition.self, from: data)
        expectEqual(back, board, "round-trips through JSON")
        expectEqual(back.tree.map(BoardSplitTree.leaves), [leftPane.id, rightPane.id], "layout survives")
    }

    run("split workspace names are derived from the two hosts") {
        expectEqual(BoardNaming.split(first: "alpha", second: "beta"), "alpha + beta", "different hosts")
        expectEqual(BoardNaming.split(first: "alpha", second: "alpha"), "alpha ×2", "the same host twice")
        expectEqual(BoardNaming.split(first: " alpha ", second: " beta "), "alpha + beta", "whitespace trimmed")
        expectEqual(BoardNaming.split(first: "", second: "beta"), "? + beta", "a nameless host is a placeholder")
        expectEqual(BoardNaming.split(first: "  ", second: "  "), L("分屏工作区"), "two nameless hosts")
        let long = BoardNaming.split(first: String(repeating: "x", count: 80), second: "y")
        expectEqual(long.count, 60, "names are capped")
        expect(long.hasSuffix("y") == false, "the cap truncates instead of overflowing the chip")
    }
}
