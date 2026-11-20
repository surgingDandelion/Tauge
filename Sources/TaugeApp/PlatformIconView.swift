import AppKit
import TaugeKit
import SwiftUI

/// Loads the bundled operating-system logos.
///
/// The PNGs live flat in `Sources/TaugeApp/Assets` (copied into
/// `Contents/Resources/Assets` by `scripts/build-app.sh`) and are drawn as
/// template images so they take the app tint like the SF Symbols next to them.
/// `Bundle.module` is deliberately not used: that accessor traps when the SwiftPM
/// resource bundle is not shipped inside the `.app`.
enum PlatformIcon {
    static func image(named name: String, pointSize: CGFloat) -> NSImage? {
        let key = name + "@" + String(format: "%.0f", pointSize)
        return cache.image(for: key) {
            guard let url = pngURL(named: name),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { return nil }
            rep.size = NSSize(width: pointSize, height: pointSize)
            let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
            image.addRepresentation(rep)
            image.isTemplate = true
            return image
        }
    }

    /// Brand tint per platform, kept close to the official logo colour but lifted
    /// where the original is too dark to read on the dark sidebar.
    static func tint(for platform: HostPlatform) -> Color {
        switch platform {
        case .macOS:
            return .primary
        case .ubuntu:
            return Color(hex: "#E95420") ?? Theme.secondary
        case .centos:
            return Color(hex: "#A94FA8") ?? Theme.secondary
        case .debian:
            return Color(hex: "#D70A53") ?? Theme.secondary
        case .fedora:
            return Color(hex: "#51A2DA") ?? Theme.secondary
        case .redhat:
            return Color(hex: "#EE3B3B") ?? Theme.secondary
        case .almalinux:
            return Color(hex: "#28B0D8") ?? Theme.secondary
        case .archlinux:
            return Color(hex: "#1793D1") ?? Theme.secondary
        case .opensuse:
            return Color(hex: "#73BA25") ?? Theme.secondary
        case .alpinelinux:
            return Color(hex: "#2F86AE") ?? Theme.secondary
        case .freebsd:
            return Color(hex: "#C2443F") ?? Theme.secondary
        case .linux, .windows, .unknown:
            return Theme.secondary
        }
    }

    private static let cache = IconCache()

    private static func pngURL(named name: String) -> URL? {
        var directories: [URL] = []
        if let resources = Bundle.main.resourceURL {
            directories.append(resources.appendingPathComponent("Assets"))
            directories.append(resources)
        }
        let executableDirectory = Bundle.main.bundleURL
        directories.append(executableDirectory
            .appendingPathComponent("Tauge_TaugeApp.bundle/Contents/Resources/Assets"))
        directories.append(executableDirectory.appendingPathComponent("Assets"))
        for directory in directories {
            let candidate = directory.appendingPathComponent(name + ".png")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

/// Lock-protected image cache: logos are loaded once per size instead of on every
/// sidebar redraw.
private final class IconCache: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: NSImage] = [:]

    func image(for key: String, build: () -> NSImage?) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = images[key] { return cached }
        guard let image = build() else { return nil }
        images[key] = image
        return image
    }
}

/// One host's operating-system logo. Falls back to the generic server glyph until
/// the host has been logged into and the probe has answered.
struct HostPlatformIcon: View {
    var platform: HostPlatform?
    var detail: String? = nil
    var size: CGFloat = 12
    var fallbackColor: Color = Theme.secondary

    var body: some View {
        Group {
            if let platform, let iconName = platform.iconName,
               let image = PlatformIcon.image(named: iconName, pointSize: size) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .foregroundStyle(PlatformIcon.tint(for: platform))
            } else {
                Image(systemName: "server.rack")
                    .font(.system(size: size * 0.92, weight: .medium))
                    .foregroundStyle(fallbackColor)
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        guard let platform else { return L("登录后自动识别操作系统") }
        if let detail, !detail.isEmpty { return detail }
        return platform.displayName
    }
}
