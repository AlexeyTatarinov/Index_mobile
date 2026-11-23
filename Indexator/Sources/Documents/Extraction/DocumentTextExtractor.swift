// SPDX-License-Identifier: GPL-3.0-or-later
//
// Extracts plain text from user documents (PDF, text, HTML, RTF, DOCX, images)
// for the semantic search index. Synchronous: call it on a background queue.

import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UIKit
import Vision

struct ExtractedPage: Equatable {
    /// 1-based page number for PDFs, nil for formats without pages.
    let number: Int?
    let text: String
}

struct ExtractedDocument {
    let pages: [ExtractedPage]
    let usedOCR: Bool

    var fullText: String { pages.map(\.text).joined(separator: "\n\n") }
}

enum DocumentExtractionError: LocalizedError {
    case unreadable(fileName: String)
    case locked(fileName: String)
    case damaged(fileName: String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return "Не удалось прочитать файл «\(name)»."
        case .locked(let name):
            return "Документ «\(name)» защищён паролем — его текст недоступен."
        case .damaged(let name):
            return "Файл «\(name)» повреждён или имеет неподдерживаемый формат."
        }
    }
}

enum DocumentTextExtractor {
    static let plainTextExtensions: Set<String> = ["txt", "md", "markdown", "text", "csv", "log", "json", "xml"]
    static let htmlExtensions: Set<String> = ["html", "htm"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tiff", "webp"]

    static let supportedExtensions: Set<String> =
        plainTextExtensions.union(htmlExtensions).union(imageExtensions).union(["pdf", "rtf", "docx"])

    /// Text files are read up to this many bytes.
    static let maxTextBytes = 20 * 1024 * 1024
    /// Only the first pages of a PDF are OCR'd, to keep indexing time bounded.
    static let maxOCRPages = 60
    /// A PDF page with less text than this is treated as a scan.
    static let minPageTextChars = 20

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func extract(from url: URL, allowOCR: Bool = true) throws -> ExtractedDocument {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent

        if ext == "pdf" {
            return try extractPDF(url, allowOCR: allowOCR)
        }
        if plainTextExtensions.contains(ext) {
            let text = try readTextFile(url)
            return single(text)
        }
        if htmlExtensions.contains(ext) {
            let html = try readTextFile(url)
            return single(stripHTML(html))
        }
        if ext == "rtf" {
            do {
                let attributed = try NSAttributedString(
                    url: url,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil
                )
                return single(attributed.string)
            } catch {
                throw DocumentExtractionError.unreadable(fileName: name)
            }
        }
        if ext == "docx" {
            let text = try extractDocx(url)
            return single(text)
        }
        if imageExtensions.contains(ext) {
            guard allowOCR else { return ExtractedDocument(pages: [], usedOCR: false) }
            guard let image = loadImage(url, maxPixelSize: 2048) else {
                throw DocumentExtractionError.unreadable(fileName: name)
            }
            return single(recognizeText(in: image), usedOCR: true)
        }
        return ExtractedDocument(pages: [], usedOCR: false)
    }

    private static func single(_ text: String, usedOCR: Bool = false) -> ExtractedDocument {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pages = trimmed.isEmpty ? [] : [ExtractedPage(number: nil, text: trimmed)]
        return ExtractedDocument(pages: pages, usedOCR: usedOCR)
    }

    // MARK: - PDF

    private static func extractPDF(_ url: URL, allowOCR: Bool) throws -> ExtractedDocument {
        let name = url.lastPathComponent
        guard let document = PDFDocument(url: url) else {
            throw DocumentExtractionError.unreadable(fileName: name)
        }
        if document.isLocked && !document.unlock(withPassword: "") {
            throw DocumentExtractionError.locked(fileName: name)
        }

        var pages: [ExtractedPage] = []
        var usedOCR = false
        for index in 0..<document.pageCount {
            autoreleasepool {
                guard let page = document.page(at: index) else { return }
                var text = page.string ?? ""
                if allowOCR, index < maxOCRPages, nonWhitespaceCount(text) < minPageTextChars,
                   let image = render(page) {
                    usedOCR = true
                    let recognized = recognizeText(in: image)
                    if nonWhitespaceCount(recognized) > nonWhitespaceCount(text) {
                        text = recognized
                    }
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    pages.append(ExtractedPage(number: index + 1, text: trimmed))
                }
            }
        }
        return ExtractedDocument(pages: pages, usedOCR: usedOCR)
    }

    /// Renders a page at ~2x (longest side at most 2000 px) on a white background.
    private static func render(_ page: PDFPage) -> CGImage? {
        var size = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 {
            size = CGSize(width: size.height, height: size.width)
        }
        guard size.width >= 1, size.height >= 1 else { return nil }
        let scale = min(2.0, 2000.0 / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        // thumbnail(of:for:) applies the page rotation for us.
        guard let image = page.thumbnail(of: target, for: .cropBox).cgImage else { return nil }
        return flattenOnWhite(image)
    }

    static func nonWhitespaceCount(_ text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            count += 1
        }
        return count
    }

    // MARK: - Images / OCR

    private static func loadImage(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return flattenOnWhite(image)
    }

    /// Transparent pixels would become black for Vision; draw them over white.
    private static func flattenOnWhite(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            break
        }
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    /// Document OCR. Unlike TextRecognizer (tuned for photos, minimumTextHeight 0.02),
    /// keeps small body text: on a full A4 page a 10 pt line is only ~1.2% of the height.
    private static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ru-RU", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    // MARK: - Plain text

    private static func readTextFile(_ url: URL) throws -> String {
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: maxTextBytes) ?? Data()
        } catch {
            throw DocumentExtractionError.unreadable(fileName: url.lastPathComponent)
        }
        return decodeText(data, mayBeTruncated: data.count >= maxTextBytes)
    }

    static let windows1251 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)
    ))

    /// UTF-8 (BOM stripped) → UTF-16 with BOM → Windows-1251 → Mac Roman.
    static func decodeText(_ data: Data, mayBeTruncated: Bool = false) -> String {
        guard !data.isEmpty else { return "" }
        let head = [UInt8](data.prefix(3))

        if head.count >= 3, head[0] == 0xEF, head[1] == 0xBB, head[2] == 0xBF {
            if let s = decodeUTF8(Data(data.dropFirst(3)), lenient: mayBeTruncated) { return s }
        } else if head.count >= 2, (head[0] == 0xFF && head[1] == 0xFE) || (head[0] == 0xFE && head[1] == 0xFF) {
            let encoding: String.Encoding = head[0] == 0xFF ? .utf16LittleEndian : .utf16BigEndian
            var body = Data(data.dropFirst(2))
            if body.count % 2 == 1 { body = Data(body.dropLast()) }
            if let s = String(data: body, encoding: encoding) { return s }
        }
        if let s = decodeUTF8(data, lenient: mayBeTruncated) { return s }
        if let s = String(data: data, encoding: windows1251) { return s }
        return String(data: data, encoding: .macOSRoman) ?? ""
    }

    /// When the read was capped, the last multi-byte character may be cut: retry without it.
    private static func decodeUTF8(_ data: Data, lenient: Bool) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        guard lenient else { return nil }
        for drop in 1...3 where data.count > drop {
            if let s = String(data: Data(data.dropLast(drop)), encoding: .utf8) { return s }
        }
        return nil
    }

    // MARK: - HTML

    /// Lightweight tag stripping (NSAttributedString HTML import is main-thread-only and slow).
    static func stripHTML(_ html: String) -> String {
        var s = html
        s = replacing(s, "(?is)<!--.*?-->", with: " ")
        s = replacing(s, "(?is)<(script|style|noscript|template)\\b[^>]*>.*?</\\1\\s*>", with: " ")
        s = replacing(s, "(?i)<br\\s*/?>", with: "\n")
        s = replacing(
            s,
            "(?i)</?(p|div|li|tr|h[1-6]|table|ul|ol|blockquote|section|article|header|footer|pre|title)\\b[^>]*>",
            with: "\n"
        )
        s = replacing(s, "(?i)</t[dh]\\s*>", with: "\t")
        s = replacing(s, "<[^>]*>", with: "")
        return decodeEntities(s)
    }

    private static func replacing(_ s: String, _ pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "—", "ndash": "–", "laquo": "«", "raquo": "»", "hellip": "…",
        "copy": "©", "reg": "®", "trade": "™", "bull": "•", "middot": "·", "shy": "",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&"),
              let regex = try? NSRegularExpression(pattern: "&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});")
        else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let body = ns.substring(with: match.range(at: 1))
            out += entityValue(body) ?? ns.substring(with: match.range)
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private static func entityValue(_ body: String) -> String? {
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            guard let code = UInt32(body.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) else { return nil }
            return String(Character(scalar))
        }
        if body.hasPrefix("#") {
            guard let code = UInt32(body.dropFirst()), let scalar = Unicode.Scalar(code) else { return nil }
            return String(Character(scalar))
        }
        return namedEntities[body]
    }

    // MARK: - DOCX

    private static func extractDocx(_ url: URL) throws -> String {
        let name = url.lastPathComponent
        let xml: Data?
        do {
            xml = try ZipReader(url: url).data(named: "word/document.xml")
        } catch let error as ZipReader.ZipError where error == .encrypted {
            throw DocumentExtractionError.locked(fileName: name)
        } catch is ZipReader.ZipError {
            throw DocumentExtractionError.damaged(fileName: name)
        } catch {
            throw DocumentExtractionError.unreadable(fileName: name)
        }
        guard let xml, let text = DocxTextParser.text(from: xml) else {
            throw DocumentExtractionError.damaged(fileName: name)
        }
        return text
    }
}

/// Collects text from WordprocessingML: <w:t> runs, "\n" per <w:p>, "\t" for <w:tab/>, "\n" for <w:br/>.
final class DocxTextParser: NSObject, XMLParserDelegate {
    private var output = ""
    private var inText = false
    private var tabStopsDepth = 0   // <w:tabs> in paragraph properties holds tab stops, not tabs
    private var fallbackDepth = 0   // <mc:Fallback> duplicates <mc:Choice> content

    /// Returns nil only when the XML could not be parsed at all.
    static func text(from data: Data) -> String? {
        let parser = XMLParser(data: data)
        let collector = DocxTextParser()
        parser.delegate = collector
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        if !ok && collector.output.isEmpty { return nil }
        return collector.output
    }

    private static func localName(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch Self.localName(elementName) {
        case "Fallback":
            fallbackDepth += 1
        case "tabs":
            tabStopsDepth += 1
        case "t":
            inText = fallbackDepth == 0
        case "tab":
            if tabStopsDepth == 0 && fallbackDepth == 0 { output += "\t" }
        case "br", "cr":
            if fallbackDepth == 0 { output += "\n" }
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch Self.localName(elementName) {
        case "Fallback":
            fallbackDepth = max(0, fallbackDepth - 1)
        case "tabs":
            tabStopsDepth = max(0, tabStopsDepth - 1)
        case "t":
            inText = false
        case "p":
            if fallbackDepth == 0 { output += "\n" }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { output += string }
    }
}
