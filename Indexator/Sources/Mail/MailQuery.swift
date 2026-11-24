// SPDX-License-Identifier: GPL-3.0-or-later
//
// Turns the words of a mail query into FTS terms: drops filler words
// ("письмо от …", "найди") and cuts Russian endings, so "рекрутингового
// агентства" also finds "рекрутинговое агентство".

import Foundation

enum MailQuery {
    /// How far below the best meaning match an email may score and still count.
    static let semanticBand: Float = 0.035
    /// The same when the words were found too: meaning-only extras must be closer.
    static let semanticBandWithWords: Float = 0.02
    static let semanticLimit = 25

    static let stopWords: Set<String> = [
        // Russian filler and request words
        "письмо", "письма", "письме", "письмом", "писем", "почта", "почте", "почту", "сообщение",
        "найди", "найти", "покажи", "где", "мне", "мой", "моя", "моё", "мое", "мои", "моего", "моей",
        "от", "для", "про", "об", "обо", "все", "всё", "какое", "какой", "который", "которое",
        "это", "этот", "эта", "как", "что", "или", "его", "её", "ее", "их", "был", "была", "было",
        // English
        "email", "emails", "mail", "message", "from", "the", "and", "for", "about", "with", "find", "show", "my",
    ]

    /// FTS prefix terms, lowercased, without stop words, with endings cut.
    static func terms(from words: [String]) -> [String] {
        var seen = Set<String>()
        return words.compactMap { raw -> String? in
            let word = fold(raw.lowercased()).filter { $0.isLetter || $0.isNumber }
            guard !stopWords.contains(word) else { return nil }
            guard word.count >= 3 || (word.count == 2 && word.allSatisfy(\.isNumber)) else { return nil }
            let term = stem(word)
            return seen.insert(term).inserted ? term : nil
        }
    }

    /// "ё" → "е", so "счет" finds "счёт" and back.
    static func fold(_ text: String) -> String {
        text.replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "Ё", with: "Е")
    }

    /// Crude stemming for prefix search: long Cyrillic words lose their ending
    /// (1-3 letters), short ones stay whole. Latin words lose a plural "s" only.
    static func stem(_ word: String) -> String {
        let n = word.count
        if word.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil {
            if n >= 9 { return String(word.prefix(n - 3)) }
            if n >= 7 { return String(word.prefix(n - 2)) }
            if n >= 5 { return String(word.prefix(n - 1)) }
            return word
        }
        if n >= 5, word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }
}
