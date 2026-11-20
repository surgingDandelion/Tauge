import Foundation
import NIOCore
import NIOPosix

/// Turns transport-level failures into something a person can act on.
///
/// NIO reports these as opaque bridged errors ("The operation couldn't be completed.
/// (NIOCore.ChannelError error 0.)"), so the raw description is replaced with the
/// actual cause and, where it makes sense, the failing machine.
public enum TransportFailure {
    public struct Description: Sendable {
        public var stage: SSHConnectionStage?
        public var detail: String?

        public init(stage: SSHConnectionStage?, detail: String?) {
            self.stage = stage
            self.detail = detail
        }
    }

    public static func describe(_ error: Error) -> Description {
        if let channelError = error as? ChannelError {
            return describeChannelError(channelError)
        }
        if let connectionError = error as? NIOConnectionError {
            return describeConnectionError(connectionError)
        }
        if let ioError = error as? IOError {
            return Description(stage: .tcp, detail: describeErrno(ioError.errnoCode, target: nil))
        }
        return Description(stage: nil, detail: nil)
    }

    private static func describeChannelError(_ error: ChannelError) -> Description {
        switch error {
        case .connectTimeout(let amount):
            let seconds = Double(amount.nanoseconds) / 1_000_000_000
            let rendered = seconds >= 1 ? String(Int(seconds.rounded())) : String(format: "%.1f", seconds)
            return Description(stage: .tcp,
                               detail: L("在 ") + rendered + L(" 秒内没有建立 TCP 连接：目标端口无响应，通常是地址不可达、端口不对，或被防火墙/安全组静默丢弃了握手包"))
        case .eof:
            return Description(stage: .tcp, detail: L("连接刚建立就被对端关闭"))
        case .ioOnClosedChannel, .alreadyClosed, .inputClosed, .outputClosed:
            return Description(stage: .tcp, detail: L("连接已关闭"))
        case .connectPending:
            return Description(stage: .tcp, detail: L("上一次连接仍在建立中"))
        default:
            return Description(stage: .tcp, detail: L("底层网络操作失败（") + String(describing: error) + "）")
        }
    }

    private static func describeConnectionError(_ error: NIOConnectionError) -> Description {
        let target = error.host + ":" + String(error.port)
        if let dnsError = error.dnsAError ?? error.dnsAAAAError, error.connectionErrors.isEmpty {
            return Description(stage: .dns,
                               detail: L("无法解析主机名 ") + error.host + "（" + friendlyDNSMessage(dnsError) + "）")
        }
        if let failure = error.connectionErrors.first {
            let address = failure.target.description
            if let ioError = failure.error as? IOError {
                return Description(stage: .tcp, detail: describeErrno(ioError.errnoCode, target: address))
            }
            return Description(stage: .tcp, detail: L("无法连接 ") + target + "：" + String(describing: failure.error))
        }
        return Description(stage: .tcp, detail: L("无法连接 ") + target)
    }

    private static func friendlyDNSMessage(_ error: Error) -> String {
        if error is SocketAddressError.UnknownHost {
            return L("域名不存在，或当前网络的 DNS 无法解析该名称")
        }
        if let socketError = error as? SocketAddressError {
            switch socketError {
            case .unixDomainSocketPathTooLong:
                return L("地址路径过长")
            case .failedToParseIPString(let text):
                return L("IP 地址格式不正确（") + text + "）"
            default:
                break
            }
        }
        return String(describing: error)
    }

    /// errno values are stable on Darwin; the text explains what to check next.
    private static func describeErrno(_ code: Int32, target: String?) -> String {
        let where_ = target.map { " " + $0 } ?? ""
        switch code {
        case ECONNREFUSED:
            return L("连接被拒绝") + where_ + L("：端口上没有任何服务在监听（检查端口号，或目标机是否只允许通过跳板访问）")
        case EHOSTUNREACH:
            return L("目标主机不可达") + where_ + L("：路由或防火墙拦截了该地址")
        case ENETUNREACH:
            return L("网络不可达") + where_ + L("：当前网络到该网段没有路由，可能需要先连 VPN 或经跳板机转发")
        case ETIMEDOUT:
            return L("TCP 连接超时") + where_ + L("：目标没有响应，可能是防火墙静默丢包")
        case ECONNRESET:
            return L("连接被对端重置") + where_
        case EADDRNOTAVAIL:
            return L("本机无法使用该地址发起连接") + where_
        default:
            return L("TCP 连接失败") + where_ + "（errno " + String(code) + "：" + String(cString: strerror(code)) + "）"
        }
    }
}
