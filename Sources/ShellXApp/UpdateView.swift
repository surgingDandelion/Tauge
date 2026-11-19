import AppKit
import Foundation
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
                    downloadStatus
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
                            UpdateNotesView(source: update.notes)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 180)
                    }
                }
            }
        }
    }

    /// Determinate bar plus byte counts and a smoothed rate. The old view
    /// showed a bare spinner, which told the user nothing about a 30 MB
    /// archive on a slow link; GitHub always advertises a content length, so
    /// the bar is determinate unless a proxy strips it.
    private var downloadStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fraction = controller.downloadProgress?.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(downloadByteSummary)
                Spacer(minLength: 12)
                Text(downloadRateSummary)
                    .monospacedDigit()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var downloadByteSummary: String {
        guard let progress = controller.downloadProgress else {
            return L("正在下载更新…")
        }
        let received = FileAttributeFormatter.size(progress.bytesReceived)
        guard progress.totalBytes > 0 else {
            return L("已下载 %@", received)
        }
        let total = FileAttributeFormatter.size(progress.totalBytes)
        let percent = Int(((progress.fraction ?? 0) * 100).rounded())
        return L("已下载 %@ / %@", received, total) + " · " + String(percent) + "%"
    }

    private var downloadRateSummary: String {
        let speed = controller.downloadSpeed > 0
            ? FileAttributeFormatter.speed(bytesPerSecond: controller.downloadSpeed)
            : L("正在等待数据…")
        guard let remaining = controller.downloadRemainingTime else { return speed }
        return speed + " · " + L("剩余 %@", FileAttributeFormatter.duration(remaining))
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

/// SwiftUI's `Text` supports inline Markdown attributes, but it does not lay
/// out block-level Markdown such as headings and lists. Split release notes
/// into blocks first so the update window keeps the document structure while
/// still using Foundation for bold text, links, and code spans.
private struct UpdateNotesView: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(UpdateMarkdownBlock.parse(source).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: UpdateMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inlineText(text)
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(headingFont(for: level))
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 4 : 0)
        case .unorderedItem(let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .foregroundStyle(.secondary)
                inlineText(text)
            }
            .padding(.leading, CGFloat(indent * 4))
        case .orderedItem(let indent, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number + ".")
                    .foregroundStyle(.secondary)
                inlineText(text)
            }
            .padding(.leading, CGFloat(indent * 4))
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 2)
                inlineText(text)
                    .foregroundStyle(.secondary)
            }
        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        case .divider:
            Divider()
        }
    }

    private func inlineText(_ text: String) -> some View {
        Text(inlineMarkdown(text))
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.semibold)
        case 2: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }
}

private enum UpdateMarkdownBlock {
    case paragraph(String)
    case heading(level: Int, text: String)
    case unorderedItem(indent: Int, text: String)
    case orderedItem(indent: Int, number: String, text: String)
    case quote(String)
    case code(String)
    case divider

    static func parse(_ source: String) -> [Self] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [Self] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let text = paragraphLines.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraphLines.removeAll(keepingCapacity: true)
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let fence = fencePrefix(in: trimmed) {
                flushParagraph()
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence) {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.code(codeLines.joined(separator: "\n")))
                continue
            }

            if let heading = headingParts(in: line) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isDivider(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }

            if let list = listParts(in: line) {
                flushParagraph()
                switch list {
                case .unordered(let indent, let text):
                    blocks.append(.unorderedItem(indent: indent, text: text))
                case .ordered(let indent, let number, let text):
                    blocks.append(.orderedItem(indent: indent, number: number, text: text))
                }
                index += 1
                continue
            }

            if trimmed.first == ">" {
                flushParagraph()
                let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                blocks.append(.quote(text))
                index += 1
                continue
            }

            paragraphLines.append(trimmed)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private enum ListParts {
        case unordered(indent: Int, text: String)
        case ordered(indent: Int, number: String, text: String)
    }

    private static func fencePrefix(in line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func headingParts(in line: String) -> (level: Int, text: String)? {
        let characters = Array(line)
        var level = 0
        while level < characters.count, characters[level] == "#" { level += 1 }
        guard (1...6).contains(level),
              level < characters.count,
              characters[level].isWhitespace else { return nil }
        let text = String(characters.dropFirst(level))
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (level, text)
    }

    private static func listParts(in line: String) -> ListParts? {
        var indent = 0
        var offset = line.startIndex
        while offset < line.endIndex {
            switch line[offset] {
            case " ": indent += 1
            case "\t": indent += 4
            default: return listParts(in: String(line[offset...]), indent: indent)
            }
            offset = line.index(after: offset)
        }
        return nil
    }

    private static func listParts(in body: String, indent: Int) -> ListParts? {
        guard let first = body.first else { return nil }
        if (first == "-" || first == "*" || first == "+"), body.dropFirst().first?.isWhitespace == true {
            let text = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : .unordered(indent: indent, text: text)
        }

        var digitEnd = body.startIndex
        while digitEnd < body.endIndex, body[digitEnd].isNumber {
            digitEnd = body.index(after: digitEnd)
        }
        guard digitEnd > body.startIndex,
              digitEnd < body.endIndex,
              body[digitEnd] == "." else { return nil }
        let afterDot = body.index(after: digitEnd)
        guard afterDot < body.endIndex, body[afterDot].isWhitespace else { return nil }
        let text = String(body[body.index(after: afterDot)...])
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .ordered(indent: indent, number: String(body[..<digitEnd]), text: text)
    }

    private static func isDivider(_ line: String) -> Bool {
        let symbols = line.filter { !$0.isWhitespace }
        guard symbols.count >= 3 else { return false }
        guard let first = symbols.first, first == "-" || first == "*" || first == "_" else { return false }
        return symbols.allSatisfy { $0 == first }
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
