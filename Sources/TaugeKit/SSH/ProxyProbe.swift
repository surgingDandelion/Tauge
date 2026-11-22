import Foundation
import NIOCore
import NIOPosix

/// The outcome of asking a proxy to open a tunnel to a specific host and port.
///
/// Kept deliberately small so the UI can render one line without parsing text,
/// and so the checks can assert on behaviour instead of on translated strings.
public struct ProxyProbeResult: Sendable, Equatable {
    public enum Outcome: String, Sendable {
        /// The tunnel was established; target reachability beyond that is SSH's business.
        case ok
        /// The TCP connection to the proxy host/port failed: wrong address, port, or network.
        case proxyUnreachable
        /// The proxy was reached but refused or failed the handshake: wrong type,
        /// missing credentials, or a policy denial.
        case handshakeRejected
    }

    public var outcome: Outcome
    public var elapsedMilliseconds: Int
    public var summary: String
    public var recommendation: String?

    public init(outcome: Outcome,
                elapsedMilliseconds: Int,
                summary: String,
                recommendation: String?) {
        self.outcome = outcome
        self.elapsedMilliseconds = elapsedMilliseconds
        self.summary = summary
        self.recommendation = recommendation
    }

    public var isSuccess: Bool { outcome == .ok }
}

public enum ProxyProbe {
    /// Opens a proxy tunnel to `targetHost:targetPort` and immediately closes it.
    ///
    /// This answers the one question the connect path cannot answer clearly:
    /// whether the problem is the proxy leg (address, type, credentials) or the
    /// target machine. It never speaks SSH, so it works even when the target is
    /// only reachable through the proxy.
    public static func test(_ proxy: ProxyEndpoint,
                            targetHost: String,
                            targetPort: Int,
                            timeout: TimeAmount = .seconds(10)) async -> ProxyProbeResult {
        let started = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> Int {
            Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }

        if proxy.type == .https {
            return ProxyProbeResult(
                outcome: .handshakeRejected,
                elapsedMilliseconds: elapsed(),
                summary: ProxyHandshakeError.unsupportedType("HTTPS").localizedDescription,
                recommendation: L("改用 HTTP CONNECT 或 SOCKS5 代理；HTTPS（TLS）代理暂未实现。")
            )
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let result: ProxyProbeResult
        do {
            let channel = try await TCPConnector.connect(targetHost: targetHost,
                                                         targetPort: targetPort,
                                                         proxy: proxy,
                                                         group: group,
                                                         timeout: timeout)
            channel.close(mode: .all, promise: nil)
            result = ProxyProbeResult(
                outcome: .ok,
                elapsedMilliseconds: elapsed(),
                summary: L("代理可用：经 ") + proxy.host + ":" + String(proxy.port)
                    + L(" 已打通到 ") + targetHost + ":" + String(targetPort) + L(" 的隧道"),
                recommendation: nil
            )
        } catch let error as ProxyConnectionError {
            result = ProxyProbeResult(
                outcome: .proxyUnreachable,
                elapsedMilliseconds: elapsed(),
                summary: error.localizedDescription,
                recommendation: L("这一步只验证到代理这一段；失败说明本机到代理地址/端口不通（VPN、端口或地址有误），与目标主机无关。")
            )
        } catch let error as ProxyHandshakeError {
            result = ProxyProbeResult(
                outcome: .handshakeRejected,
                elapsedMilliseconds: elapsed(),
                summary: error.localizedDescription,
                recommendation: recommendation(for: error, proxy: proxy)
            )
        } catch {
            result = ProxyProbeResult(
                outcome: .handshakeRejected,
                elapsedMilliseconds: elapsed(),
                summary: error.localizedDescription,
                recommendation: L("代理已连通，但握手没有完成；确认代理类型与端口是否匹配。")
            )
        }
        try? await group.shutdownGracefully()
        return result
    }

    /// Parses the "host:port" text typed into a test field. A bare host keeps
    /// `defaultPort` so the field can show just a hostname.
    public static func parseTarget(_ text: String, defaultPort: Int = 443) -> (host: String, port: Int)? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            let host = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            if rest.hasPrefix(":"), let port = Int(rest.dropFirst()), port > 0, port < 65536 {
                return (host, port)
            }
            return host.isEmpty ? nil : (host, defaultPort)
        }
        if let colon = value.lastIndex(of: ":") {
            let host = String(value[..<colon])
            let portText = String(value[value.index(after: colon)...])
            // A numeric suffix is a port; if it is out of range say so instead of
            // quietly treating "host:99999" as a host name.
            if !portText.isEmpty, portText.allSatisfy({ $0.isNumber }) {
                guard let port = Int(portText), port > 0, port < 65536, !host.isEmpty else { return nil }
                return (host, port)
            }
        }
        return (value, defaultPort)
    }

    private static func recommendation(for error: ProxyHandshakeError, proxy: ProxyEndpoint) -> String {
        switch error {
        case .unsupportedType:
            return L("改用 HTTP CONNECT 或 SOCKS5 代理；HTTPS（TLS）代理暂未实现。")
        case .timeout, .malformedResponse, .closedWithoutResponse:
            return L("TCP 能连上但对方没有按 ") + proxy.type.displayName
                + L(" 应答：确认「类型」与端口是否匹配（例如 8080 是 HTTP CONNECT，1080 才是 SOCKS5）。")
        case .httpStatus(let code):
            if code == 407 {
                return L("代理要求认证：在代理配置里填写用户名和密码后再测试。")
            }
            if code == 403 {
                return L("代理策略不允许访问该目标：换一个测试目标，或联系代理管理员放行。")
            }
            if code == 502 || code == 503 || code == 504 {
                return L("代理自己连不到目标：说明代理这一段是通的，问题在目标地址或代理到目标的网络。")
            }
            return L("代理返回了 ") + String(code) + L("：检查代理类型、端口与账号。")
        case .socks5MethodRejected:
            return L("代理不接受免密/用户名密码认证：确认代理账号，或先不填用户名密码再试。")
        case .socks5AuthFailed:
            return L("SOCKS5 用户名或密码错误：重新填写密码后保存再测试。")
        case .socks5Reply(let code):
            if code == 0x05 {
                return L("代理连不到目标：说明代理这一段是通的，问题在目标地址或代理到目标的网络。")
            }
            return L("SOCKS5 拒绝连接（错误码 ") + String(code) + L("）：确认目标端口在代理侧可用。")
        }
    }
}
