// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Indexator

final class FallbackDictionaryTests: XCTestCase {
    func testSingleWord() {
        XCTAssertEqual(FallbackDictionary.translate("Попугай"), "parrot")
    }

    func testInflectedWords() {
        XCTAssertEqual(FallbackDictionary.translate("собака на пляже"), "dog on beach")
        XCTAssertEqual(FallbackDictionary.translate("кошки"), "cat")
    }

    func testUnknownWordsStay() {
        XCTAssertEqual(FallbackDictionary.translate("красный трамвай"), "red трамвай")
        XCTAssertNil(FallbackDictionary.translate("трамвай"))
    }

    func testPrompt() {
        XCTAssertEqual(SearchEngine.prompt(for: "parrot"), "a photo of parrot")
        XCTAssertEqual(SearchEngine.prompt(for: "a photo of a cat"), "a photo of a cat")
    }
}
