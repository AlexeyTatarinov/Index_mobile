// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Indexator

final class TextChunkerTests: XCTestCase {
    private let vocabulary = [
        "договор", "аренды", "квартиры", "арендатор", "обязуется", "вносить", "плату",
        "ежемесячно", "налоговый", "вычет", "документы", "подтверждающие", "расходы",
        "собственник", "передаёт", "помещение", "состоянии", "пригодном", "проживания",
    ]

    /// Deterministic Russian prose built only from `vocabulary`.
    private func makeText(sentences: Int, seed: Int = 0, terminators: Bool = true) -> String {
        var out: [String] = []
        for i in 0..<sentences {
            let length = 6 + (i * 7 + seed) % 9
            var words: [String] = []
            for j in 0..<length {
                words.append(vocabulary[(i * 31 + j * 17 + seed) % vocabulary.count])
            }
            let sentence = words.joined(separator: " ")
            if terminators {
                out.append(String(sentence.prefix(1)).uppercased() + String(sentence.dropFirst()) + ".")
            } else {
                out.append(sentence)
            }
        }
        return out.joined(separator: " ")
    }

    private func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".…")).lowercased() }
            .filter { !$0.isEmpty }
    }

    func testShortTextIsSingleChunk() {
        let text = "Договор аренды квартиры на два года."
        let chunks = TextChunker.chunks(from: [ExtractedPage(number: nil, text: text)])
        XCTAssertEqual(chunks, [TextChunk(page: nil, text: text)])
    }

    func testChunksRespectTargetSize() {
        let page = ExtractedPage(number: 1, text: makeText(sentences: 200))
        let chunks = TextChunker.chunks(from: [page], targetChars: 300, overlapChars: 60)
        XCTAssertGreaterThan(chunks.count, 5)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.text.count, 300)
        }
        for chunk in chunks.dropLast() {
            XCTAssertGreaterThan(chunk.text.count, 100, "Chunks should be reasonably filled")
        }
    }

    func testNoMidWordCuts() {
        let known = Set(vocabulary)
        let pages = [
            // Sentences, several paragraphs.
            ExtractedPage(number: 1, text: makeText(sentences: 40) + "\n\n" + makeText(sentences: 30, seed: 3)),
            // One huge paragraph without sentence ends: forces word-level splitting.
            ExtractedPage(number: 2, text: makeText(sentences: 60, seed: 5, terminators: false)),
        ]
        let chunks = TextChunker.chunks(from: pages, targetChars: 250, overlapChars: 50)
        XCTAssertGreaterThan(chunks.count, 10)
        for chunk in chunks {
            for token in tokens(chunk.text) {
                XCTAssertTrue(known.contains(token), "Cut word «\(token)» in chunk: \(chunk.text)")
            }
        }
    }

    func testConsecutiveChunksOverlap() {
        let page = ExtractedPage(number: 1, text: makeText(sentences: 120))
        let chunks = TextChunker.chunks(from: [page], targetChars: 300, overlapChars: 80)
        XCTAssertGreaterThan(chunks.count, 3)
        for (prev, next) in zip(chunks, chunks.dropFirst()) {
            // Some word-aligned prefix of `next` (>= 20 chars) must be a suffix of `prev`.
            let chars = Array(next.text)
            var found = false
            let upper = min(chars.count, 120)
            XCTAssertGreaterThan(upper, 20)
            for k in 20..<max(upper, 20) where chars[k] == " " {
                if prev.text.hasSuffix(String(chars[0..<k])) {
                    found = true
                    break
                }
            }
            XCTAssertTrue(found, "No overlap between:\n\(prev.text)\n---\n\(next.text)")
        }
    }

    func testPagesAreKeptAndNotMixed() {
        let first = String(repeating: "Кошка спит на тёплом диване весь день. ", count: 30)
        let second = String(repeating: "Собака гуляет в парке под дождём. ", count: 30)
        let chunks = TextChunker.chunks(
            from: [ExtractedPage(number: 1, text: first), ExtractedPage(number: 2, text: second)],
            targetChars: 200,
            overlapChars: 50
        )
        let pageNumbers = chunks.map(\.page)
        XCTAssertEqual(pageNumbers.first, 1)
        XCTAssertEqual(pageNumbers.last, 2)
        XCTAssertEqual(pageNumbers, pageNumbers.sorted { ($0 ?? 0) < ($1 ?? 0) })
        for chunk in chunks {
            if chunk.page == 1 {
                XCTAssertFalse(chunk.text.contains("Собака"))
            } else {
                XCTAssertEqual(chunk.page, 2)
                XCTAssertFalse(chunk.text.contains("Кошка"))
            }
        }
    }

    func testTinyChunksAreSkipped() {
        let pages = [
            ExtractedPage(number: 1, text: "12"),
            ExtractedPage(number: 2, text: "— 3 —"),
            ExtractedPage(number: 3, text: "Короткий"),
            ExtractedPage(number: 4, text: "Это нормальная страница с текстом."),
        ]
        let chunks = TextChunker.chunks(from: pages)
        XCTAssertEqual(chunks.map(\.page), [4])
    }

    func testWhitespaceIsNormalized() {
        let text = "  Привет,\t\t  мир.  \r\n\n\n\n  Второй   абзац здесь, English too.  "
        let chunks = TextChunker.chunks(from: [ExtractedPage(number: nil, text: text)])
        XCTAssertEqual(chunks.map(\.text), ["Привет, мир.\n\nВторой абзац здесь, English too."])
    }

    func testMaxChunksLimit() {
        let page = ExtractedPage(number: 1, text: makeText(sentences: 300))
        let chunks = TextChunker.chunks(from: [page], targetChars: 200, overlapChars: 40, maxChunks: 5)
        XCTAssertEqual(chunks.count, 5)
    }

    // MARK: - Snippets

    private let longText =
        String(repeating: "Вступительный текст без ключевых слов. ", count: 10)
        + "Здесь упоминается налоговый вычет за лечение зубов. "
        + String(repeating: "Заключительные слова документа. ", count: 10)

    func testSnippetAroundPrefixMatch() {
        let snippet = TextChunker.snippet(of: longText, around: ["налог"])
        XCTAssertTrue(snippet.contains("налоговый вычет"))
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertLessThanOrEqual(snippet.count, 222)

        // Whole words only at the edges.
        let known = Set(tokens(longText).map { $0.trimmingCharacters(in: .punctuationCharacters) })
        for token in tokens(snippet) {
            XCTAssertTrue(known.contains(token.trimmingCharacters(in: .punctuationCharacters)), token)
        }
    }

    func testSnippetIsCaseInsensitive() {
        let snippet = TextChunker.snippet(of: longText, around: ["НАЛОГ"])
        XCTAssertTrue(snippet.contains("налоговый"))
    }

    func testSnippetMatchesOnlyWordStarts() {
        // "лог" occurs inside "налоговый" but does not start a word.
        let snippet = TextChunker.snippet(of: longText, around: ["лог"])
        XCTAssertTrue(snippet.hasPrefix("Вступительный"))
        XCTAssertFalse(snippet.contains("налоговый"))
    }

    func testSnippetIgnoresShortWordsAndFallsBackToStart() {
        let snippet = TextChunker.snippet(of: longText, around: ["за", "x"])
        XCTAssertTrue(snippet.hasPrefix("Вступительный"))
        XCTAssertFalse(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("…"))
    }

    func testShortTextSnippetIsWholeText() {
        let snippet = TextChunker.snippet(of: "Налоговый\n\nвычет   за лечение", around: ["вычет"])
        XCTAssertEqual(snippet, "Налоговый вычет за лечение")
    }
}
