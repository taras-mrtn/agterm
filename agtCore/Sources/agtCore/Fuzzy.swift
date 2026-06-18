import Foundation

/// Scores how well `query` matches `target` for the command palettes — lower is a better
/// match, `nil` means no match. Tiers: an exact prefix is `0`; a substring is `5 +` the
/// offset where it starts; a scattered subsequence is `40 +` the length gap. An empty query
/// matches everything at `0` (so the unfiltered list keeps its natural order). Case-insensitive.
public func fuzzyScore(query: String, target: String) -> Int? {
    let q = query.lowercased()
    let t = target.lowercased()
    guard !q.isEmpty else { return 0 }
    if t.hasPrefix(q) { return 0 }
    if let range = t.range(of: q) {
        return 5 + t.distance(from: t.startIndex, to: range.lowerBound)
    }
    // subsequence: every query char appears in order, not necessarily adjacent.
    var qi = q.startIndex
    for ch in t where ch == q[qi] {
        qi = q.index(after: qi)
        if qi == q.endIndex { return 40 + (t.count - q.count) }
    }
    return nil
}
