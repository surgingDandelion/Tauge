import Foundation
import TaugeKit

/// Checks for the click maths behind multi-row selection in the SFTP panes.
func runFileSelectionChecks() {
    let order = ["/a", "/b", "/c", "/d", "/e"]

    run("fileSelection plain click replaces the selection") {
        let outcome = FileSelection.outcome(clicked: "/c", order: order, selection: ["/a", "/b"],
                                            anchor: "/a", mode: .replace)
        expectEqual(outcome.selection, ["/c"], "only the clicked row stays selected")
        expectEqual(outcome.anchor, "/c", "the clicked row becomes the anchor")
    }

    run("fileSelection command click toggles one row") {
        let added = FileSelection.outcome(clicked: "/d", order: order, selection: ["/a"], anchor: nil,
                                          mode: .toggle)
        expectEqual(added.selection, ["/a", "/d"], "a new row is added to the selection")
        expectEqual(added.anchor, "/d", "the toggled row becomes the anchor")

        let removed = FileSelection.outcome(clicked: "/a", order: order, selection: ["/a", "/d"], anchor: "/d",
                                            mode: .toggle)
        expectEqual(removed.selection, ["/d"], "an already selected row is removed")
    }

    run("fileSelection shift click selects the whole range") {
        let outcome = FileSelection.outcome(clicked: "/d", order: order, selection: ["/b"], anchor: "/b",
                                            mode: .extend)
        expectEqual(outcome.selection, ["/b", "/c", "/d"], "the range between anchor and click is selected")
        expectEqual(outcome.anchor, "/b", "the anchor survives so the next shift click grows the same range")
    }

    run("fileSelection shift click extends upwards too") {
        let outcome = FileSelection.outcome(clicked: "/b", order: order, selection: ["/a"], anchor: "/d",
                                            mode: .extend)
        expectEqual(outcome.selection, ["/b", "/c", "/d"], "dragging the other way selects the same rows")
    }

    run("fileSelection shift click without an anchor behaves like a plain click") {
        let outcome = FileSelection.outcome(clicked: "/c", order: order, selection: ["/a"], anchor: nil,
                                            mode: .extend)
        expectEqual(outcome.selection, ["/c"], "no anchor means a single row")
        expectEqual(outcome.anchor, "/c", "the click seeds the anchor")

        let stale = FileSelection.outcome(clicked: "/c", order: order, selection: ["/a"], anchor: "/gone",
                                          mode: .extend)
        expectEqual(stale.selection, ["/c"], "an anchor row that left the list is ignored")
    }

    run("fileSelection command shift click adds the range to the selection") {
        let outcome = FileSelection.outcome(clicked: "/e", order: order, selection: ["/a"], anchor: "/c",
                                            mode: .extendAdding)
        expectEqual(outcome.selection, ["/a", "/c", "/d", "/e"], "the previous rows stay selected")
        expectEqual(outcome.anchor, "/c", "the anchor survives")
    }

    run("fileSelection modifiers turn into the expected mode") {
        expectEqual(FileSelection.Mode(command: false, shift: false), .replace, "plain click replaces")
        expectEqual(FileSelection.Mode(command: true, shift: false), .toggle, "command click toggles")
        expectEqual(FileSelection.Mode(command: false, shift: true), .extend, "shift click extends")
        expectEqual(FileSelection.Mode(command: true, shift: true), .extendAdding, "command shift adds")
    }
}
