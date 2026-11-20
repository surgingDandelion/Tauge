import Foundation
import TaugeKit

/// Checks for the payloads the SFTP panes publish when a drag starts.
///
/// A drag used to carry exactly one row; a multi-row selection now travels in the
/// same payload, so the new list form and the legacy single-path form both have to
/// stay readable — an older payload is what a drag started before an update (or by
/// another build) still looks like.
func runDragPayloadChecks() {
    run("drag.payload keeps a legacy single-path payload readable") {
        let json = """
        {"hostID":"7C2E0D0B-0000-0000-0000-000000000000","path":"/tmp/one.txt","paneID":"P1"}
        """
        let payload = try JSONDecoder().decode(RemoteDragPayload.self, from: Data(json.utf8))
        expectEqual(payload.allPaths, ["/tmp/one.txt"], "a legacy payload yields its single path")
        expectEqual(payload.hostID, "7C2E0D0B-0000-0000-0000-000000000000", "the host id survives")
        expectEqual(payload.paneID, "P1", "the pane id survives")
    }

    run("drag.payload carries every selected row in pane order") {
        let payload = RemoteDragPayload(hostID: nil,
                                        path: "/tmp/b.txt",
                                        paths: ["/tmp/a.txt", "/tmp/b.txt", "/tmp/c.txt"],
                                        paneID: "P1")
        let decoded = try JSONDecoder().decode(RemoteDragPayload.self,
                                               from: try JSONEncoder().encode(payload))
        expectEqual(decoded.allPaths, ["/tmp/a.txt", "/tmp/b.txt", "/tmp/c.txt"],
                    "the whole selection survives the round trip in pane order")
        expectEqual(decoded.paneID, "P1", "the pane id survives the round trip")
    }

    run("drag.payload drops blank and repeated paths") {
        let payload = RemoteDragPayload(path: "/b", paths: ["/a", "", "   ", "/a", "/b"])
        expectEqual(payload.allPaths, ["/a", "/b"], "blanks and repeats are dropped")
    }

    run("drag.payload appends the grabbed row when the list omits it") {
        let payload = RemoteDragPayload(path: "/grabbed", paths: ["/other"])
        expectEqual(payload.allPaths, ["/other", "/grabbed"],
                    "the grabbed row is transferred even if the list lost it")
    }

    run("drag.local payload carries the whole local selection") {
        let payload = LocalDragPayload(paths: ["/Users/me/a.txt", "/Users/me/a.txt", "  /Users/me/b.txt  "])
        expectEqual(payload.allPaths, ["/Users/me/a.txt", "/Users/me/b.txt"],
                    "blanks and repeats are dropped")
        let decoded = try JSONDecoder().decode(LocalDragPayload.self,
                                               from: try JSONEncoder().encode(payload))
        expectEqual(decoded.allPaths, payload.allPaths, "the local selection survives the round trip")
    }
}
