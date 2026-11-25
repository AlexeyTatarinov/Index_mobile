// SPDX-License-Identifier: GPL-3.0-or-later
//
// The app learns from the user, on the phone only:
// - «Подходит» / «Не подходит» on a result: for the same query (same words, any order
//   or ending) a liked result goes first and a rejected one is hidden.
// - Voice fixes: words dictation keeps getting wrong («Сири» for "CV"), built-in ones
//   plus the ones learned when the user corrects the heard text before searching.
// - Synonyms the user adds (QuerySynonyms).
// Everything lives in UserDefaults and can be cleared in Settings → Обучение поиска.

import Foundation

@MainActor
final class SearchLearning: ObservableObject {
    static let shared = SearchLearning()

    /// Query key → result key ("photo:<id>") → +1 liked, -1 rejected.
    @Published private(set) var marks: [String: [String: Int]] = [:]
    /// The query whose results are on screen; menus mark results for it.
    var currentQuery = ""

    private let defaultsKey = "learn.feedback"

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([String: [String: Int]].self, from: data) {
            marks = saved
        }
    }

    /// Same key for «природа», «природы» and «Природа видео».
    nonisolated static func queryKey(_ query: String) -> String {
        let words = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !SearchEngine.isMediaWord($0) && !DocumentStore.stopWords.contains($0.lowercased()) }
            .map(QuerySynonyms.key)
            .filter { !$0.isEmpty }
        return Set(words).sorted().joined(separator: " ")
    }

    nonisolated static func itemKey(_ item: ResultItem) -> String { item.kind.rawValue + ":" + item.id }

    var count: Int { marks.values.reduce(0) { $0 + $1.count } }

    func mark(_ item: ResultItem, good: Bool?) {
        let key = Self.queryKey(currentQuery)
        guard !key.isEmpty else { return }
        var forQuery = marks[key] ?? [:]
        if let good {
            forQuery[Self.itemKey(item)] = good ? 1 : -1
        } else {
            forQuery[Self.itemKey(item)] = nil
        }
        marks[key] = forQuery.isEmpty ? nil : forQuery
        save()
        AppLog.shared.add("Обучение: «\(currentQuery)» — \(good.map { $0 ? "подходит" : "не подходит" } ?? "сброс") (\(item.kind.rawValue))")
    }

    func mark(kind: ResultItem.Kind, id: String, good: Bool?) {
        mark(ResultItem(id: id, kind: kind, title: ""), good: good)
    }

    func state(kind: ResultItem.Kind, id: String) -> Int? {
        marks[Self.queryKey(currentQuery)]?[kind.rawValue + ":" + id]
    }

    /// Rejected results out, liked ones first (photos liked earlier come back even
    /// when the search itself did not find them this time).
    func apply(to items: [ResultItem], query: String, extraPhotos: (String) -> ResultItem) -> [ResultItem] {
        guard let forQuery = marks[Self.queryKey(query)], !forQuery.isEmpty else { return items }
        let kept = items.filter { forQuery[Self.itemKey($0)] != -1 }
        let present = Set(kept.map(Self.itemKey))
        let missingLiked = forQuery.filter { $0.value == 1 && !present.contains($0.key) && $0.key.hasPrefix("photo:") }
            .keys.sorted()
            .map { extraPhotos(String($0.dropFirst("photo:".count))) }
        let liked = kept.filter { forQuery[Self.itemKey($0)] == 1 }
        let rest = kept.filter { forQuery[Self.itemKey($0)] != 1 }
        return liked + missingLiked + rest
    }

    func reset() {
        marks = [:]
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(marks) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

/// Words dictation gets wrong, replaced before the text reaches the search field.
enum VoiceFixes {
    static let enabledKey = "learn.voiceFixesOn"
    static let learnedKey = "learn.voiceFixes"

    /// Russian dictation hears English words as Russian ones: "CV" comes out as «Сири».
    static let builtIn: [(String, String)] = [
        ("сири", "CV"), ("siri", "CV"), ("си ви", "CV"), ("си-ви", "CV"), ("сиви", "CV"),
        ("резюмэ", "резюме"),
        ("пдф", "PDF"), ("пи ди эф", "PDF"), ("пэдээф", "PDF"),
        ("джимейл", "Gmail"), ("гмейл", "Gmail"), ("джи мейл", "Gmail"), ("жмейл", "Gmail"),
        ("эксель", "Excel"), ("ексель", "Excel"), ("айклауд", "iCloud"), ("ай клауд", "iCloud"),
        ("вотсап", "WhatsApp"), ("ватсап", "WhatsApp"), ("букинг", "Booking"),
        ("инвойс", "invoice"),
    ]

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var learned: [String: String] {
        UserDefaults.standard.dictionary(forKey: learnedKey) as? [String: String] ?? [:]
    }

    static func setLearned(_ fixes: [String: String]) {
        UserDefaults.standard.set(fixes, forKey: learnedKey)
    }

    /// Replaces whole words and phrases, ignoring case. Learned fixes go first.
    static func apply(_ text: String) -> String {
        guard isEnabled, !text.isEmpty else { return text }
        var result = text
        let fixes = learned.map { ($0.key, $0.value) }.sorted { $0.0.count > $1.0.count } + builtIn
        for (heard, meant) in fixes {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: heard) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: meant))
        }
        return result
    }

    /// The user fixed the dictated text before searching. Words that changed script
    /// («сиви» → "CV") or were slightly misheard are remembered for next time; a different
    /// query typed over the dictation is not (too many words changed, or unrelated words).
    static func learn(heard: String, sent: String) {
        let a = heard.split(separator: " ").map(String.init)
        let b = sent.split(separator: " ").map(String.init)
        guard a.count == b.count, !a.isEmpty else { return }
        let pairs = zip(a, b).filter { $0.0.lowercased() != $0.1.lowercased() }
        guard !pairs.isEmpty, pairs.count <= 2 else { return }
        var fixes = learned
        for (h, s) in pairs {
            let hw = h.lowercased().filter { $0.isLetter || $0.isNumber }
            let sw = s.filter { $0.isLetter || $0.isNumber || $0 == "-" }
            guard !hw.isEmpty, !sw.isEmpty else { continue }
            let crossScript = isCyrillic(hw) != isCyrillic(sw.lowercased())
            let close = hw.count >= 4 && distance(hw, sw.lowercased()) <= 2
            if crossScript || close {
                fixes[hw] = sw
                AppLog.shared.add("Голос: запомнил «\(hw)» → «\(sw)»")
            }
        }
        setLearned(fixes)
    }

    static func isCyrillic(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[y.count]
    }
}
