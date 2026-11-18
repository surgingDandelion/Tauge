import Foundation

/// "Proxy or jump chain, not both."
///
/// Both describe how to leave this machine towards the first hop, and combining
/// them silently means the jump chain also has to tunnel through the proxy
/// (which the system-ssh transport cannot express at all). Rather than encode
/// that ambiguity, the editor keeps exactly one of the two active: picking a
/// concrete proxy clears the jump chain, and picking jump hosts clears the proxy.
public enum RouteRules {
    public static func isProxyActive(_ policy: ProxyPolicy) -> Bool {
        if case .use = policy { return true }
        return false
    }

    /// A jump chain only counts when it actually lists hosts; `.hosts([])` is the
    /// transient state while the user is still picking the first one.
    public static func isJumpActive(_ policy: JumpPolicy) -> Bool {
        if case .hosts(let ids) = policy { return !ids.isEmpty }
        return false
    }

    public static func jumpPolicy(afterSelectingProxy proxy: ProxyPolicy,
                                  current: JumpPolicy) -> JumpPolicy {
        isProxyActive(proxy) ? .direct : current
    }

    public static func proxyPolicy(afterSelectingJump jump: JumpPolicy,
                                   current: ProxyPolicy) -> ProxyPolicy {
        isJumpActive(jump) ? .direct : current
    }

    /// Enforces the rule at save time, in case a host was imported or edited
    /// through another path: the proxy wins because it is the more specific
    /// choice (and the one the system-ssh transport can still honour).
    public static func normalized(proxy: ProxyPolicy,
                                  jump: JumpPolicy) -> (proxy: ProxyPolicy, jump: JumpPolicy) {
        if isProxyActive(proxy), isJumpActive(jump) {
            return (proxy, .direct)
        }
        return (proxy, jump)
    }
}
