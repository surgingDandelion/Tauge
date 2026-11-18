#if !SWIFTTERM_EMBEDDED
/// Stand-in for the build-plugin generated terminfo table. The XTGETTCAP
/// answers are optional: an empty table only means xterm capability queries
/// go unanswered, and clients fall back to TERM/terminfo.
enum SwiftTermTerminfo {
    static let xtgettcapReplies: [String: String] = [:]
}

enum SwiftTermBuildInfo {
    static let tag = "v1.99.3"
    static let branch = "vendor"
    static let version = "1.99.3"
}
#endif
