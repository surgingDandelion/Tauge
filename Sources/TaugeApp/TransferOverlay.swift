import SwiftUI
import TaugeKit

/// Floating progress HUD for active transfers.
///
/// The SFTP pane has its own activity strip, but that strip is only visible
/// when the pane is open. Transfers started from a drag, the terminal drop or a
/// second pane should still be obvious, so this overlay lives above the whole
/// workspace and shows the first three transfers with progress, speed and ETA.
struct TransferHUD: View {
    @EnvironmentObject private var app: AppState

    private var active: [TransferProgress] {
        app.transfers.filter { !$0.state.isTerminal }
    }

    var body: some View {
        Group {
            if active.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(active.count == 1 ? L("传输中") : L("传输中 · ") + String(active.count))
                        Spacer()
                        Button {
                            app.showingTransferCenter = true
                        } label: {
                            Text(L("详情"))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    }
                    .font(.system(size: 11, weight: .semibold))

                    ForEach(Array(active.prefix(3))) { progress in
                        row(progress)
                    }
                    if active.count > 3 {
                        Text(L("另有 ") + String(active.count - 3) + L(" 个传输…"))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .padding(10)
                .frame(width: 330, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Theme.secondary.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                .padding(14)
            }
        }
        .allowsHitTesting(true)
    }

    private func row(_ progress: TransferProgress) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: progress.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                    .foregroundStyle(progress.state == .failed ? Theme.danger : Theme.accent)
                Text(displayName(progress))
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if progress.state == .failed {
                    Text(L("失败"))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.danger)
                } else {
                    Text(String(Int(progress.fraction * 100)) + "%")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                }
                Button {
                    app.cancelTransfer(progress)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help(L("取消传输"))
            }
            ProgressView(value: min(max(progress.fraction, 0), 1))
                .controlSize(.small)
            HStack(spacing: 8) {
                Text(FileAttributeFormatter.size(progress.bytesCompleted) + " / " + FileAttributeFormatter.size(progress.bytesTotal))
                Text(FileAttributeFormatter.speed(bytesPerSecond: progress.bytesPerSecond))
                if let remaining = progress.remainingTime {
                    Text(L("剩余 ") + FileAttributeFormatter.duration(remaining))
                }
                Spacer()
                if progress.state == .paused {
                    Button(L("继续")) { app.resumeTransfer(progress) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                } else if progress.state == .failed {
                    Button(L("重试")) { app.retryTransfer(progress) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(Theme.secondary)
        }
    }

    private func displayName(_ progress: TransferProgress) -> String {
        if let file = progress.currentFile, !file.isEmpty {
            return (file as NSString).lastPathComponent
        }
        return (progress.sourcePath as NSString).lastPathComponent
    }
}
