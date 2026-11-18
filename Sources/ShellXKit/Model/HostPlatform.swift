import Foundation

/// The remote operating system a host was probed to run.
///
/// Detection runs once after a successful login (see `HostPlatformDetector`) and is
/// cached per host, so the sidebar and start page can draw the matching logo instead
/// of the generic server glyph even before the next connection.
public enum HostPlatform: String, Codable, CaseIterable, Sendable {
    case macOS = "macos"
    case ubuntu
    case centos
    case debian
    case fedora
    case redhat
    case almalinux
    case archlinux
    case opensuse
    case alpinelinux
    case freebsd
    /// A Linux host whose distribution has no dedicated logo.
    case linux
    case windows
    /// The probe could not tell what the host runs.
    case unknown

    /// Human readable label used in tooltips and error messages.
    public var displayName: String {
        switch self {
        case .macOS: return "macOS"
        case .ubuntu: return "Ubuntu"
        case .centos: return "CentOS"
        case .debian: return "Debian"
        case .fedora: return "Fedora"
        case .redhat: return "Red Hat Enterprise Linux"
        case .almalinux: return "AlmaLinux"
        case .archlinux: return "Arch Linux"
        case .opensuse: return "openSUSE"
        case .alpinelinux: return "Alpine Linux"
        case .freebsd: return "FreeBSD"
        case .linux: return "Linux"
        case .windows: return "Windows"
        case .unknown: return "未知系统"
        }
    }

    /// PNG basename shipped in `Sources/ShellXApp/Assets` and copied into the app
    /// bundle by `scripts/build-app.sh`. `nil` means there is no logo for this
    /// platform and the UI keeps its generic server symbol.
    public var iconName: String? {
        switch self {
        case .linux: return "os-linux"
        case .windows, .unknown: return nil
        default: return "os-" + rawValue
        }
    }

    /// True for platforms the probe recognized with confidence, which lets the UI
    /// tell "still detecting" apart from "gave up".
    public var isDetected: Bool { self != .unknown }
}

/// One detection result: which platform, plus enough text to show the user what
/// the probe actually saw ("Ubuntu 22.04.4 LTS", "Darwin 23.2.0").
public struct HostPlatformInfo: Codable, Equatable, Sendable {
    public var platform: HostPlatform
    public var detail: String
    public var detectedAt: Date

    public init(platform: HostPlatform, detail: String, detectedAt: Date = Date()) {
        self.platform = platform
        self.detail = detail
        self.detectedAt = detectedAt
    }
}
