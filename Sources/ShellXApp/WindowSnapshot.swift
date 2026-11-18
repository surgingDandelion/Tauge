import AppKit
import ShellXKit

/// Developer hook that renders the main window to a PNG without a screen
/// capture. Useful when the session is locked (screencapture returns
/// "could not create image from window"), for CI-style visual checks, and for
/// grabbing a window that is behind other apps.
///
/// Run with `SHELLX_SNAPSHOT=/tmp/tauge.png`. Optional:
///   SHELLX_SNAPSHOT_DELAY  seconds to wait for the UI to settle (default 5)
///   SHELLX_SNAPSHOT_EXIT   1 = terminate after writing the file
///
/// The bitmap is produced by walking the view's Core Animation layer tree, so
/// it does not need the window server to composite the window (which is exactly
/// what a locked screen forbids).
@MainActor
enum WindowSnapshot {
    private static var outputPath: String? {
        guard let path = ProcessInfo.processInfo.environment["SHELLX_SNAPSHOT"], !path.isEmpty else { return nil }
        return path
    }

    static var isEnabled: Bool { outputPath != nil }

    static func runIfRequested() {
        guard let path = outputPath else { return }
        let delay = Double(ProcessInfo.processInfo.environment["SHELLX_SNAPSHOT_DELAY"] ?? "") ?? 5
        let exitAfter = ProcessInfo.processInfo.environment["SHELLX_SNAPSHOT_EXIT"] == "1"
        let sequence = ProcessInfo.processInfo.environment["SHELLX_SNAPSHOT_SEQUENCE"] == "1"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.5) * 1_000_000_000))
            if sequence {
                await captureThemeSweep(base: path)
            } else {
                capture(to: path)
            }
            if exitAfter {
                try? await Task.sleep(nanoseconds: 200_000_000)
                NSApp.terminate(nil)
            }
        }
    }

    /// Grabs the four screens the theme work has to look right on: the workspace
    /// and the start page, each in light and dark appearance. Selection and
    /// appearance are restored afterwards so a QA run does not change what the
    /// user sees next launch (showStartPage() would persist "no selection").
    private static func captureThemeSweep(base: String) async {
        let app = AppState.shared
        let savedTab = app.selectedTabID
        let savedBoard = app.selectedBoardID
        let savedAppearance = NSApp.appearance

        func rest() async {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
        func shot(_ suffix: String) {
            capture(to: suffixed(base, suffix))
        }

        shot("-light-workspace")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await rest()
        shot("-dark-workspace")
        app.selectedTabID = nil
        app.selectedBoardID = nil
        await rest()
        shot("-dark-start")
        NSApp.appearance = NSAppearance(named: .aqua)
        await rest()
        shot("-light-start")
        app.selectedTabID = savedTab
        app.selectedBoardID = savedBoard
        NSApp.appearance = savedAppearance
        await rest()
        shot("-light-workspace-restored")
    }

    private static func suffixed(_ path: String, _ suffix: String) -> String {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        return dir.appendingPathComponent(stem + suffix).appendingPathExtension(ext).path
    }

    /// Writes the largest titled window's content view to `path`.
    @discardableResult
    static func capture(to path: String) -> Bool {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 && $0.contentView != nil }),
              let view = window.contentView else {
            report("no window to capture")
            return false
        }
        guard let image = render(view: view, scale: window.backingScaleFactor) else {
            report("render produced no image")
            return false
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            report("png encoding failed")
            return false
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            report("wrote \(path) \(image.width)x\(image.height)")
            return true
        } catch {
            report("write failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Prints the terminal views' real colors when SHELLX_SNAPSHOT_DEBUG=1.
    /// Used to tell a genuine palette problem from a snapshot-only artifact.
    private static func debugDumpTerminals(_ root: NSView) {
        guard ProcessInfo.processInfo.environment["SHELLX_SNAPSHOT_DEBUG"] == "1" else { return }
        var stack = [root]
        while let view = stack.popLast() {
            stack.append(contentsOf: view.subviews)
            guard String(describing: type(of: view)).contains("Terminal") else { continue }
            let bg = (view as? NSTextView)?.backgroundColor
            let layerBG = view.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
            report("terminal \(type(of: view)) appearance=\(view.effectiveAppearance.name.rawValue) "
                   + "textBg=\(bg.map { "\($0)" } ?? "nil") layerBg=\(layerBG.map { "\($0.usingColorSpace(.sRGB) ?? $0)" } ?? "nil") "
                   + "layerOpaque=\(view.layer?.isOpaque ?? false) alpha=\(view.alphaValue)")
        }
    }

    private static func render(view: NSView, scale: CGFloat) -> CGImage? {
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Core Animation layers are laid out with a bottom-left origin while the
        // captured bitmap is top-down: flip vertically so the PNG reads upright.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)

        if let layer = view.layer {
            // SwiftUI builds a deep layer tree; rendering it directly picks up
            // gradients, shadows and the terminal's own layers.
            view.layoutSubtreeIfNeeded()
            // A window that the window server is not compositing (locked screen,
            // hidden app) never gets asked to draw, so its terminal layers are
            // still empty. Force every view that draws itself to draw now.
            forceDisplay(view)
            debugDumpTerminals(view)
            layer.displayIfNeeded()
            layer.render(in: context)
            if let image = context.makeImage() { return image }
        }

        // Fallback for plain AppKit views without layers.
        if let rep = view.bitmapImageRepForCachingDisplay(in: bounds) {
            view.cacheDisplay(in: bounds, to: rep)
            return rep.cgImage
        }
        return nil
    }

    /// Walks the hierarchy and makes every view draw immediately.
    private static func forceDisplay(_ view: NSView) {
        for subview in view.subviews {
            forceDisplay(subview)
            subview.needsDisplay = true
            subview.displayIfNeeded()
            subview.layer?.displayIfNeeded()
        }
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data(("[snapshot] " + message + "\n").utf8))
    }
}
