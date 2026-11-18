import Foundation
import NIOCore
import NIOSSH

/// The credential material used for a single SSH hop.
public enum SSHAuthMaterial: Sendable {
    case password(String)
    case privateKey(NIOSSHPrivateKey)
    case none

    public var methodDescription: String {
        switch self {
        case .password: return "密码"
        case .privateKey: return "公钥"
        case .none: return "无认证"
        }
    }
}

/// Supplies authentication offers in order, matching what the server advertises.
final class SSHAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private var offers: [NIOSSHUserAuthenticationOffer.Offer]
    private let lock = NSLock()
    private var exhausted = false

    /// True once every configured offer was rejected by the server, which means
    /// the server refused the credentials rather than stalling the handshake.
    var didExhaustOffers: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exhausted
    }

    init(username: String, offers: [NIOSSHUserAuthenticationOffer.Offer]) {
        self.username = username
        self.offers = offers
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        lock.lock()
        var selected: NIOSSHUserAuthenticationOffer.Offer?
        for (index, offer) in offers.enumerated() {
            let compatible: Bool
            switch offer {
            case .password:
                compatible = availableMethods.contains(.password)
            case .privateKey:
                compatible = availableMethods.contains(.publicKey)
            case .none:
                compatible = true
            case .hostBased:
                compatible = false
            }
            if compatible {
                selected = offer
                offers.remove(at: index)
                break
            }
        }
        if selected == nil {
            exhausted = true
        }
        lock.unlock()

        guard let selected else {
            nextChallengePromise.succeed(nil)
            return
        }
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username,
                                                                   serviceName: "ssh-connection",
                                                                   offer: selected))
    }
}
