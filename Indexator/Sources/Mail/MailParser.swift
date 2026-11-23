// SPDX-License-Identifier: GPL-3.0-or-later
//
// Turns a Gmail API message (format=full) into plain text: picks text/plain
// parts, falls back to stripped HTML, decodes base64url and charsets.

import Foundation

// MARK: - Gmail API JSON

struct GmailHeader: Decodable, Equatable {
    let name: String
    let value: String
}

struct GmailBody: Decodable, Equatable {
    let size: Int?
    let data: String?
    let attachmentId: String?
}

struct GmailPart: Decodable, Equatable {
    let partId: String?
    let mimeType: String?
    let filename: String?
    let headers: [GmailHeader]?
    let body: GmailBody?
    let parts: [GmailPart]?

    func header(_ name: String) -> String? {
        headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

struct GmailAPIMessage: Decodable, Equatable {
    let id: String
    let threadId: String?
    let labelIds: [String]?
    let snippet: String?
    let internalDate: String?
    let payload: GmailPart?
}

// MARK: - Parser

enum MailParser {
    /// Longest body kept per email. Search only needs the first part of long newsletters.
    static let maxBodyLength = 30_000

    static func parse(_ message: GmailAPIMessage) -> MailMessage {
        let payload = message.payload
        var plain: [String] = []
        var html: [String] = []
        var attachments: [String] = []
        if let payload { collect(payload, plain: &plain, html: &html, attachments: &attachments) }

        var body = plain.joined(separator: "\n\n")
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = html.map(stripHTML).joined(separator: "\n\n")
        }
        body = normalizeWhitespace(body)
        if body.count > maxBodyLength { body = String(body.prefix(maxBodyLength)) }

        let date = message.internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        return MailMessage(
            id: message.id,
            threadId: message.threadId ?? message.id,
            subject: payload?.header("Subject") ?? "",
            sender: payload?.header("From") ?? "",
            recipients: payload?.header("To") ?? "",
            date: date,
            snippet: decodeEntities(message.snippet ?? ""),
            body: body,
            labels: message.labelIds ?? [],
            attachments: attachments
        )
    }

    private static func collect(_ part: GmailPart, plain: inout [String], html: inout [String], attachments: inout [String]) {
        let mime = (part.mimeType ?? "").lowercased()
        if let name = part.filename, !name.isEmpty {
            attachments.append(name)
            return
        }
        if let parts = part.parts, !parts.isEmpty {
            for child in parts { collect(child, plain: &plain, html: &html, attachments: &attachments) }
            return
        }
        guard let data = part.body?.data, let bytes = base64URLDecode(data) else { return }
        let charset = charsetParameter(part.header("Content-Type"))
        let text = decode(bytes, charset: charset)
        if mime == "text/plain" {
            plain.append(text)
        } else if mime == "text/html" {
            html.append(text)
        }
    }

    // MARK: Encoding helpers

    static func base64URLDecode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s = s.filter { !$0.isWhitespace }
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }

    static func charsetParameter(_ contentType: String?) -> String? {
        guard let contentType else { return nil }
        for piece in contentType.split(separator: ";") {
            let pair = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].lowercased() == "charset" {
                return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
            }
        }
        return nil
    }

    static func decode(_ data: Data, charset: String?) -> String {
        if let charset, !charset.isEmpty {
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let s = String(data: data, encoding: encoding) { return s }
            }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1251) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Text helpers

    static func stripHTML(_ html: String) -> String {
        var s = html
        for tag in ["style", "script", "head", "title"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ",
                                       options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<(br|/p|/div|/tr|/li|/h[1-6])[^>]*>", with: "\n",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return decodeEntities(s)
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "laquo": "«", "raquo": "»",
        "mdash": "—", "ndash": "–", "hellip": "…", "copy": "©", "reg": "®", "euro": "€", "rsquo": "’",
        "lsquo": "‘", "rdquo": "”", "ldquo": "“", "bull": "•", "zwnj": "", "shy": "",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let regex = try! NSRegularExpression(pattern: "&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);")
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let name = ns.substring(with: match.range(at: 1))
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = namedEntities[name.lowercased()]
            }
            result += replacement ?? ns.substring(with: match.range)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// Collapses runs of spaces and blank lines, drops quoted-reply noise like "> ".
    static func normalizeWhitespace(_ text: String) -> String {
        var lines: [String] = []
        var blank = 0
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.replacingOccurrences(of: "[ \\t\\x{00A0}\\x{200B}]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                blank += 1
                if blank == 1, !lines.isEmpty { lines.append("") }
            } else {
                blank = 0
                lines.append(line)
            }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// "Иван Петров <ivan@example.com>" → "Иван Петров"; "<a@b.c>" or "a@b.c" → "a@b.c".
    static func displayName(_ from: String) -> String {
        let trimmed = from.trimmingCharacters(in: .whitespaces)
        if let open = trimmed.lastIndex(of: "<") {
            let name = trimmed[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if !name.isEmpty { return name }
            return trimmed[trimmed.index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: "> "))
        }
        return trimmed
    }

    /// Text pieces that go into the embedder: subject and sender first, then the body
    /// cut into overlapping windows (the e5 model reads about 900 characters at most).
    static func passages(for message: MailMessage, chunk: Int = 800, maxChunks: Int = 4) -> [String] {
        let head = [message.subject, message.senderName].filter { !$0.isEmpty }.joined(separator: " — ")
        let body = message.body.isEmpty ? message.snippet : message.body
        var chunks: [String] = []
        var start = body.startIndex
        while start < body.endIndex && chunks.count < maxChunks {
            let end = body.index(start, offsetBy: chunk, limitedBy: body.endIndex) ?? body.endIndex
            var piece = String(body[start..<end])
            if chunks.isEmpty, !head.isEmpty { piece = head + "\n" + piece }
            chunks.append(piece)
            guard end < body.endIndex else { break }
            start = body.index(end, offsetBy: -100, limitedBy: body.startIndex) ?? end
        }
        if chunks.isEmpty, !head.isEmpty { chunks.append(head) }
        return chunks
    }
}
