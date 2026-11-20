import SwiftUI
import TaugeKit

struct TransferCenterView: View {
    @EnvironmentObject private var app: AppState
    @ViewState private var filter = TransferFilter.all

    enum TransferFilter: String, CaseIterable, Identifiable {
        case all, active, completed, failed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return L("全部")
            case .active: return L("进行中")
            case .completed: return L("已完成")
            case .failed: return L("失败")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(L("传输中心")).font(.system(size: 14, weight: .semibold))
                Picker("", selection: $filter) {
                    ForEach(TransferFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                Spacer()
                Button(L("重试全部失败")) { app.retryAllFailedTransfers() }
                    .disabled(!filtered.contains { $0.state == .failed })
                Button(L("清除已完成")) { app.clearFinishedTransfers() }
                    .disabled(!app.transfers.contains { $0.state == .completed || $0.state == .cancelled })
                Button(L("关闭")) { app.showingTransferCenter = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .frame(height: 46)

            Divider()

            HStack {
                Text(L("冲突策略")).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Picker("", selection: $app.transferConflictPolicy) {
                    Text(L("每次询问")).tag(ConflictPolicy?.none)
                    ForEach(ConflictPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(Optional(policy))
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                Text(L("对本窗口内新发起的传输生效"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Divider()

            if filtered.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.secondary)
                    Text(L("暂无传输任务")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { progress in
                            TransferRowView(progress: progress)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 720, height: 480)
    }

    private var filtered: [TransferProgress] {
        let sorted = app.transfers.sorted { $0.updatedAt > $1.updatedAt }
        switch filter {
        case .all: return sorted
        case .active: return sorted.filter { !$0.state.isTerminal }
        case .completed: return sorted.filter { $0.state == .completed }
        case .failed: return sorted.filter { $0.state == .failed }
        }
    }
}

struct TransferRowView: View {
    @EnvironmentObject private var app: AppState
    let progress: TransferProgress

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: progress.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .font(.system(size: 16))
                .foregroundStyle(color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(URL(fileURLWithPath: progress.sourcePath).lastPathComponent)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(progress.direction == .upload ? L("上传") : L("下载"))
                        .font(.system(size: 9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Theme.accent.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Spacer()
                    Text(app.hostName(forTransfer: progress))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                }
                Text(progress.sourcePath + " → " + progress.destinationPath)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if progress.state == .running || progress.state == .paused || progress.state == .queued {
                    ProgressView(value: max(0, min(1, progress.fraction)))
                        .progressViewStyle(.linear)
                    HStack(spacing: 10) {
                        Text(FileAttributeFormatter.size(progress.bytesCompleted) + " / " + FileAttributeFormatter.size(progress.bytesTotal))
                        if progress.bytesPerSecond > 0 {
                            Text(FileAttributeFormatter.speed(bytesPerSecond: progress.bytesPerSecond) + "/s")
                        }
                        if let remaining = progress.remainingTime {
                            Text(L("剩余 ") + FileAttributeFormatter.duration(remaining))
                        }
                        if progress.attempt > 1 {
                            Text(L("第 %d 次尝试", progress.attempt))
                                .foregroundStyle(Theme.warning)
                        }
                        Spacer()
                        Text(progress.state.displayName)
                    }
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                } else {
                    HStack(spacing: 8) {
                        Text(progress.state.displayName)
                            .foregroundStyle(color)
                        if let error = progress.errorMessage {
                            Text(error).lineLimit(1).foregroundStyle(Theme.danger)
                        }
                        Spacer()
                    }
                    .font(.system(size: 10))
                }
            }

            HStack(spacing: 6) {
                switch progress.state {
                case .running:
                    Button(L("暂停")) { app.pauseTransfer(progress) }
                case .paused:
                    Button(L("继续")) { app.resumeTransfer(progress) }
                case .failed:
                    Button(L("重试")) { app.retryTransfer(progress) }
                case .queued:
                    Button(L("取消")) { app.cancelTransfer(progress) }
                case .completed, .cancelled:
                    Button(L("移除")) { app.removeTransfer(progress) }
                }
                if progress.state != .completed && progress.state != .cancelled {
                    Button(L("取消")) { app.cancelTransfer(progress) }
                }
            }
            .font(.system(size: 10))
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var color: Color {
        switch progress.state {
        case .completed: return Theme.success
        case .failed: return Theme.danger
        case .paused: return Theme.warning
        case .cancelled: return Theme.secondary
        case .queued: return Theme.secondary
        case .running: return Theme.accent
        }
    }
}
