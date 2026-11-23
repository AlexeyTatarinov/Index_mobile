// SPDX-License-Identifier: GPL-3.0-or-later
//
// Port of OpenAI CLIP's SimpleTokenizer (byte-level BPE, context length 77).
// Uses the original `bpe_simple_vocab_16e6.txt` merges file, downloaded in CI.

import Foundation

enum CLIPTokenizerError: Error {
    case vocabUnreadable
}

final class CLIPTokenizer {
    static let contextLength = 77

    private struct Pair: Hashable {
        let first: String
        let second: String
    }

    private let encoder: [String: Int32]
    private let bpeRanks: [Pair: Int]
    private let byteEncoder: [UInt8: String]
    private let pattern: NSRegularExpression
    private var cache: [String: [String]] = [:]
    private let lock = NSLock()

    let startToken: Int32
    let endToken: Int32

    init(vocabURL: URL) throws {
        guard let text = try? String(contentsOf: vocabURL, encoding: .utf8) else {
            throw CLIPTokenizerError.vocabUnreadable
        }
        let lines = text.components(separatedBy: "\n")
        // Same slice as the Python reference: merges[1 : 49152 - 256 - 2 + 1]
        let upper = min(lines.count, 49152 - 256 - 2 + 1)
        var merges: [Pair] = []
        merges.reserveCapacity(upper)
        for line in lines[1..<upper] {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            merges.append(Pair(first: String(parts[0]), second: String(parts[1])))
        }

        let (order, mapping) = CLIPTokenizer.bytesToUnicode()
        byteEncoder = mapping

        var vocab: [String] = order.map { mapping[$0]! }
        vocab += vocab.map { $0 + "</w>" }
        vocab += merges.map { $0.first + $0.second }
        vocab += ["<|startoftext|>", "<|endoftext|>"]

        var enc: [String: Int32] = [:]
        enc.reserveCapacity(vocab.count)
        for (index, token) in vocab.enumerated() {
            enc[token] = Int32(index)
        }
        encoder = enc

        var ranks: [Pair: Int] = [:]
        ranks.reserveCapacity(merges.count)
        for (index, pair) in merges.enumerated() {
            ranks[pair] = index
        }
        bpeRanks = ranks

        startToken = enc["<|startoftext|>"]!
        endToken = enc["<|endoftext|>"]!

        pattern = try NSRegularExpression(
            pattern: #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#,
            options: [.caseInsensitive]
        )
    }

    /// Returns exactly `contextLength` token ids: [SOT] + text + [EOT], zero padded.
    func tokenize(_ text: String) -> [Int32] {
        var ids = encode(text)
        let maxBody = CLIPTokenizer.contextLength - 2
        if ids.count > maxBody {
            ids = Array(ids.prefix(maxBody))
        }
        var result: [Int32] = [startToken]
        result += ids
        result.append(endToken)
        while result.count < CLIPTokenizer.contextLength {
            result.append(0)
        }
        return result
    }

    func encode(_ text: String) -> [Int32] {
        let cleaned = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
        let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        var ids: [Int32] = []
        for match in pattern.matches(in: cleaned, options: [], range: range) {
            guard let r = Range(match.range, in: cleaned) else { continue }
            let token = String(cleaned[r])
            let mapped = token.utf8.map { byteEncoder[$0]! }.joined()
            for piece in bpe(mapped) {
                if let id = encoder[piece] {
                    ids.append(id)
                }
            }
        }
        return ids
    }

    private func bpe(_ token: String) -> [String] {
        lock.lock()
        if let cached = cache[token] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var word: [String] = token.map { String($0) }
        guard !word.isEmpty else { return [] }
        word[word.count - 1] += "</w>"

        while word.count > 1 {
            var best: (rank: Int, index: Int)? = nil
            for i in 0..<(word.count - 1) {
                if let rank = bpeRanks[Pair(first: word[i], second: word[i + 1])] {
                    if best == nil || rank < best!.rank {
                        best = (rank, i)
                    }
                }
            }
            guard let chosen = best else { break }
            let first = word[chosen.index]
            let second = word[chosen.index + 1]

            var merged: [String] = []
            merged.reserveCapacity(word.count)
            var i = 0
            while i < word.count {
                if i < word.count - 1 && word[i] == first && word[i + 1] == second {
                    merged.append(first + second)
                    i += 2
                } else {
                    merged.append(word[i])
                    i += 1
                }
            }
            word = merged
        }

        lock.lock()
        cache[token] = word
        lock.unlock()
        return word
    }

    /// GPT-2 style reversible byte -> unicode mapping. Returns the byte order used to build the vocab.
    private static func bytesToUnicode() -> ([UInt8], [UInt8: String]) {
        var bs: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var cs: [Int] = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) {
            bs.append(b)
            cs.append(256 + n)
            n += 1
        }
        var mapping: [UInt8: String] = [:]
        for (b, c) in zip(bs, cs) {
            mapping[UInt8(b)] = String(Character(Unicode.Scalar(UInt32(c))!))
        }
        return (bs.map { UInt8($0) }, mapping)
    }
}
