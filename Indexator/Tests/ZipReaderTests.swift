// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Indexator

/// Small archives generated with Python's zipfile module.
enum ZipFixtures {
    /// Minimal .docx ([Content_Types].xml, _rels/.rels, word/document.xml), all deflated.
    /// Paragraphs: "Договор аренды квартиры" (with tab stops in pPr), a paragraph split
    /// into three runs, "Name<tab/>Value", "Line one<br/>Line two &amp; more", an English sentence.
    static let docxBase64 = "UEsDBBQAAAAIALutd13JTxqw6wAAAK4BAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbH1QvU7DMBDeeQrLK4odGBBCSTrwMwJDeYCTfUks7LPlc0v79jht6YAK4933q69b7YIXW8zsIvXyRrVSIJloHU29/Fi/NPdScAGy4CNhL/fIcjVcdet9QhZVTNzLuZT0oDWbGQOwigmpImPMAUo986QTmE+YUN+27Z02kQpSacriIYfuCUfY+CKed/V9LJLRsxSPR+KS1UtIyTsDpeJ6S/ZXSnNKUFV54PDsEl9XgtQXExbk74CT7q0uk51F8Q65vEKoLP0Vs9U2mk2oSvW/zYWecRydwbN+cUs5GmSukwevzkgARz/99WHu4RtQSwMEFAAAAAgAu613XbmBRHGwAAAAKgEAAAsAAABfcmVscy8ucmVsc43POw7CMAwG4J1TRN5pWgaEUJMuCKkrKgeIEjeNaB5KwqO3JwMDIAZG278/y233sDO5YUzGOwZNVQNBJ70yTjM4D8f1DkjKwikxe4cMFkzQ8VV7wlnkspMmExIpiEsMppzDntIkJ7QiVT6gK5PRRytyKaOmQciL0Eg3db2l8d0A/mGSXjGIvWqADEvAf2w/jkbiwcurRZd/nPhKFFlEjZnB3UdF1atdFRYob+nHi/wJUEsDBBQAAAAIALutd12s3tiYowEAABUDAAARAAAAd29yZC9kb2N1bWVudC54bWyNks1uEzEQx+88xcgHbsTbHgAt2e2NE0I9FO7e3UmysP7AdrINpyY9cChSOfAgUKioilhewX4jZrMNH1KqcvDYM7Z/85/RjA+OZQMLtK7WKmN7o4QBqlJXtZpm7MXR0wePGTgvVCUarTBjS3TsIL83btNKl3OJygMRlEvbjM28NynnrpyhFG6kDSq6m2grhSfXTnmrbWWsLtE5SiAbvp8kD7kUtWI5IQtdLTds03vm0PabF4W72aFNF6LJWIMTz8gx2mXs0X7CeD7m25f898/hex4+hi58oXURungC4VM8CZfhR/gazyBcU5QCcR2uyJ5tMBuGHUh/5Ay0vtrUGVFSL4xFh3aBLA8ftkyCrYc0Xfgcz8O3eBou4zqu4jn8A9+aQWoxVHDjkeYLgnVxRarW8T2En+F7T46nuxi3iAJS08FeAvEdYVY9YXRnfflzIXFnEtFr7OMvRTPHu0HPaoVAM7MLVlj+1yPfargvpHkCUtv/IB/NEN7M6/I1FFa3Cib6GF7NpXGgaZLB03Uj3i6h0tNbCnZY+kM79HwzdP1hO9D5L1BLAQIUAxQAAAAIALutd13JTxqw6wAAAK4BAAATAAAAAAAAAAAAAACAAQAAAABbQ29udGVudF9UeXBlc10ueG1sUEsBAhQDFAAAAAgAu613XbmBRHGwAAAAKgEAAAsAAAAAAAAAAAAAAIABHAEAAF9yZWxzLy5yZWxzUEsBAhQDFAAAAAgAu613Xaze2JijAQAAFQMAABEAAAAAAAAAAAAAAIAB9QEAAHdvcmQvZG9jdW1lbnQueG1sUEsFBgAAAAADAAMAuQAAAMcDAAAAAA=="

    /// hello.txt (stored, method 0), dir/ (directory), deflated.txt (method 8, "deflated " x 50).
    static let mixedZipBase64 = "UEsDBBQAAAAAALutd12XwPqHIgAAACIAAAAJAAAAaGVsbG8udHh0SGVsbG8sIHN0b3JlZCB3b3JsZCEg0J/RgNC40LLQtdGCLlBLAwQUAAAAAAAAACEAAAAAAAAAAAAAAAAABAAAAGRpci9QSwMEFAAAAAgAAAAhAHJimMQQAAAAwgEAAAwAAABkZWZsYXRlZC50eHRLSU3LSSxJTVFIGWUMTQYAUEsBAhQDFAAAAAAAu613XZfA+ociAAAAIgAAAAkAAAAAAAAAAAAAAIABAAAAAGhlbGxvLnR4dFBLAQIUAxQAAAAAAAAAIQAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAACAAUkAAABkaXIvUEsBAhQDFAAAAAgAAAAhAHJimMQQAAAAwgEAAAwAAAAAAAAAAAAAAIABawAAAGRlZmxhdGVkLnR4dFBLBQYAAAAAAwADAKMAAAClAAAAAAA="

    static var docx: Data { Data(base64Encoded: docxBase64)! }
    static var mixedZip: Data { Data(base64Encoded: mixedZipBase64)! }
}

final class ZipReaderTests: XCTestCase {
    func testStoredAndDeflatedEntries() throws {
        let zip = try ZipReader(data: ZipFixtures.mixedZip)
        XCTAssertEqual(zip.entries.map(\.name), ["hello.txt", "dir/", "deflated.txt"])

        let stored = try XCTUnwrap(zip.entry(named: "hello.txt"))
        XCTAssertEqual(stored.method, 0)
        let storedData = try zip.data(for: stored)
        XCTAssertEqual(String(data: storedData, encoding: .utf8), "Hello, stored world! Привет.")

        let deflated = try XCTUnwrap(zip.entry(named: "deflated.txt"))
        XCTAssertEqual(deflated.method, 8)
        XCTAssertLessThan(deflated.compressedSize, deflated.uncompressedSize)
        let inflated = try XCTUnwrap(zip.data(named: "deflated.txt"))
        XCTAssertEqual(String(data: inflated, encoding: .utf8), String(repeating: "deflated ", count: 50))

        let dir = try XCTUnwrap(zip.entry(named: "dir/"))
        XCTAssertTrue(dir.isDirectory)
        XCTAssertEqual(try zip.data(for: dir), Data())
    }

    func testMissingEntryIsNil() throws {
        let zip = try ZipReader(data: ZipFixtures.mixedZip)
        XCTAssertNil(try zip.data(named: "nope.txt"))
    }

    func testDocxDocumentEntryIsDeflated() throws {
        let zip = try ZipReader(data: ZipFixtures.docx)
        let entry = try XCTUnwrap(zip.entry(named: "word/document.xml"))
        XCTAssertEqual(entry.method, 8)
        let xml = try zip.data(for: entry)
        XCTAssertEqual(xml.count, entry.uncompressedSize)
        let text = try XCTUnwrap(String(data: xml, encoding: .utf8))
        XCTAssertTrue(text.contains("Договор аренды квартиры"))
    }

    func testGarbageIsNotAZip() {
        XCTAssertThrowsError(try ZipReader(data: Data("definitely not a zip archive".utf8)))
        XCTAssertThrowsError(try ZipReader(data: Data()))
    }

    func testTruncatedArchiveThrows() {
        let data = ZipFixtures.docx
        // Cut off the end of central directory record.
        XCTAssertThrowsError(try ZipReader(data: data.prefix(data.count - 10)))
    }
}
