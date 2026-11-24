import AppKit
import Combine
import SwiftUI

/// Keeps the native window's resizing and lifecycle while letting the main
/// toolbar draw its own controls.
@MainActor
final class MainWindowChrome: ObservableObject {
    @Published private(set) var isFullScreen = false
    @Published private(set) var isWindowActive = false
    private weak var window: NSWindow?

    static let changes = Publishers.MergeMany([
        NSWindow.didBecomeKeyNotification,
        NSWindow.didResignKeyNotification,
        NSWindow.didEnterFullScreenNotification,
        NSWindow.didExitFullScreenNotification
    ].map { NotificationCenter.default.publisher(for: $0) })

    func attach(to window: NSWindow) {
        self.window = window
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        refresh(window)
    }

    func windowDidChange(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window else { return }
        refresh(window)
    }

    func close() { window?.performClose(nil) }

    func minimize() { window?.performMiniaturize(nil) }

    func toggleFullScreen() { window?.toggleFullScreen(nil) }

    private func refresh(_ window: NSWindow) {
        // AppKit can recreate these when a window enters or leaves fullscreen.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        let fullScreen = window.styleMask.contains(.fullScreen)
        if isFullScreen != fullScreen { isFullScreen = fullScreen }
        if isWindowActive != window.isKeyWindow { isWindowActive = window.isKeyWindow }
    }
}

/// An empty toolbar region handles native dragging and zooming without
/// capturing clicks intended for the window controls or the terminal.
struct WindowDragRegion: NSViewRepresentable {
    let onAttach: (NSWindow) -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.onAttach = onAttach
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.onAttach = onAttach
    }

    final class DragView: NSView {
        var onAttach: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.onAttach?(window)
            }
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                if window.styleMask.contains(.resizable), !window.styleMask.contains(.fullScreen) {
                    window.zoom(nil)
                }
                return
            }
            window.performDrag(with: event)
        }
    }
}
