import Foundation
import ShellXKit

// MARK: - Command broadcast

/// Command broadcast: whatever is typed in one workspace pane is replayed into
/// every other pane that is currently connected.
///
/// The switch is `AppSettings.broadcastInput` (off by default, persisted), so
/// there is one source of truth and no chance of a stale copy. Nothing here
/// touches the transport directly: a broadcast is an ordinary `write` to each
/// peer's terminal session, exactly as if the user had typed there.
extension AppState {
    var isBroadcastingInput: Bool { settings.broadcastInput }

    /// The panes that would receive a keystroke typed in `origin`.
    func broadcastRecipients(excluding origin: TerminalTab) -> [TerminalTab] {
        let panes = boardSessions.map {
            CommandBroadcast.Pane(id: $0.id, isConnected: $0.connectionState.isConnected)
        }
        return CommandBroadcast.recipients(origin: origin.id, panes: panes)
            .compactMap { boardSession(id: $0) }
    }

    /// Panes a keystroke would reach right now, for the toolbar pill. The pane
    /// the user is typing in is not counted: it already has the characters.
    var broadcastPeerCount: Int {
        let connected = boardSessions.filter { $0.connectionState.isConnected }.count
        return max(0, connected - 1)
    }

    /// Every terminal pane funnels its keyboard/paste/drop input through here:
    /// the origin always receives the bytes, and the workspace echoes them to
    /// the other live panes only while broadcast is on and a workspace is the
    /// visible surface (a single tab has no peers, so it never broadcasts).
    func sendInput(_ data: Data, from tab: TerminalTab) {
        tab.write(data)
        guard isBroadcastingInput, isWorkspaceSelected, !data.isEmpty else { return }
        for peer in broadcastRecipients(excluding: tab) {
            peer.write(data)
        }
    }

    func setBroadcastingInput(_ enabled: Bool) {
        guard settings.broadcastInput != enabled else { return }
        var next = settings
        next.broadcastInput = enabled
        updateSettings(next)
    }

    func toggleBroadcastingInput() {
        setBroadcastingInput(!settings.broadcastInput)
    }
}
