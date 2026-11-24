// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Indexator

final class DocumentRelevanceTests: XCTestCase {
    func testTermsDropStopWordsAndKeepShortAcronyms() {
        XCTAssertEqual(DocumentRelevance.terms("моё CV"), ["cv"])
        XCTAssertEqual(DocumentRelevance.terms("найди договор на квартиру"), ["догов", "кварти"])
        XCTAssertEqual(DocumentRelevance.terms("Попугай попугай"), ["попуг"])
    }

    func testShortQueryNeedsEveryWord() {
        let terms = DocumentRelevance.terms("договор аренды")
        let full = DocumentRelevance.words("Договор аренды квартиры № 15")
        let half = DocumentRelevance.words("Договор купли-продажи автомобиля")
        XCTAssertTrue(DocumentRelevance.isTextMatch(terms: terms, words: full))
        XCTAssertFalse(DocumentRelevance.isTextMatch(terms: terms, words: half))
    }

    func testUnrelatedDocumentIsNotATextMatch() {
        let terms = DocumentRelevance.terms("попугай")
        let words = DocumentRelevance.words("Счёт-фактура №A-17/2023, Валенсия, сумма 12 500 руб.")
        XCTAssertFalse(DocumentRelevance.isTextMatch(terms: terms, words: words))
        XCTAssertFalse(DocumentRelevance.isTextMatch(terms: [], words: words))
    }

    func testLongQueryAllowsOneMissingWordInFive() {
        let terms = DocumentRelevance.terms("налоговый вычет покупка квартиры Москва")
        XCTAssertEqual(terms.count, 5)
        let words = DocumentRelevance.words("Заявление на налоговый вычет при покупке квартиры")
        XCTAssertTrue(DocumentRelevance.isTextMatch(terms: terms, words: words))
        let fewer = DocumentRelevance.words("Заявление на налоговый вычет")
        XCTAssertFalse(DocumentRelevance.isTextMatch(terms: terms, words: fewer))
    }

    func testFolderPathsCompareAcrossPrivatePrefix() {
        let a = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/", isDirectory: true)
        let b = URL(fileURLWithPath: "/var/mobile/Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        let inner = URL(fileURLWithPath: "/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Downloads", isDirectory: true)
        let sibling = URL(fileURLWithPath: "/var/mobile/Library/Mobile Documents/com~apple~CloudDocsX", isDirectory: true)
        let pa = DocumentRelevance.normalizedPath(a)
        XCTAssertEqual(pa, DocumentRelevance.normalizedPath(b))
        XCTAssertTrue(DocumentRelevance.isSameOrInside(DocumentRelevance.normalizedPath(inner), pa))
        XCTAssertFalse(DocumentRelevance.isSameOrInside(DocumentRelevance.normalizedPath(sibling), pa))
        XCTAssertFalse(DocumentRelevance.isSameOrInside(pa, DocumentRelevance.normalizedPath(inner)))
    }
}
