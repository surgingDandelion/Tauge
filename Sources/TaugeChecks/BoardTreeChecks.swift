import Foundation
import TaugeKit

/// Covers the pure split-tree maths behind the board workspace and the board
/// persistence layer. The SwiftUI layout itself is exercised by hand; the tree
/// operations and the stored JSON are what actually decide whether a layout
/// survives a relaunch.
func runBoardTreeChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("tauge-tree-checks-" + UUID().uuidString)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    run("board grid builds the expected shapes") {
        expectEqual(BoardSplitTree.grid(for: []), nil, "no panes, no tree")
        expectEqual(BoardSplitTree.grid(for: [a]), .pane(a), "one pane is a leaf")
        let two = BoardSplitTree.grid(for: [a, b])
        guard case .split(let axis, let fraction, let first, let second)? = two else {
            expect(false, "two panes should split")
            return
        }
        expectEqual(axis, .horizontal, "two panes sit side by side")
        expect(fraction == 0.5, "two panes are even")
        expectEqual(BoardSplitTree.leaves(first), [a], "first child")
        expectEqual(BoardSplitTree.leaves(second), [b], "second child")

        guard let four = BoardSplitTree.grid(for: [a, b, c, d]) else {
            expect(false, "four panes should build a grid")
            return
        }
        expectEqual(BoardSplitTree.leaves(four), [a, b, c, d], "grid keeps pane order")
        guard case .split(let rootAxis, _, let top, let bottom) = four else {
            expect(false, "grid root should be a split")
            return
        }
        expectEqual(rootAxis, .vertical, "rows are stacked vertically")
        expectEqual(BoardSplitTree.leaves(top), [a, b], "top row holds the first two panes")
        expectEqual(BoardSplitTree.leaves(bottom), [c, d], "bottom row holds the last two panes")

        let five = BoardSplitTree.grid(for: [a, b, c, d, e])
        expectEqual(BoardSplitTree.leaves(five!), [a, b, c, d, e], "3x2 grid keeps every pane once")
    }

    run("splitting a pane keeps the rest of the layout") {
        let base = BoardSplitTree.grid(for: [a, b])!
        let split = BoardSplitTree.splitting(base, leaf: a, axis: .vertical, newPane: c)
        expectEqual(BoardSplitTree.leaves(split), [a, c, b], "new pane follows the split leaf")
        guard case .split(let axis, _, let first, _) = split, case .split(let innerAxis, _, _, _) = first else {
            expect(false, "split replaces the leaf with a split")
            return
        }
        expectEqual(innerAxis, .vertical, "requested axis is used")
        expectEqual(axis, .horizontal, "outer layout is untouched")
    }

    run("splitting before a pane puts the new one first") {
        let base = BoardSplitTree.grid(for: [a, b])!
        let after = BoardSplitTree.splitting(base, leaf: b, axis: .horizontal, newPane: c, newFirst: true)
        expectEqual(BoardSplitTree.leaves(after), [a, c, b], "new pane lands before the target")
        let plain = BoardSplitTree.splitting(base, leaf: b, axis: .horizontal, newPane: c)
        expectEqual(BoardSplitTree.leaves(plain), [a, b, c], "the default still lands after it")
    }

    run("moving a pane onto an edge re-parents it and keeps every pane") {
        let base = BoardSplitTree.grid(for: [a, b, c])!
        let left = BoardSplitTree.moving(base, source: c, onto: a, axis: .horizontal, newFirst: true)
        expectEqual(BoardSplitTree.leaves(left), [c, a, b], "source moves to the left of the target")
        let right = BoardSplitTree.moving(base, source: a, onto: c, axis: .horizontal, newFirst: false)
        expectEqual(BoardSplitTree.leaves(right), [b, c, a], "source moves to the right of the target")
        let bottom = BoardSplitTree.moving(base, source: a, onto: b, axis: .vertical, newFirst: false)
        expectEqual(BoardSplitTree.leaves(bottom), [b, a, c], "vertical move keeps the tree valid")
        expectEqual(BoardSplitTree.leaves(BoardSplitTree.moving(base, source: a, onto: a, axis: .horizontal, newFirst: true)),
                    [a, b, c],
                    "moving a pane onto itself is a no-op")
        for target in [a, b, c] {
            for source in [a, b, c] where source != target {
                for axis in [BoardSplitAxis.horizontal, .vertical] {
                    let moved = BoardSplitTree.moving(base, source: source, onto: target, axis: axis, newFirst: true)
                    expectEqual(Set(BoardSplitTree.leaves(moved)), Set([a, b, c]), "every move keeps all panes")
                }
            }
        }
    }

    run("removing a pane collapses its parent") {
        let base = BoardSplitTree.grid(for: [a, b, c, d])!
        let three = BoardSplitTree.removing(base, leaf: a)
        expectEqual(BoardSplitTree.leaves(three!), [b, c, d], "removed leaf disappears")
        let two = BoardSplitTree.removing(three!, leaf: b)
        expectEqual(BoardSplitTree.leaves(two!), [c, d], "collapse continues")
        let one = BoardSplitTree.removing(two!, leaf: c)
        expectEqual(one, .pane(d), "last split collapses into the surviving pane")
        expectEqual(BoardSplitTree.removing(one!, leaf: d), nil, "removing the last pane leaves nothing")
        // Removing an unknown id must be a no-op.
        expectEqual(BoardSplitTree.removing(base, leaf: UUID()), base, "unknown leaf is ignored")
    }

    run("swapping panes keeps the layout and swaps positions") {
        let base = BoardSplitTree.grid(for: [a, b, c, d])!
        let swapped = BoardSplitTree.swapping(base, a, d)
        expectEqual(BoardSplitTree.leaves(swapped), [d, b, c, a], "positions swap")
        expectEqual(BoardSplitTree.swapping(base, a, a), base, "swapping with itself is a no-op")
    }

    run("divider fractions address nested splits") {
        let base = BoardSplitTree.grid(for: [a, b, c, d])!
        let root = BoardSplitTree.settingFraction(base, path: [], fraction: 0.7)
        guard case .split(_, let rootFraction, _, _) = root else {
            expect(false, "root should stay a split")
            return
        }
        expect(abs(rootFraction - 0.7) < 0.0001, "root fraction updated")
        let nested = BoardSplitTree.settingFraction(base, path: [1], fraction: 0.3)
        guard case .split(_, _, _, let bottom) = nested, case .split(_, let nestedFraction, _, _) = bottom else {
            expect(false, "second child should stay a split")
            return
        }
        expect(abs(nestedFraction - 0.3) < 0.0001, "nested fraction updated")
        let clamped = BoardSplitTree.settingFraction(base, path: [], fraction: 0.01)
        guard case .split(_, let clampedFraction, _, _) = clamped else { return }
        expect(clampedFraction >= 0.12, "fractions are clamped so panes stay usable")
    }

    run("divider snapping uses round fractions") {
        expect(abs(BoardSplitTree.snapped(0.47) - 0.5) < 0.0001, "snaps to the middle")
        expect(abs(BoardSplitTree.snapped(0.66) - 2.0 / 3.0) < 0.0001, "snaps to two thirds")
        expect(abs(BoardSplitTree.snapped(0.26) - 0.25) < 0.0001, "snaps to a quarter")
        expect(abs(BoardSplitTree.snapped(0.1) - 0.12) < 0.0001, "clamps below the minimum")
        expect(abs(BoardSplitTree.snapped(0.8) - 0.8) < 0.0001, "leaves non-matching values alone")
    }

    run("pruning drops panes that no longer exist") {
        let base = BoardSplitTree.grid(for: [a, b, c, d])!
        let pruned = BoardSplitTree.pruning(base, keeping: [a, c])
        expectEqual(BoardSplitTree.leaves(pruned!), [a, c], "only known panes remain")
        expectEqual(BoardSplitTree.pruning(base, keeping: []), nil, "nothing kept, no tree")
    }

    run("board definitions round-trip through JSON and SQLite") {
        let tree = BoardSplitTree.splitting(BoardSplitTree.grid(for: [a, b])!, leaf: a, axis: .vertical, newPane: c)
        // Both panes point at the same host on purpose: pane identity, not the
        // host, must decide which directory comes back.
        let sharedHostID = UUID()
        let board = BoardDefinition(name: "生产环境",
                                    panes: [BoardPaneDefinition(id: a, hostID: sharedHostID, showsSFTP: true,
                                                                 terminalDirectory: "/srv/api",
                                                                 lastRemoteDirectory: "/var/log/nginx"),
                                            BoardPaneDefinition(id: b, hostID: sharedHostID,
                                                                 terminalDirectory: "/srv/worker",
                                                                 lastRemoteDirectory: "/remote/worker"),
                                            BoardPaneDefinition(id: c, hostID: UUID())],
                                    layout: "grid",
                                    tree: tree,
                                    focusedPaneID: c)
        let data = try JSONEncoder().encode(board)
        let decoded = try JSONDecoder().decode(BoardDefinition.self, from: data)
        expectEqual(decoded, board, "tree and panes survive JSON")
        expect(decoded.isGrid, "layout flag survives")

        let database = try SQLiteDatabase(path: root.appendingPathComponent("boards.sqlite").path)
        defer { database.close() }
        let store = try HostStore(database: database)
        try store.save(board: board)
        expectEqual(try store.boards().count, 1, "board is stored")
        expectEqual(try store.board(id: board.id), board, "board reads back identically")
        try store.deleteBoard(id: board.id)
        expectEqual(try store.boards().count, 0, "board is deleted")

        expectEqual(decoded.panes[0].showsSFTP, true, "an open SFTP browser is remembered")
        expectEqual(decoded.panes[1].showsSFTP, false, "a closed SFTP browser is remembered too")
        expectEqual(decoded.panes[0].terminalDirectory, "/srv/api", "first pane keeps its terminal directory")
        expectEqual(decoded.panes[1].terminalDirectory, "/srv/worker", "same-host second pane keeps its own terminal directory")
        expectEqual(decoded.panes[0].lastRemoteDirectory, "/var/log/nginx", "first pane keeps its SFTP directory")
        expectEqual(decoded.panes[1].lastRemoteDirectory, "/remote/worker", "same-host second pane keeps its own SFTP directory")

        let legacy = #"{"id":"\#(UUID().uuidString)","name":"旧看板","panes":[{"id":"\#(a.uuidString)","hostID":"\#(UUID().uuidString)"}],"layout":"list"}"#
        let legacyBoard = try JSONDecoder().decode(BoardDefinition.self, from: Data(legacy.utf8))
        expectEqual(legacyBoard.panes.count, 1, "boards saved before pane SFTP still decode")
        expectEqual(legacyBoard.panes[0].showsSFTP, false, "missing flag defaults to closed")
        expectEqual(legacyBoard.panes[0].terminalDirectory, nil, "legacy panes have no terminal directory")
        expectEqual(legacyBoard.panes[0].lastRemoteDirectory, nil, "legacy panes have no SFTP directory")
    }

    run("divider drag measures in window coordinates") {
        var tracker = BoardSplitDragTracker()
        expectEqual(tracker.isTracking, false, "nothing tracked before a drag starts")
        expectEqual(tracker.delta(to: CGPoint(x: 10, y: 10), axis: .horizontal), nil, "no delta without a start")

        tracker.begin(at: CGPoint(x: 400, y: 300))
        expectEqual(tracker.delta(to: CGPoint(x: 460, y: 300), axis: .horizontal), 60, "horizontal drag follows x")
        expectEqual(tracker.delta(to: CGPoint(x: 460, y: 300), axis: .vertical), 0, "horizontal drag ignores y")

        tracker.begin(at: CGPoint(x: 400, y: 300))
        expectEqual(tracker.delta(to: CGPoint(x: 400, y: 340), axis: .vertical), 40, "vertical drag follows y")
        expectEqual(tracker.delta(to: CGPoint(x: 340, y: 340), axis: .vertical), 40, "vertical drag ignores x")

        tracker.end()
        expectEqual(tracker.isTracking, false, "a finished drag forgets its origin")
    }
}
