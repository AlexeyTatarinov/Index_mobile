// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Indexator

/// Compares the Swift tokenizer with token ids that the Python tokenizer produced
/// during model conversion (Models/mclip_b32_tokens.json).
final class WordPieceTokenizerTests: XCTestCase {
    private struct Expected: Decodable {
        struct Sample: Decodable { let text: String; let ids: [Int32] }
        let max_length: Int
        let samples: [Sample]
    }

    func testMatchesPythonTokenizer() throws {
        let bundle = Bundle.main
        guard
            let vocab = bundle.url(forResource: "\(ClipModel.variant)_vocab", withExtension: "txt", subdirectory: "Models"),
            let json = bundle.url(forResource: "\(ClipModel.variant)_tokens", withExtension: "json", subdirectory: "Models")
        else {
            throw XCTSkip("model files are not bundled")
        }
        let expected = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: json))
        let tokenizer = try WordPieceTokenizer(vocabURL: vocab, maxLength: expected.max_length)
        for sample in expected.samples {
            XCTAssertEqual(tokenizer.encode(sample.text).ids, sample.ids, sample.text)
        }
    }

    func testBasicSplit() {
        let words = WordPieceTokenizer.basicTokens("Счёт, март!").map { String(String.UnicodeScalarView($0)) }
        XCTAssertEqual(words, ["Счёт", ",", "март", "!"])
    }

    func testPrompt() {
        XCTAssertEqual(SearchEngine.prompt(for: "parrot"), "a photo of parrot")
        XCTAssertEqual(SearchEngine.prompt(for: "попугай"), "попугай")
    }
}
