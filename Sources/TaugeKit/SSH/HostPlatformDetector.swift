import Foundation
import NIOCore

/// Figures out which operating system a freshly connected host runs.
///
/// The probe is a single `exec` channel that prints `KEY=VALUE` lines: `uname`
/// covers the kernel, `sw_vers` covers macOS, and `/etc/os-release` covers the
/// distribution. Because every line is `KEY=VALUE`, one tiny parser handles all
/// three sources. Detection is best effort — an appliance without `uname`, a
/// restricted `ForceCommand`, or a terse banner simply leaves the icon generic.
public enum HostPlatformDetector {
    /// One remote command, so detection costs a single channel round trip.
    /// The outer quotes are single so the login shell of the target user (which may
    /// be fish or csh) treats the whole script as one literal argument; the actual
    /// work then runs under POSIX `/bin/sh`, present on every Unix we support.
    public static let probeCommand = #"/bin/sh -c 'printf "SXOS_KERNEL=%s\n" "$(uname -s)"; printf "SXOS_RELEASE=%s\n" "$(uname -r)"; printf "SXOS_MACOS=%s\n" "$(sw_vers -productVersion 2>/dev/null)"; cat /etc/os-release 2>/dev/null'"#

    /// Runs the probe over an established client and parses whatever comes back.
    public static func detect(using client: SSHClient,
                              timeout: TimeAmount = .seconds(10)) async -> HostPlatformInfo? {
        // Partial output is still useful: a slow login shell may print the kernel
        // line before the timeout closes the channel.
        guard let output = try? await client.runCommand(probeCommand, timeout: timeout) else { return nil }
        return parse(probeOutput: output)
    }

    /// Parses the probe output. Exposed so the self-check suite can exercise the
    /// distro mapping without a server.
    public static func parse(probeOutput: String) -> HostPlatformInfo? {
        var fields: [String: String] = [:]
        for rawLine in probeOutput.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            // os-release keys are uppercase ASCII; skipping anything else keeps the
            // shell's own noise (prompts, banners) out of the field table.
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0 == "_" }) else { continue }
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            fields[key.uppercased()] = value
        }

        let kernel = fields["SXOS_KERNEL"] ?? ""
        guard !kernel.isEmpty else { return nil }

        let lowerKernel = kernel.lowercased()
        let platform: HostPlatform
        if lowerKernel.hasPrefix("darwin") {
            platform = .macOS
        } else if lowerKernel.contains("freebsd") || lowerKernel.contains("openbsd") || lowerKernel.contains("netbsd") {
            platform = .freebsd
        } else if lowerKernel.contains("cygwin") || lowerKernel.contains("mingw") || lowerKernel.contains("windows") {
            platform = .windows
        } else if lowerKernel.contains("linux") {
            platform = linuxPlatform(fields: fields)
        } else {
            platform = .unknown
        }

        return HostPlatformInfo(platform: platform,
                                detail: detailText(platform: platform, kernel: kernel, fields: fields),
                                detectedAt: Date())
    }

    /// Maps `ID`/`ID_LIKE` from os-release onto a logo. `ID_LIKE` matters because
    /// derivatives (Linux Mint, Rocky, Amazon Linux) only inherit their parent's
    /// family instead of naming it in `ID`.
    private static func linuxPlatform(fields: [String: String]) -> HostPlatform {
        // "ID" is authoritative and must win over "ID_LIKE": CentOS names itself
        // centos yet lists rhel, and AlmaLinux lists both rhel and centos, so a
        // family check that ran first would draw the wrong logo.
        if let brand = brand(for: (fields["ID"] ?? "").lowercased()) {
            return brand
        }

        // Derivatives without a logo of their own only name their family. Only an
        // unambiguous family is worth borrowing — Rocky Linux lists rhel, centos
        // and fedora at once, so it keeps the generic Tux instead of guessing.
        let families = Set((fields["ID_LIKE"] ?? "").lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .compactMap { brand(for: String($0)) })
        if families.count == 1, let family = families.first {
            return family
        }
        return .linux
    }

    /// Maps one os-release identifier (the "ID" value or a single "ID_LIKE" token)
    /// to a logo.
    private static func brand(for identifier: String) -> HostPlatform? {
        switch identifier {
        case "ubuntu": return .ubuntu
        case "centos": return .centos
        case "debian": return .debian
        case "fedora": return .fedora
        case "almalinux", "alma": return .almalinux
        case "arch", "archlinux", "manjaro": return .archlinux
        case "opensuse", "opensuse-leap", "opensuse-tumbleweed", "suse", "sles": return .opensuse
        case "alpine": return .alpinelinux
        case "rhel", "redhat": return .redhat
        default: return nil
        }
    }

    private static func detailText(platform: HostPlatform, kernel: String, fields: [String: String]) -> String {
        switch platform {
        case .macOS:
            let version = fields["SXOS_MACOS"] ?? ""
            return version.isEmpty ? "macOS" : "macOS " + version
        case .windows:
            return "Windows"
        case .unknown:
            let release = fields["SXOS_RELEASE"] ?? ""
            return release.isEmpty ? kernel : kernel + " " + release
        case .freebsd:
            let release = fields["SXOS_RELEASE"] ?? ""
            return release.isEmpty ? "FreeBSD" : "FreeBSD " + release
        default:
            if let pretty = fields["PRETTY_NAME"] ?? fields["NAME"], !pretty.isEmpty { return pretty }
            return platform.displayName
        }
    }
}
