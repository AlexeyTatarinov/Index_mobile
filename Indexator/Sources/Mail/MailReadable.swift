// SPDX-License-Identifier: GPL-3.0-or-later
//
// Makes a stored email body pleasant to read: drops invisible filler, leftover
// HTML/CSS, image placeholders; shortens links to their site name; moves the
// quoted previous conversation out of the way. Works on emails already stored.

import Foundation

enum MailReadable {
    struct Body: Equatable {
        var text: String       // what to show
        var quoted: String     // earlier messages of the thread, hidden by default
    }

    /// Invisible characters marketing emails use as preheader padding.
    private static let invisible = CharacterSet(charactersIn: "\u{034F}\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}\u{00AD}")

    static func body(_ raw: String) -> Body {
        var text = raw
        // Some senders put HTML into the plain-text part.
        let tags = text.components(separatedBy: "</").count - 1
        if tags >= 3 { text = MailParser.stripHTML(text) }

        text = String(String.UnicodeScalarView(text.unicodeScalars.filter { !invisible.contains($0) }))
        text = text.replacingOccurrences(of: "\\[(image|cid|img)[^\\]]*\\]", with: "",
                                         options: [.regularExpression, .caseInsensitive])
        // "<https://…>" in plain text: keep the address, drop the brackets.
        text = text.replacingOccurrences(of: "<(https?://[^>\\s]+)>", with: "$1", options: .regularExpression)

        var kept: [String] = []
        var quoted: [String] = []
        var inQuote = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inQuote && isQuoteHeader(trimmed) { inQuote = true }
            if inQuote || trimmed.hasPrefix(">") {
                quoted.append(trimmed.hasPrefix(">") ? String(trimmed.drop(while: { $0 == ">" || $0 == " " })) : trimmed)
                continue
            }
            if looksLikeCode(trimmed) { continue }
            kept.append(trimmed)
        }
        return Body(text: MailParser.normalizeWhitespace(kept.joined(separator: "\n")),
                    quoted: MailParser.normalizeWhitespace(quoted.joined(separator: "\n")))
    }

    /// "On Mon, 3 Nov 2025 Ivan <…> wrote:", "… написал(а):", Outlook's "-----Original Message-----".
    static func isQuoteHeader(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.hasPrefix("-----original message") || lower.hasPrefix("-----исходное сообщение") { return true }
        if line.count > 160 { return false }
        return (lower.hasPrefix("on ") && lower.hasSuffix("wrote:"))
            || lower.hasSuffix("написал:") || lower.hasSuffix("написала:") || lower.hasSuffix("написал(а):")
            || (lower.hasPrefix("le ") && lower.hasSuffix("a écrit :"))
    }

    /// CSS rules, MSO conditionals and other markup that survived stripping.
    static func looksLikeCode(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        if line.hasPrefix("@media") || line.hasPrefix("@font-face") || line.hasPrefix("<!--") || line.hasPrefix("<![") { return true }
        if line.contains("{") && (line.contains("}") || line.contains(":")) && line.contains(";") { return true }
        let punctuation = line.filter { "{};:#<>=".contains($0) }.count
        return line.count > 20 && Double(punctuation) / Double(line.count) > 0.15
    }

    /// Body text with each web address replaced by "↗ site" that opens it.
    static func attributed(_ text: String) -> AttributedString {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return AttributedString(text)
        }
        let ns = text as NSString
        var result = AttributedString()
        var last = 0
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url else { continue }
            result += AttributedString(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            if url.scheme == "mailto" {
                var piece = AttributedString(ns.substring(with: match.range))
                piece.link = url
                result += piece
            } else {
                var piece = AttributedString("↗ " + shortHost(url))
                piece.link = url
                result += piece
            }
            last = match.range.location + match.range.length
        }
        result += AttributedString(ns.substring(from: last))
        return result
    }

    /// "www.booking.com" → "booking.com".
    static func shortHost(_ url: URL) -> String {
        var host = url.host ?? url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}
