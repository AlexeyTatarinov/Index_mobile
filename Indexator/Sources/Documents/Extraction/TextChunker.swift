// SPDX-License-Identifier: GPL-3.0-or-later
//
// Splits extracted document text into overlapping chunks for embedding,
// and builds short result snippets around matched words.

import Foundation

struct TextChunk: Equatable {
    let page: Int?
    let text: String
}

enum TextChunker {
    /// Chunks with fewer letters than this (page numbers, separators) are dropped.
    static let minLetters = 15

    /// Chunks are at most `targetChars` long (except a single word longer than that),
    /// never cross pages and never cut a word. Consecutive chunks of one page share
    /// a tail of about `overlapChars`.
    static func chunks(
        from pages: [ExtractedPage],
        targetChars: Int = 900,
        overlapChars: Int = 150,
        maxChunks: Int = 4000
    ) -> [TextChunk] {
        guard maxChunks > 0 else { return [] }
        let target = max(40, targetChars)
        let overlap = max(0, min(overlapChars, target / 3))
        // Room for "overlap + separator + piece" so a new chunk still fits into target.
        let pieceLimit = target - overlap - 2
        // No need to normalize more text than can ever become chunks.
        let pageCharLimit = Int(min(Double(maxChunks) * Double(target) * 2, 1_000_000_000))

        var result: [TextChunk] = []
        for page in pages {
            let raw = page.text.count > pageCharLimit ? String(page.text.prefix(pageCharLimit)) : page.text
            let text = normalize(raw)
            if text.isEmpty { continue }

            var pieces: [(text: String, newParagraph: Bool)] = []
            for paragraph in text.components(separatedBy: "\n\n") {
                let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                for (i, piece) in split(trimmed, limit: pieceLimit).enumerated() {
                    pieces.append((text: piece, newParagraph: i == 0))
                }
            }

            var current = ""
            var currentLength = 0
            for piece in pieces {
                let length = piece.text.count
                if currentLength == 0 {
                    current = piece.text
                    currentLength = length
                    continue
                }
                let separator = piece.newParagraph ? "\n\n" : " "
                if currentLength + separator.count + length <= target {
                    current += separator + piece.text
                    currentLength += separator.count + length
                    continue
                }
                appendChunk(current, page: page.number, to: &result)
                if result.count >= maxChunks { return result }
                let tail = overlapTail(of: current, maxChars: overlap)
                if tail.isEmpty {
                    current = piece.text
                    currentLength = length
                } else {
                    current = tail + " " + piece.text
                    currentLength = tail.count + 1 + length
                }
            }
            if currentLength > 0 {
                appendChunk(current, page: page.number, to: &result)
                if result.count >= maxChunks { return result }
            }
        }
        return result
    }

    private static func appendChunk(_ text: String, page: Int?, to result: inout [TextChunk]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var letters = 0
        for c in trimmed where c.isLetter {
            letters += 1
            if letters >= minLetters { break }
        }
        if letters >= minLetters {
            result.append(TextChunk(page: page, text: trimmed))
        }
    }

    // MARK: - Normalization

    /// Collapses runs of spaces/tabs, trims spaces around newlines, 3+ newlines → 2.
    static func normalize(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        s = replacing(s, "[ \\t\\f\\x0B\\u00A0\\u2000-\\u200A\\u202F\\u205F\\u3000]+", with: " ")
        s = replacing(s, " ?\\n ?", with: "\n")
        s = replacing(s, "\\n{3,}", with: "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(_ s: String, _ pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        return regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    // MARK: - Splitting

    /// Splits a paragraph into pieces of at most `limit` characters:
    /// at sentence boundaries first, then at word boundaries.
    static func split(_ paragraph: String, limit: Int) -> [String] {
        if paragraph.count <= limit { return [paragraph] }
        var units: [String] = []
        for sentence in sentences(paragraph) {
            if sentence.count <= limit {
                units.append(sentence)
            } else {
                units += words(sentence, limit: limit)
            }
        }
        return pack(units, limit: limit)
    }

    /// Sentences end at ". ", "! ", "? ", "… " (terminator followed by whitespace) or a newline.
    static func sentences(_ text: String) -> [String] {
        let chars = Array(text)
        var result: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
            current = ""
        }
        for (i, c) in chars.enumerated() {
            if c == "\n" {
                flush()
                continue
            }
            current.append(c)
            if c == "." || c == "!" || c == "?" || c == "…" {
                if i + 1 == chars.count || chars[i + 1].isWhitespace { flush() }
            }
        }
        flush()
        return result
    }

    /// Word-level split; a single word longer than `limit` is the only thing ever hard-cut.
    private static func words(_ text: String, limit: Int) -> [String] {
        var units: [String] = []
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            if word.count <= limit {
                units.append(String(word))
            } else {
                var rest = Substring(word)
                while !rest.isEmpty {
                    units.append(String(rest.prefix(limit)))
                    rest = rest.dropFirst(limit)
                }
            }
        }
        return pack(units, limit: limit)
    }

    private static func pack(_ units: [String], limit: Int) -> [String] {
        var result: [String] = []
        var current = ""
        var length = 0
        for unit in units {
            let n = unit.count
            if length == 0 {
                current = unit
                length = n
            } else if length + 1 + n <= limit {
                current += " " + unit
                length += 1 + n
            } else {
                result.append(current)
                current = unit
                length = n
            }
        }
        if length > 0 { result.append(current) }
        return result
    }

    /// The last ~`maxChars` characters of `text`, starting at a word boundary.
    static func overlapTail(of text: String, maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        let chars = Array(text)
        if chars.count <= maxChars {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var start = chars.count - maxChars
        if !chars[start - 1].isWhitespace {
            while start < chars.count && !chars[start].isWhitespace { start += 1 }
        }
        while start < chars.count && chars[start].isWhitespace { start += 1 }
        guard start < chars.count else { return "" }
        return String(chars[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Snippets

    /// A window of `text` around the first occurrence of any of `words` (length >= 3,
    /// case-insensitive, matching a word or its beginning: "налог" finds "налоговый").
    /// Cut ends get "…". Without a match, returns the beginning of the text.
    static func snippet(of text: String, around words: [String], maxChars: Int = 220) -> String {
        let flat = replacing(text, "\\s+", with: " ").trimmingCharacters(in: .whitespaces)
        let chars = Array(flat)
        let limit = max(20, maxChars)
        guard chars.count > limit else { return flat }

        var hit: Int?
        for word in words {
            let needle = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard needle.count >= 3, let offset = firstWordStart(of: needle, in: flat) else { continue }
            if hit == nil || offset < hit! { hit = offset }
        }

        var start = hit.map { max(0, $0 - limit / 3) } ?? 0
        var end = min(chars.count, start + limit)
        start = max(0, end - limit)
        let rawStart = start
        let rawEnd = end

        // Move both edges to word boundaries, never past the matched word.
        if start > 0 && !chars[start - 1].isWhitespace {
            let stop = min(end, hit ?? end)
            while start < stop && !chars[start].isWhitespace { start += 1 }
        }
        if end < chars.count && !chars[end].isWhitespace {
            let minEnd = max(start, hit ?? start)
            while end > minEnd && !chars[end - 1].isWhitespace { end -= 1 }
        }
        if end <= start {
            start = rawStart
            end = rawEnd
        }

        var result = String(chars[start..<end]).trimmingCharacters(in: .whitespaces)
        if start > 0 { result = "…" + result }
        if end < chars.count { result += "…" }
        return result
    }

    /// Character offset of the first match of `word` that starts a word.
    private static func firstWordStart(of word: String, in text: String) -> Int? {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: word, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            if range.lowerBound == text.startIndex || !isWordCharacter(text[text.index(before: range.lowerBound)]) {
                return text.distance(from: text.startIndex, to: range.lowerBound)
            }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }
}
