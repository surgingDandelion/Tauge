import AppKit
import ShellXKit
import SwiftUI

enum BoardSplitMetrics {
    /// Width of the gutter between two panes. The separator is drawn in the
    /// middle; the whole gutter is the drag target, which is why resizing feels
    /// forgiving compared to a hairline.
    static let gutter: CGFloat = 8
    /// Smallest useful pane, in points.
    static let minimumPane: CGFloat = 140
}

/// AppKit-backed divider. SwiftUI's DragGesture on a view that moves under the
/// pointer turns into a feedback loop (the translation resets as the divider
/// follows the cursor), which makes the drag feel dead. Handling mouse events in
/// an NSView avoids that entirely and also gives us a real resize cursor and
/// crisp hairline drawing.
struct BoardSplitHandle: NSViewRepresentable {
    let axis: BoardSplitAxis
    let onBegin: () -> Void
    let onMove: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> BoardSplitHandleView {
        let view = BoardSplitHandleView()
        configure(view)
        return view
    }

    func updateNSView(_ view: BoardSplitHandleView, context: Context) {
        configure(view)
    }

    private func configure(_ view: BoardSplitHandleView) {
        view.axis = axis
        view.onBegin = onBegin
        view.onMove = onMove
        view.onEnd = onEnd
        view.onReset = onReset
    }
}

final class BoardSplitHandleView: NSView {
    var axis: BoardSplitAxis = .horizontal {
        didSet {
            guard oldValue != axis else { return }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var onBegin: (() -> Void)?
    var onMove: ((CGFloat) -> Void)?
    var onEnd: ((CGFloat) -> Void)?
    var onReset: (() -> Void)?

    private var isHovering = false {
        didSet { if oldValue != isHovering { needsDisplay = true } }
    }
    private var isDragging = false {
        didSet { if oldValue != isDragging { needsDisplay = true } }
    }
    private var tracker = BoardSplitDragTracker()
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
            return
        }
        isDragging = true
        tracker.begin(at: event.locationInWindow)
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        onMove?(delta(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        let total = delta(for: event)
        tracker.end()
        onEnd?(total)
    }

    private func delta(for event: NSEvent) -> CGFloat {
        tracker.delta(to: event.locationInWindow, axis: axis) ?? 0
    }

    override func draw(_ dirtyRect: NSRect) {
        let gutter = Theme.windowBackgroundNSColor
        gutter.setFill()
        bounds.fill()

        if isHovering || isDragging {
            NSColor.controlAccentColor.withAlphaComponent(isDragging ? 0.10 : 0.06).setFill()
            bounds.fill()
        }

        let accent = NSColor.controlAccentColor
        let active = isHovering || isDragging

        if axis == .horizontal {
            let width: CGFloat = active ? 3 : 1
            let rect = NSRect(x: bounds.midX - width / 2,
                              y: isDragging ? 0 : bounds.midY - (active ? 22 : bounds.height / 2),
                              width: width,
                              height: isDragging ? bounds.height : (active ? 44 : bounds.height))
            let path = NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2)
            (active ? accent.withAlphaComponent(isDragging ? 0.95 : 0.8) : NSColor.separatorColor).setFill()
            path.fill()
        } else {
            let height: CGFloat = active ? 3 : 1
            let rect = NSRect(x: isDragging ? 0 : bounds.midX - (active ? 22 : bounds.width / 2),
                              y: bounds.midY - height / 2,
                              width: isDragging ? bounds.width : (active ? 44 : bounds.width),
                              height: height)
            let path = NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2)
            (active ? accent.withAlphaComponent(isDragging ? 0.95 : 0.8) : NSColor.separatorColor).setFill()
            path.fill()
        }
    }
}
