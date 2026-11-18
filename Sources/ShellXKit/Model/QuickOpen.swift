import Foundation

/// Ranking for the quick-open panel (⌘K).
///
/// The panel has to answer "type a few letters, hit return, connect" with the
/// right machine on the first row. Substring matching alone put the best hit
/// wherever the sidebar happened to place it, so matching is scored instead:
/// an exact title beats a prefix, a prefix beats a word inside the address, and
/// a subsequence ("dbp" for "db-prod-01") still finds the host without drowning
/// the exact matches. Every whitespace separated token has to match somewhere,
/// which makes "prod db" work without the user knowing the stored name.
///
/// Pure and free of UI types so the ordering can be checked headlessly.
public enum QuickOpen {
    /// One searchable entry. `keywords` are pre-folded by the caller (group
    /// path, address, tags, pinyin…) and are matched less strongly than the
    /// title, so a group name never outranks a host that starts with the query.
    public struct Candidate: Sendable, Equatable {
        public var id: String
        public var title: String
        public var keywords: [String]
        /// Tie-breaker only: 0 for a cold entry, higher for a recently used
        /// machine. It never lifts a weaker match class above a stronger one.
        public var weight: Int

        public init(id: String, title: String, keywords: [String] = [], weight: Int = 0) {
            self.id = id
            self.title = title
            self.keywords = keywords
            self.weight = weight
        }
    }

    public struct Match: Sendable, Equatable {
        public var candidate: Candidate
        public var score: Int

        public init(candidate: Candidate, score: Int) {
            self.candidate = candidate
            self.score = score
        }
    }

    /// Split on whitespace; an all-space query yields no tokens and therefore
    /// "everything, in the caller's order".
    public static func tokens(_ query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace })
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    public static func rank(_ candidates: [Candidate], query: String) -> [Match] {
        let tokens = tokens(query)
        guard !tokens.isEmpty else {
            return candidates.map { Match(candidate: $0, score: 0) }
        }
        var scored: [(index: Int, match: Match)] = []
        for (index, candidate) in candidates.enumerated() {
            var total = 0
            var matched = true
            for token in tokens {
                guard let score = tokenScore(token, title: candidate.title, keywords: candidate.keywords) else {
                    matched = false
                    break
                }
                total += score
            }
            if matched {
                scored.append((index, Match(candidate: candidate, score: total)))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.match.score != rhs.match.score { return lhs.match.score > rhs.match.score }
            if lhs.match.candidate.weight != rhs.match.candidate.weight {
                return lhs.match.candidate.weight > rhs.match.candidate.weight
            }
            return lhs.index < rhs.index
        }
        return scored.map(\.match)
    }

    /// Best score for one token across the title and the keywords, or nil when
    /// no field matches it.
    public static func tokenScore(_ token: String, title: String, keywords: [String]) -> Int? {
        var best: Int?
        if let score = fieldScore(token, in: normalize(title), weight: 2) { best = score }
        for keyword in keywords {
            let field = normalize(keyword)
            guard !field.isEmpty else { continue }
            if let score = fieldScore(token, in: field, weight: 1) {
                best = max(best ?? score, score)
            }
        }
        return best
    }

    /// Score of one already-folded token inside one already-folded field.
    static func fieldScore(_ token: String, in field: String, weight: Int) -> Int? {
        if field == token { return 1_000 * weight }
        if field.hasPrefix(token) { return 700 * weight }
        if let range = field.range(of: token) {
            let distance = field.distance(from: field.startIndex, to: range.lowerBound)
            let boundary = isWordBoundary(before: range.lowerBound, in: field)
            let base = boundary ? 520 : 320
            return max(base - min(distance, 60), 100) * weight
        }
        // A two letter token matches far too much as a subsequence — "db" hides
        // inside "prod-web" — so the last-chance match needs three letters.
        if token.count >= 3, isSubsequence(token, of: field) { return 60 * weight }
        return nil
    }

    /// True when the character before `index` separates words, or when the match
    /// starts the field. "prod" matching "db-prod-01" and "team/prod" counts as a
    /// word start; matching inside "reproduce" does not.
    static func isWordBoundary(before index: String.Index, in field: String) -> Bool {
        guard index > field.startIndex else { return true }
        let previous = field[field.index(before: index)]
        return previous.isWhitespace || " /._-@:,(+".contains(previous)
    }

    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var cursor = needle.startIndex
        for character in haystack {
            guard cursor < needle.endIndex else { break }
            if character == needle[cursor] { cursor = needle.index(after: cursor) }
        }
        return cursor == needle.endIndex
    }

    /// Case and diacritic folding, so "München" matches "munchen" and a Turkish
    /// dotted i does not split a match.
    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
    }
}
