// SPDX-License-Identifier: GPL-3.0-or-later
//
// Unigram (SentencePiece) tokenizer for XLM-R style vocabularies, read from a
// Hugging Face `tokenizer.json`. Mirrors the HF fast tokenizer:
// normalizer (Precompiled nmt_nfkc, approximated by NFKC + whitespace cleanup),
// Metaspace pre-tokenizer ("▁", prepended, split per word), Viterbi with a fused
// <unk> fallback, then <s> ... </s>.

import Foundation

enum SentencePieceTokenizerError: LocalizedError {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail): return "Не удалось прочитать словарь токенизатора: \(detail)"
        }
    }
}

final class SentencePieceTokenizer {
    let bosId: Int32 = 0
    let padId: Int32 = 1
    let eosId: Int32 = 2
    let unkId: Int32

    private struct Piece {
        let id: Int32
        let score: Double
    }

    /// Keys are pieces as Strings. Lookups use NFC input, so Swift's canonical
    /// String equality does not change results in practice.
    private let pieces: [String: Piece]
    /// Longest piece length in Unicode scalars.
    private let maxPieceLength: Int
    private let unkScore: Double

    private static let metaspace: Unicode.Scalar = "\u{2581}"

    init(tokenizerJSON url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any],
              let vocab = model["vocab"] as? [[Any]] else {
            throw SentencePieceTokenizerError.unreadable("нет model.vocab")
        }
        if let type = model["type"] as? String, type != "Unigram" {
            throw SentencePieceTokenizerError.unreadable("тип модели \(type), ожидался Unigram")
        }
        unkId = Int32((model["unk_id"] as? NSNumber)?.intValue ?? 3)

        // Special tokens (<s>, <pad>, </s>, <unk>, <mask>) never come out of Viterbi.
        var specialIds = Set<Int>([Int(bosId), Int(padId), Int(eosId), Int(unkId)])
        if let added = root["added_tokens"] as? [[String: Any]] {
            for token in added {
                if let id = (token["id"] as? NSNumber)?.intValue {
                    specialIds.insert(id)
                }
            }
        }

        var table: [String: Piece] = [:]
        table.reserveCapacity(vocab.count)
        var minScore = Double.greatestFiniteMagnitude
        var maxLength = 1
        for (index, entry) in vocab.enumerated() {
            guard entry.count >= 2,
                  let piece = entry[0] as? String,
                  let score = (entry[1] as? NSNumber)?.doubleValue else { continue }
            minScore = min(minScore, score)
            if specialIds.contains(index) || piece.isEmpty { continue }
            let value = Piece(id: Int32(index), score: score)
            if let existing = table[piece] {
                // Canonically equivalent duplicates: keep the higher score.
                if existing.score >= score { continue }
            }
            table[piece] = value
            maxLength = max(maxLength, piece.unicodeScalars.count)
        }
        guard !table.isEmpty else {
            throw SentencePieceTokenizerError.unreadable("пустой словарь")
        }
        pieces = table
        maxPieceLength = maxLength
        unkScore = (minScore == .greatestFiniteMagnitude ? 0 : minScore) - 10
    }

    /// Token ids with <s> and </s>, truncated to `maxLength` keeping </s> last.
    func encode(_ text: String, maxLength: Int) -> [Int32] {
        let budget = max(0, maxLength - 2)
        var body: [Int32] = []
        body.reserveCapacity(min(budget, 512))
        for word in Self.normalize(text).split(separator: " ") {
            if body.count >= budget { break }
            var scalars: [Unicode.Scalar] = [Self.metaspace]
            scalars.append(contentsOf: word.unicodeScalars)
            body.append(contentsOf: viterbi(scalars))
        }
        if body.count > budget {
            body.removeLast(body.count - budget)
        }
        return [bosId] + body + [eosId]
    }

    // MARK: - Normalization

    /// NFKC, control characters dropped, whitespace collapsed to single spaces and trimmed.
    static func normalize(_ text: String) -> String {
        let nfkc = text
            .replacingOccurrences(of: "``", with: "\"")
            .replacingOccurrences(of: "''", with: "\"")
            .precomposedStringWithCompatibilityMapping
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in nfkc.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            switch scalar.value {
            case 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF:
                continue  // zero-width characters
            default:
                break
            }
            if scalar.properties.generalCategory == .control {
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(scalar)
        }
        return String(out)
    }

    // MARK: - Viterbi

    private func viterbi(_ scalars: [Unicode.Scalar]) -> [Int32] {
        let n = scalars.count
        guard n > 0 else { return [] }
        var bestScore = [Double](repeating: -.infinity, count: n + 1)
        var startAt = [Int](repeating: -1, count: n + 1)
        var tokenAt = [Int32](repeating: unkId, count: n + 1)
        bestScore[0] = 0

        for begin in 0..<n {
            let base = bestScore[begin]
            if base == -.infinity { continue }
            var key = ""
            var hasSingle = false
            let limit = min(maxPieceLength, n - begin)
            for length in 1...limit {
                key.unicodeScalars.append(scalars[begin + length - 1])
                guard let piece = pieces[key] else { continue }
                let end = begin + length
                let candidate = base + piece.score
                if startAt[end] < 0 || candidate > bestScore[end] {
                    bestScore[end] = candidate
                    startAt[end] = begin
                    tokenAt[end] = piece.id
                }
                if length == 1 { hasSingle = true }
            }
            if !hasSingle {
                let end = begin + 1
                let candidate = base + unkScore
                if startAt[end] < 0 || candidate > bestScore[end] {
                    bestScore[end] = candidate
                    startAt[end] = begin
                    tokenAt[end] = unkId
                }
            }
        }

        var ids: [Int32] = []
        var position = n
        while position > 0 {
            ids.append(tokenAt[position])
            position = startAt[position]
        }
        ids.reverse()

        // Fuse runs of <unk> into one token, as HF does.
        var fused: [Int32] = []
        fused.reserveCapacity(ids.count)
        for id in ids {
            if id == unkId, fused.last == unkId { continue }
            fused.append(id)
        }
        return fused
    }
}
