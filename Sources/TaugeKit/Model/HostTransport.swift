import Foundation

/// How Tauge talks to a host.
///
/// The built-in transport is the vendored SwiftNIO SSH stack: modern key
/// exchange, AEAD ciphers, and no external processes. Some appliances and
/// long-lived servers (CentOS 6-era OpenSSH 5.3, for example) only offer
/// ssh-rsa host keys with SHA-1 and diffie-hellman-group14-sha1, which that
/// stack deliberately refuses. Those hosts can be reached through the system
/// `/usr/bin/ssh` instead, trading the in-process stack for whatever legacy
/// algorithms the local OpenSSH build still accepts.
public enum HostTransport: String, Codable, CaseIterable, Sendable {
    case builtin
    case system

    public var displayName: String {
        switch self {
        case .builtin: return L("内置（推荐）")
        case .system: return L("系统 ssh（兼容旧服务器）")
        }
    }

    public var detail: String {
        switch self {
        case .builtin:
            return L("使用 Tauge 内置的 SSH 实现，支持口令、私钥与跳板，不依赖系统组件。")
        case .system:
            return L("调用 /usr/bin/ssh，可连接只支持 ssh-rsa、diffie-hellman-group14-sha1 等旧算法的服务器；")
                + L("会读取 ~/.ssh/config 与 known_hosts，代理认证需在系统 ssh 中配置。")
        }
    }
}
