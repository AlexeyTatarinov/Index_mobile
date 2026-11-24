// SPDX-License-Identifier: GPL-3.0-or-later
//
// Checks the Swift tokenizer and the Core ML e5 model against the PyTorch
// reference written by scripts/convert-e5.py (Models/e5_reference.json).

import XCTest
@testable import Indexator

final class TextEmbedderTests: XCTestCase {
    private struct Reference {
        let text: String
        let inputIds: [Int32]
        let embedding: [Float]
    }

    private func references() throws -> [Reference] {
        guard let url = Bundle.main.url(forResource: "e5_reference", withExtension: "json", subdirectory: "Models") else {
            throw XCTSkip("Models/e5_reference.json отсутствует, модель e5 не собрана")
        }
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try XCTUnwrap(root["items"] as? [[String: Any]])
        return try items.map { item -> Reference in
            let text = try XCTUnwrap(item["text"] as? String)
            let ids = try XCTUnwrap(item["input_ids"] as? [NSNumber]).map { $0.int32Value }
            let embedding = try XCTUnwrap(item["embedding"] as? [NSNumber]).map { $0.floatValue }
            return Reference(text: text, inputIds: ids, embedding: embedding)
        }
    }

    private func makeTokenizer() throws -> SentencePieceTokenizer {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "e5_tokenizer", withExtension: "json", subdirectory: "Models"))
        return try SentencePieceTokenizer(tokenizerJSON: url)
    }

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    func testTokenizerMatchesReference() throws {
        let refs = try references()
        let tokenizer = try makeTokenizer()
        for ref in refs {
            let ids = tokenizer.encode(ref.text, maxLength: TextEmbedder.sequenceLength)
            if ids != ref.inputIds {
                // Precompiled normalizer is approximated: allow one differing token at most.
                let differing = zip(ids, ref.inputIds).filter { $0.0 != $0.1 }.count + abs(ids.count - ref.inputIds.count)
                XCTAssertLessThanOrEqual(differing, 1, "\(ref.text): \(ids) != \(ref.inputIds)")
            }
        }
        // Plain text must match exactly.
        if let plain = refs.first(where: { $0.text == "query: tax deduction for apartment" }) {
            XCTAssertEqual(tokenizer.encode(plain.text, maxLength: TextEmbedder.sequenceLength), plain.inputIds)
        }
    }

    func testTokenizerTruncation() throws {
        _ = try references()
        let tokenizer = try makeTokenizer()
        let long = String(repeating: "налоговый вычет за квартиру ", count: 200)
        let ids = tokenizer.encode(long, maxLength: 256)
        XCTAssertEqual(ids.count, 256)
        XCTAssertEqual(ids.first, 0)
        XCTAssertEqual(ids.last, 2)
        XCTAssertEqual(tokenizer.encode("", maxLength: 256), [0, 2])
    }

    func testEmbeddingMatchesReference() throws {
        let refs = try references()
        let embedder = try TextEmbedder()
        for ref in refs {
            let vector = try embedder.embed(raw: ref.text)
            XCTAssertEqual(vector.count, embedder.dimension)
            let cosine = dot(vector, VectorMath.normalized(ref.embedding))
            XCTAssertGreaterThan(cosine, 0.97, ref.text)
        }
    }

    func testRussianSemantics() throws {
        _ = try references()
        let embedder = try TextEmbedder.shared()
        let query = try embedder.embed(query: "налоговый вычет за квартиру")
        let passages = try embedder.embed(passages: [
            "Заявление на имущественный налоговый вычет при покупке квартиры",
            "Рецепт борща со сметаной",
        ])
        XCTAssertGreaterThan(dot(query, passages[0]), dot(query, passages[1]))
    }
}
