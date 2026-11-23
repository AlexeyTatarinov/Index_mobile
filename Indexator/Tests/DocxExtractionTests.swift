// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Indexator

final class DocxExtractionTests: XCTestCase {
    private func temporaryFile(_ data: Data, extension ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDocxParagraphs() throws {
        let url = try temporaryFile(ZipFixtures.docx, extension: "docx")
        let document = try DocumentTextExtractor.extract(from: url)
        XCTAssertFalse(document.usedOCR)
        XCTAssertEqual(document.pages.count, 1)
        XCTAssertNil(document.pages.first?.number)

        let lines = document.fullText.components(separatedBy: "\n")
        XCTAssertEqual(lines, [
            "Договор аренды квартиры",
            "Арендатор обязуется вносить плату до 10 числа.",
            "Name\tValue",
            "Line one",
            "Line two & more",
            "The quick brown fox jumps over the lazy dog.",
        ])
    }

    func testDocxTextParserDirectly() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
        <w:p><w:r><w:t>Привет,</w:t></w:r><w:r><w:t xml:space="preserve"> мир</w:t></w:r></w:p>
        <w:p><w:r><w:t>Hello</w:t></w:r></w:p>
        </w:body></w:document>
        """
        let text = try XCTUnwrap(DocxTextParser.text(from: Data(xml.utf8)))
        XCTAssertEqual(text, "Привет, мир\nHello\n")
    }

    func testCorruptDocxThrowsLocalizedError() throws {
        let url = try temporaryFile(Data("not a zip".utf8), extension: "docx")
        XCTAssertThrowsError(try DocumentTextExtractor.extract(from: url)) { error in
            XCTAssertTrue(error is DocumentExtractionError)
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }
    }

    // MARK: - Plain text encodings

    func testWindows1251Text() throws {
        // "Съешь же ещё этих мягких французских булок." in Windows-1251.
        let bytes: [UInt8] = [
            209, 250, 229, 248, 252, 32, 230, 229, 32, 229, 249, 184, 32, 253, 242, 232, 245, 32,
            236, 255, 227, 234, 232, 245, 32, 244, 240, 224, 237, 246, 243, 231, 241, 234, 232, 245,
            32, 225, 243, 235, 238, 234, 46,
        ]
        let url = try temporaryFile(Data(bytes), extension: "txt")
        let document = try DocumentTextExtractor.extract(from: url)
        XCTAssertEqual(document.fullText, "Съешь же ещё этих мягких французских булок.")
    }

    func testUTF8WithBOM() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("Заметки: hello".utf8)
        let url = try temporaryFile(data, extension: "md")
        XCTAssertEqual(try DocumentTextExtractor.extract(from: url).fullText, "Заметки: hello")
    }

    func testUTF16LittleEndianWithBOM() throws {
        let body = try XCTUnwrap("Таблица;csv".data(using: .utf16LittleEndian))
        let url = try temporaryFile(Data([0xFF, 0xFE]) + body, extension: "csv")
        XCTAssertEqual(try DocumentTextExtractor.extract(from: url).fullText, "Таблица;csv")
    }

    func testHTMLIsStripped() throws {
        let html = """
        <html><head><style>p { color: red; }</style><script>var x = "<p>скрипт</p>";</script></head>
        <body><h1>Заголовок</h1><p>Цена &amp; условия&nbsp;&laquo;договора&raquo; &#8212; &#x41;</p></body></html>
        """
        let url = try temporaryFile(Data(html.utf8), extension: "html")
        let text = try DocumentTextExtractor.extract(from: url).fullText
        XCTAssertTrue(text.contains("Заголовок"))
        XCTAssertTrue(text.contains("Цена & условия «договора» — A"))
        XCTAssertFalse(text.contains("скрипт"))
        XCTAssertFalse(text.contains("color"))
        XCTAssertFalse(text.contains("<"))
    }

    func testEmptyAndUnknownFilesGiveNoPages() throws {
        let empty = try temporaryFile(Data(), extension: "txt")
        XCTAssertTrue(try DocumentTextExtractor.extract(from: empty).pages.isEmpty)

        let unknown = try temporaryFile(Data("whatever".utf8), extension: "xyz")
        XCTAssertTrue(try DocumentTextExtractor.extract(from: unknown).pages.isEmpty)
    }

    func testImagesWithoutOCRGiveNoPages() throws {
        let url = try temporaryFile(Data([0x89, 0x50, 0x4E, 0x47]), extension: "png")
        let document = try DocumentTextExtractor.extract(from: url, allowOCR: false)
        XCTAssertTrue(document.pages.isEmpty)
        XCTAssertFalse(document.usedOCR)
    }

    func testSupportedExtensions() {
        XCTAssertTrue(DocumentTextExtractor.isSupported(URL(fileURLWithPath: "/tmp/a.PDF")))
        XCTAssertTrue(DocumentTextExtractor.isSupported(URL(fileURLWithPath: "/tmp/b.docx")))
        XCTAssertTrue(DocumentTextExtractor.isSupported(URL(fileURLWithPath: "/tmp/c.heic")))
        XCTAssertFalse(DocumentTextExtractor.isSupported(URL(fileURLWithPath: "/tmp/d.doc")))
        XCTAssertFalse(DocumentTextExtractor.isSupported(URL(fileURLWithPath: "/tmp/noext")))
    }
}
