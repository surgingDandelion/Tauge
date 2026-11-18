import SwiftUI
import ShellXKit

struct StatusBarView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        HStack(spacing: 12) {
            Button {
                app.toggleSidebar()
            } label: {
                Image(systemName: app.settings.sidebarVisible ? "sidebar.left" : "sidebar.leading")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.secondary)
                    .frame(width: 16, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .shortcutTip(app.settings.sidebarVisible ? "隐藏侧边栏" : "显示侧边栏", keys: ["⌃⌘S"], below: false)

            if app.isWorkspaceSelected {
                // A workspace is not tied to one tab, so showing the selected tab's route here
                // would be misleading; summarise the workspace instead.
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.grid.2x2").font(.system(size: 10))
                    Text(boardSummary)
                        .font(.system(size: 11))
                }
                .foregroundStyle(Theme.secondary)
            } else if let tab = app.selectedTab {
                // Same reason as the workspace: the tab is its own ObservableObject, so the
                // status text needs a view that subscribes to it or it never refreshes.
                TabStatusItems(tab: tab)
            } else {
                Text("就绪")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            if app.catalogReadOnly {
                Button {
                    app.presentCatalogReadOnlyNotice()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("数据库只读")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
                }
                .buttonStyle(.plain)
                .help("当前无法写入数据库位置：" + app.catalogPath)
            }
            if app.activeTransferCount > 0 {
                Button {
                    app.showingTransferCenter = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(activeTransferLabel)
                            .font(.system(size: 11).monospacedDigit())
                    }
                }
                .buttonStyle(.plain)
            }
            Button {
                app.showingCommandPalette = true
            } label: {
                Text("⌘K 命令面板")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Theme.headerBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.separator.opacity(0.5)).frame(height: 0.5)
        }
    }

    /// "3 个传输 · 4.2 MB/s" so throughput is visible without opening a panel.
    private var activeTransferLabel: String {
        let active = app.transfers.filter { !$0.state.isTerminal }
        let label = String(app.activeTransferCount) + " 个传输"
        let speed = active.reduce(0.0) { $0 + $1.bytesPerSecond }
        guard speed > 0 else { return label }
        return label + " · " + FileAttributeFormatter.speed(bytesPerSecond: speed)
    }

    private var boardSummary: String {
        let name = app.currentBoard?.name ?? "工作区"
        let layout = (app.currentBoard?.isGrid == true) ? "宫格" : "列表"
        let connected = app.boardSessions.filter { $0.connectionState.isConnected }.count
        let broadcast = app.settings.broadcastInput ? " · 广播" : ""
        return "工作区“" + name + "” · " + String(app.boardSessions.count) + " 个窗格 · "
            + String(connected) + " 已连接 · " + layout + broadcast
    }
}

struct TabStatusItems: View {
    @ObservedObject var tab: TerminalTab

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(stateColor(tab.connectionState))
                .frame(width: 7, height: 7)
            Text(tab.connectionState.label)
                .font(.system(size: 11))
            if !tab.routeSummary.isEmpty {
                Text(tab.routeSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            // The route line already covers the path through jump hosts; when a
            // tab has only that one line, printing statusDetail again just
            // duplicated "local → 10.103.136.65" twice.
            if !tab.statusDetail.isEmpty, tab.statusDetail != tab.routeSummary {
                Text(tab.statusDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            if tab.kind == .sftp {
                // SFTP-only tab: encoding and $TERM mean nothing here, the
                // panel count is what tells the user how many servers are open.
                Text("SFTP · " + String(tab.allRemotes.count) + " 个面板")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            } else if tab.connectionState.isConnected {
                Text(tab.encoding.displayName + " · " + tab.terminalType)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
        }
    }

    private func stateColor(_ state: TabConnectionState) -> Color {
        switch state {
        case .idle: return .gray
        case .connecting: return .orange
        case .connected: return .green
        case .disconnected, .failed: return .red
        }
    }

}
