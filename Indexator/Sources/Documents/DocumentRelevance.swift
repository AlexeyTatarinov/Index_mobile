// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure helpers for document search precision and folder de-duplication.
// A document is shown when its text (or file name) contains most of the query's words;
// meaning-only matches are kept only when the model is very sure.

import Foundation

enum DocumentRelevance {
    /// e5 cosine a document needs to be shown without any of the query's words.
    /// Unrelated text sits around 0.78–0.83 with e5-small; real paraphrases land above this.
    static let semanticOnlyMinScore: Float = 0.86
    /// Meaning-only documents shown after the text matches, at most.
    static let semanticOnlyLimit = 3

    /// Query words as search stems: lowercased, stop words dropped, crude stemming.
    /// Two-letter words are kept ("CV", "ИП"), common short words are not.
    static func terms(_ query: String) -> [String] {
        var seen = Set<String>()
        return query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { $0.lowercased() }
            .filter { $0.count >= 2 && !DocumentStore.stopWords.contains($0) }
            .map { DocumentStore.stem($0) }
            .filter { seen.insert($0).inserted }
    }

    /// Words of a text, lowercased, for prefix checks.
    static func words(_ text: String) -> Set<Substring> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
    }

    /// Query terms with their synonyms (QuerySynonyms): a group is found when any of
    /// its stems starts a word of the text, so «резюме» counts in a file named "CV".
    static func termGroups(_ query: String) -> [[String]] {
        var seen = Set<String>()
        return query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { $0.lowercased() }
            .filter { $0.count >= 2 && !DocumentStore.stopWords.contains($0) }
            .compactMap { word -> [String]? in
                let term = DocumentStore.stem(word)
                guard seen.insert(term).inserted else { return nil }
                var group = [term]
                for alt in QuerySynonyms.alternatives(for: word) {
                    let t = DocumentStore.stem(QuerySynonyms.normalize(alt))
                    if t.count >= 2, !group.contains(t) { group.append(t) }
                }
                return group
            }
    }

    private static func found(_ group: [String], in words: Set<Substring>) -> Bool {
        group.contains { stem in words.contains { $0.hasPrefix(stem) } }
    }

    /// Fraction of terms that start some word of the text.
    static func coverage(terms: [String], in words: Set<Substring>) -> Double {
        coverage(groups: terms.map { [$0] }, in: words)
    }

    static func coverage(groups: [[String]], in words: Set<Substring>) -> Double {
        guard !groups.isEmpty else { return 0 }
        return Double(groups.filter { found($0, in: words) }.count) / Double(groups.count)
    }

    /// Whether enough of the query's words are in the text: all of them for up to
    /// four words, 80% for longer queries.
    static func isTextMatch(terms: [String], words: Set<Substring>) -> Bool {
        isTextMatch(groups: terms.map { [$0] }, words: words)
    }

    static func isTextMatch(groups: [[String]], words: Set<Substring>) -> Bool {
        guard !groups.isEmpty else { return false }
        // ceil(80%) in integers, so five words need exactly four.
        let needed = (groups.count * 4 + 4) / 5
        return groups.filter { found($0, in: words) }.count >= needed
    }

    // MARK: - Folders

    /// Comparable path: symlinks resolved, "/private" prefix and trailing slash dropped.
    static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// True when `path` is `folder` itself or lies anywhere inside it.
    static func isSameOrInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }
}
