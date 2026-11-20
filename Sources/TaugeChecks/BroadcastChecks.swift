import Foundation
import TaugeKit

/// Covers command broadcast: which panes receive the echoed bytes, and the
/// persisted switch that turns the behaviour on (off by default).
func runBroadcastChecks() {
    let a = UUID()
    let b = UUID()
    let c = UUID()

    run("broadcast reaches every other connected pane") {
        let panes = [
            CommandBroadcast.Pane(id: a, isConnected: true),
            CommandBroadcast.Pane(id: b, isConnected: true),
            CommandBroadcast.Pane(id: c, isConnected: true),
        ]
        expectEqual(CommandBroadcast.recipients(origin: a, panes: panes), [b, c], "peers receive the input in display order")
        expectEqual(CommandBroadcast.recipientCount(origin: a, panes: panes), 2, "origin is not counted")
    }

    run("broadcast never echoes to the typing pane") {
        let panes = [CommandBroadcast.Pane(id: a, isConnected: true)]
        expectEqual(CommandBroadcast.recipients(origin: a, panes: panes), [], "a lone pane has no peers")
        expectEqual(CommandBroadcast.recipientCount(origin: a, panes: panes), 0, "no peers to count")
    }

    run("broadcast skips disconnected panes") {
        let panes = [
            CommandBroadcast.Pane(id: a, isConnected: true),
            CommandBroadcast.Pane(id: b, isConnected: false),
            CommandBroadcast.Pane(id: c, isConnected: true),
        ]
        expectEqual(CommandBroadcast.recipients(origin: a, panes: panes), [c], "a dead pane would drop the bytes")
    }

    run("broadcast count needs an origin") {
        let panes = [CommandBroadcast.Pane(id: a, isConnected: true), CommandBroadcast.Pane(id: b, isConnected: true)]
        expectEqual(CommandBroadcast.recipientCount(origin: nil, panes: panes), 0, "no origin, no broadcast")
    }

    run("broadcast defaults to off and survives a round trip") {
        let defaults = AppSettings()
        expectEqual(defaults.broadcastInput, false, "broadcast is opt-in")

        let legacy = Data("{}".utf8)
        let decodedLegacy = try JSONDecoder().decode(AppSettings.self, from: legacy)
        expectEqual(decodedLegacy.broadcastInput, false, "an older settings blob leaves broadcast off")

        var enabled = AppSettings()
        enabled.broadcastInput = true
        let encoded = try JSONEncoder().encode(enabled)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        expectEqual(decoded.broadcastInput, true, "an enabled broadcast is remembered")
    }
}
