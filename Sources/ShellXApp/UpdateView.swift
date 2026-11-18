import AppKit
import ShellXKit
import SwiftUI

struct UpdateView: View {
    @ObservedObject var controller: UpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 560, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 46, height: 46)
                Image(systemName: phaseIcon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(phaseTitle)
                    .font(.title3.weight(.semibold))
                Text(L("版本 %@（构建 %@）", controller.currentVersion, TaugeAppInfo.build))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle:
            message(L("点击“检查更新”获取 GitHub 上的最新版本。"), icon: "arrow.triangle.2.circlepath")
        case .checking:
            VStack(alignment: .leading, spacing: 14) {
                ProgressView()
                    .controlSize(.small)
                Text(L("正在连接 GitHub 查询最新版本…"))
                    .foregroundStyle(.secondary)
            }
        case .upToDate:
            VStack(alignment: .leading, spacing: 14) {
                Label(L("你使用的是最新版本。"), systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text(L("Tauge %@ 已是最新版本。", controller.currentVersion))
                    .foregroundStyle(.secondary)
            }
        case .available, .downloading, .ready, .installing:
            availableContent
        case .failed:
            VStack(alignment: .leading, spacing: 14) {
                Label(L("无法完成更新"), systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                if let error = controller.errorMessage {
                    Text(error)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var availableContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let update = controller.update {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("最新版本 %@", update.version.description))
                        .font(.headline)
                    if !update.displaySize.isEmpty {
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(update.displaySize)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link(L("在 GitHub 上查看"), destination: update.releaseURL)
                        .font(.callout)
                }

                if controller.phase == .downloading {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L("正在下载并校验更新包…"))
                            .foregroundStyle(.secondary)
                    }
                } else if controller.phase == .ready {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L("正在验证更新包…"))
                            .foregroundStyle(.secondary)
                    }
                } else if controller.phase == .installing {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L("正在安装更新，Tauge 即将重新启动。"))
                            .foregroundStyle(.secondary)
                    }
                }

                if !update.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("更新内容"))
                            .font(.subheadline.weight(.semibold))
                        ScrollView {
                            Text(update.notes)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 180)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            switch controller.phase {
            case .idle:
                Button(L("关闭")) { controller.closeWindow() }
                    .keyboardShortcut(.cancelAction)
                Button(L("检查更新")) { controller.checkForUpdates(manual: true) }
                    .keyboardShortcut(.defaultAction)
            case .checking:
                Button(L("关闭")) { controller.closeWindow() }
                    .keyboardShortcut(.cancelAction)
            case .upToDate:
                Link(L("在 GitHub 上查看"), destination: URL(string: "https://github.com/surgingDandelion/Tauge/releases")!)
                Button(L("好")) { controller.closeWindow() }
                    .keyboardShortcut(.defaultAction)
            case .available:
                Button(L("稍后")) { controller.closeWindow() }
                    .keyboardShortcut(.cancelAction)
                Button(L("下载并安装")) { controller.downloadAndInstall() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .downloading, .ready:
                Button(L("取消")) { controller.cancelDownload() }
                    .keyboardShortcut(.cancelAction)
            case .installing:
                EmptyView()
            case .failed:
                Button(L("关闭")) { controller.closeWindow() }
                    .keyboardShortcut(.cancelAction)
                Button(L("重试")) { controller.retry() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func message(_ text: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }

    private var phaseTitle: String {
        switch controller.phase {
        case .idle: return L("检查更新")
        case .checking: return L("正在检查更新…")
        case .upToDate: return L("已是最新版本")
        case .available: return L("发现新版本")
        case .downloading: return L("正在下载更新…")
        case .ready: return L("正在验证更新…")
        case .installing: return L("正在安装更新…")
        case .failed: return L("更新失败")
        }
    }

    private var phaseIcon: String {
        switch controller.phase {
        case .idle: return "arrow.triangle.2.circlepath"
        case .checking: return "arrow.triangle.2.circlepath"
        case .upToDate: return "checkmark.seal"
        case .available: return "arrow.down.circle"
        case .downloading: return "arrow.down.circle"
        case .ready: return "checkmark.shield"
        case .installing: return "gearshape.2"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

final class UpdateWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(controller: UpdateController) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("检查更新")
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: UpdateView(controller: controller))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
