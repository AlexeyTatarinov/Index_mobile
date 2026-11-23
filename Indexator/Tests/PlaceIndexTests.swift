// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Indexator

final class PlaceIndexTests: XCTestCase {
    func testRussianCaseEndingsShareStem() {
        XCTAssertEqual(PlaceIndex.stem("валенсии"), PlaceIndex.stem("валенсия"))
        XCTAssertEqual(PlaceIndex.stem("москве"), PlaceIndex.stem("москва"))
        XCTAssertEqual(PlaceIndex.stem("барселоне"), PlaceIndex.stem("барселона"))
    }

    func testFindsCityInQueryAndNearestCity() throws {
        let places = PlaceIndex.shared
        guard places.count > 0 else { throw XCTSkip("places.tsv is not bundled") }

        let match = try XCTUnwrap(places.match(in: "архитектура Валенсии"))
        XCTAssertTrue(match.words.contains("валенсии"))
        XCTAssertTrue(match.places.contains { $0.country == "ES" && $0.name == "Valencia" })

        let english = try XCTUnwrap(places.match(in: "beach in Barcelona"))
        XCTAssertEqual(english.places.first?.country, "ES")

        XCTAssertNil(places.match(in: "собака на пляже"))
        XCTAssertNil(places.match(in: "природа"))

        let near = try XCTUnwrap(places.nearest(latitude: 39.4699, longitude: -0.3763))
        XCTAssertEqual(near.name, "Valencia")
        XCTAssertEqual(near.displayName, "Валенсия")
    }

    func testConceptWordsMapToLabels() throws {
        guard !ImageLabeler.supported.isEmpty else { throw XCTSkip("Vision labels unavailable") }
        XCTAssertTrue(LabelQuery.labels(for: "еда").labels.contains("food"))
        XCTAssertFalse(LabelQuery.labels(for: "город").labels.contains("mountain"))
        XCTAssertTrue(LabelQuery.labels(for: "собака").words.contains("собака"))
    }
}
