import Foundation
import ShellXKit

/// Checks for the ranking behind the ⌘K quick-open panel: the panel is only as
/// good as the order it puts results in, so these cover the scoring tiers, the
/// multi-token rule and the stability of ties.
func runQuickOpenChecks() {
    func candidate(_ id: String, _ title: String, keywords: [String] = [], weight: Int = 0) -> QuickOpen.Candidate {
        QuickOpen.Candidate(id: id, title: title, keywords: keywords, weight: weight)
    }

    let hosts = [
        candidate("host-db", "prod-db-01", keywords: ["10.0.0.5", "db"]),
        candidate("host-web", "prod-web-01", keywords: ["10.0.0.6", "web"]),
        candidate("board-1", "生产环境", keywords: ["prod-db-01", "prod-web-01"]),
        candidate("host-dev", "staging box", keywords: ["dev", "db"]),
    ]

    run("quickOpen exact match beats prefix beats substring") {
        let ranked = QuickOpen.rank(hosts, query: "prod-db-01").map(\.candidate.id)
        expectEqual(ranked.first, "host-db", "the exactly matching title wins")
        expect(ranked.contains("board-1"), "a workspace whose keywords contain the title also matches")
        expect(!ranked.contains("host-dev"), "unrelated entries stay out")
    }

    run("quickOpen prefix outranks a mid-word substring") {
        let ranked = QuickOpen.rank(hosts, query: "prod").map(\.candidate.id)
        expectEqual(Array(ranked.prefix(2)), ["host-db", "host-web"], "both prod hosts rank first, in list order")
        expect(ranked.contains("board-1"), "the workspace that only mentions prod hosts ranks later")
    }

    run("quickOpen every token has to match") {
        let ranked = QuickOpen.rank(hosts, query: "prod db").map(\.candidate.id)
        expect(ranked.contains("host-db"), "the title has prod and the keyword has db")
        expect(!ranked.contains("host-web"), "prod-web has no db")
        expectEqual(QuickOpen.rank(hosts, query: "prod nothing-here").count, 0, "one unmatched token empties the list")
    }

    run("quickOpen ignores case and diacritics") {
        expectEqual(QuickOpen.rank(hosts, query: "STAGING").map(\.candidate.id), ["host-dev"], "case is folded")
        let accented = [candidate("host-accent", "Café Server")]
        expectEqual(QuickOpen.rank(accented, query: "cafe").count, 1, "diacritics are folded away")
    }

    run("quickOpen matches CJK substrings") {
        expectEqual(QuickOpen.rank(hosts, query: "生产").map(\.candidate.id), ["board-1"], "Chinese titles match by substring")
    }

    run("quickOpen empty query keeps the original order") {
        expectEqual(QuickOpen.rank(hosts, query: "").map(\.candidate.id),
                    hosts.map(\.id), "an empty query is not a filter")
        expectEqual(QuickOpen.rank(hosts, query: "   ").map(\.candidate.id),
                    hosts.map(\.id), "a blank query is not a filter either")
    }

    run("quickOpen weight only breaks ties") {
        let tied = [candidate("a", "same", weight: 0), candidate("b", "same", weight: 50)]
        expectEqual(QuickOpen.rank(tied, query: "same").map(\.candidate.id), ["b", "a"],
                    "equal scores fall back to recent use")
        let scored = [candidate("a", "same", weight: 0), candidate("b", "same-host", weight: 500)]
        expectEqual(QuickOpen.rank(scored, query: "same").map(\.candidate.id), ["a", "b"],
                    "a better text match still wins over a heavier weight")
    }

    run("quickOpen keeps the input order for full ties") {
        let tied = (0 ..< 5).map { candidate("id-\($0)", "tie") }
        expectEqual(QuickOpen.rank(tied, query: "tie").map(\.candidate.id),
                    tied.map(\.id), "identical matches do not shuffle")
    }

    run("quickOpen returns nothing when nothing matches") {
        expectEqual(QuickOpen.rank(hosts, query: "zzzz").count, 0, "no partial or fuzzy hit for a nonsense query")
        expectEqual(QuickOpen.rank([], query: "prod").count, 0, "an empty candidate list stays empty")
    }

    run("quickOpen tokenises on whitespace") {
        expectEqual(QuickOpen.tokens("  Prod   DB "), ["prod", "db"], "tokens are trimmed, folded and lowercased")
        expectEqual(QuickOpen.tokens("   ").count, 0, "a blank query has no tokens")
    }
}
