import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One decoded drag operation that reached an AppKit drop container.
struct DroppedContent {
    struct RemotePath {
        var hostID: String?
        var path: String
        var paneID: String?
    }

    var remotePaths: [RemotePath] = []
    var fileURLs: [URL] = []

    var isEmpty: Bool { remotePaths.isEmpty && fileURLs.isEmpty }
}

/// AppKit-backed drop area.
///
/// SwiftUI's `.onDrop` needs a hit-tested SwiftUI view under the pointer and
/// silently drops the operation when the drag source only publishes a custom
/// pasteboard type (which is exactly what dragging a remote SFTP row does).
/// Wrapping the content in a real `NSView` dragging destination gives AppKit a
/// destination it can always find: the drag search starts at the hosting view
/// and walks up the superview chain.
struct DropArea<Content: View>: NSViewRepresentable {
    var app: AppState
    var onDrop: (DroppedContent) -> Void
    var content: Content

    init(app: AppState, onDrop: @escaping (DroppedContent) -> Void, @ViewBuilder content: () -> Content) {
        self.app = app
        self.onDrop = onDrop
        self.content = content()
    }

    /// `NSHostingView` starts a fresh SwiftUI graph, so the environment has to
    /// be re-injected; otherwise `@EnvironmentObject` lookups inside the hosted
    /// panes would trap at runtime.
    private var hostedContent: AnyView {
        AnyView(content.environmentObject(app))
    }

    func makeNSView(context: Context) -> DropContainerView {
        let view = DropContainerView()
        view.handler = onDrop
        view.setContent(hostedContent)
        return view
    }

    func updateNSView(_ nsView: DropContainerView, context: Context) {
        nsView.handler = onDrop
        nsView.setContent(hostedContent)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DropContainerView, context: Context) -> CGSize? {
        // An `NSView` has no intrinsic size, so returning `nil` here would let
        // SwiftUI collapse the whole SFTP area to nothing in a flexible parent.
        // Fall back to the panel's design size when a dimension is unspecified.
        let width = proposal.width ?? 640
        let height = proposal.height ?? 240
        return CGSize(width: width, height: height)
    }
}

final class DropContainerView: NSView {
    var handler: ((DroppedContent) -> Void)?
    private var hosting: NSHostingView<AnyView>?

    private var acceptedTypes: [NSPasteboard.PasteboardType] {
        [
            NSPasteboard.PasteboardType(RemoteFileDrag.payloadType.identifier),
            .fileURL,
            .string,
        ]
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(acceptedTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(acceptedTypes)
    }

    func setContent(_ view: AnyView) {
        if let hosting {
            hosting.rootView = view
            return
        }
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.hosting = hosting
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        decode(sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        decode(sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let content = decode(sender.draggingPasteboard)
        guard !content.isEmpty else { return false }
        handler?(content)
        return true
    }

    private func decode(_ pasteboard: NSPasteboard) -> DroppedContent {
        var content = DroppedContent()

        let customType = RemoteFileDrag.payloadType.identifier
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(customType)),
           let payload = try? JSONDecoder().decode(RemoteFileDrag.Payload.self, from: data) {
            content.remotePaths.append(.init(hostID: payload.hostID, path: payload.path, paneID: payload.paneID))
        } else if let raw = pasteboard.string(forType: .string) {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // A plain string drop is only treated as a remote path when it looks
            // like an absolute POSIX path; arbitrary text is ignored.
            if path.hasPrefix("/"), !path.contains("\n") {
                content.remotePaths.append(.init(hostID: nil, path: path))
            }
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            content.fileURLs = urls
        }

        return content
    }
}
