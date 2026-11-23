// SPDX-License-Identifier: GPL-3.0-or-later
//
// BERT WordPiece tokenizer (cased, as in distilbert-base-multilingual-cased):
// clean text, split CJK characters, whitespace and punctuation, then greedy
// longest-match word pieces with the "##" continuation prefix.

import Foundation

enum WordPieceError: Error {
    case vocabUnreadable
    case missingToken(String)
}

final class WordPieceTokenizer {
    private let vocab: [String: Int32]
    let cls: Int32, sep: Int32, pad: Int32, unk: Int32
    let maxLength: Int

    init(vocabURL: URL, maxLength: Int) throws {
        guard let text = try? String(contentsOf: vocabURL, encoding: .utf8) else {
            throw WordPieceError.vocabUnreadable
        }
        var map: [String: Int32] = [:]
        var index: Int32 = 0
        text.enumerateLines { line, _ in
            if map[line] == nil { map[line] = index }
            index += 1
        }
        func id(_ token: String) throws -> Int32 {
            guard let v = map[token] else { throw WordPieceError.missingToken(token) }
            return v
        }
        vocab = map
        cls = try id("[CLS]")
        sep = try id("[SEP]")
        pad = try id("[PAD]")
        unk = try id("[UNK]")
        self.maxLength = maxLength
    }

    /// Token ids and attention mask, both padded to `maxLength`.
    func encode(_ text: String) -> (ids: [Int32], mask: [Int32]) {
        var ids: [Int32] = [cls]
        for word in Self.basicTokens(text) {
            ids.append(contentsOf: pieces(word))
            if ids.count >= maxLength - 1 { break }
        }
        ids = Array(ids.prefix(maxLength - 1))
        ids.append(sep)
        var mask = [Int32](repeating: 1, count: ids.count)
        while ids.count < maxLength {
            ids.append(pad)
            mask.append(0)
        }
        return (ids, mask)
    }

    private func pieces(_ word: [Unicode.Scalar]) -> [Int32] {
        if word.count > 100 { return [unk] }
        var result: [Int32] = []
        var start = 0
        while start < word.count {
            var end = word.count
            var found: Int32?
            while start < end {
                var piece = String(String.UnicodeScalarView(word[start..<end]))
                if start > 0 { piece = "##" + piece }
                if let id = vocab[piece] {
                    found = id
                    break
                }
                end -= 1
            }
            guard let id = found else { return [unk] }
            result.append(id)
            start = end
        }
        return result
    }

    static func basicTokens(_ text: String) -> [[Unicode.Scalar]] {
        var tokens: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        func flush() {
            if !current.isEmpty { tokens.append(current); current = [] }
        }
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 0 || v == 0xFFFD { continue }
            if isWhitespace(scalar) {
                flush()
            } else if isControl(scalar) {
                continue
            } else if isPunctuation(scalar) || isCJK(v) {
                flush()
                tokens.append([scalar])
            } else {
                current.append(scalar)
            }
        }
        flush()
        return tokens
    }

    private static func isWhitespace(_ s: Unicode.Scalar) -> Bool {
        if s == " " || s == "\t" || s == "\n" || s == "\r" { return true }
        return s.properties.generalCategory == .spaceSeparator
    }

    private static func isControl(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .control, .format: return true
        default: return false
        }
    }

    private static func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if (33...47).contains(v) || (58...64).contains(v) || (91...96).contains(v) || (123...126).contains(v) {
            return true
        }
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    private static func isCJK(_ v: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x20000...0x2A6DF).contains(v)
            || (0x2A700...0x2B73F).contains(v) || (0x2B740...0x2B81F).contains(v) || (0x2B820...0x2CEAF).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0x2F800...0x2FA1F).contains(v)
    }
}
