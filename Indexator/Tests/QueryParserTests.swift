// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Indexator

final class QueryParserTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testPlainQueryHasNoFilter() {
        let p = QueryParser.parse("собака на пляже", calendar: calendar)
        XCTAssertNil(p.dateFilter)
        XCTAssertEqual(p.text, "собака на пляже")
    }

    func testSeasonAndYear() {
        let p = QueryParser.parse("пляж летом 2024", calendar: calendar)
        XCTAssertEqual(p.text, "пляж")
        let f = try! XCTUnwrap(p.dateFilter)
        XCTAssertEqual(f.months, [6, 7, 8])
        XCTAssertEqual(f.from, date(2024, 1, 1))
        XCTAssertEqual(f.to, date(2025, 1, 1))
        XCTAssertTrue(f.matches(seconds: date(2024, 7, 10).timeIntervalSince1970, month: 7))
        XCTAssertFalse(f.matches(seconds: date(2024, 10, 10).timeIntervalSince1970, month: 10))
        XCTAssertFalse(f.matches(seconds: date(2023, 7, 10).timeIntervalSince1970, month: 7))
    }

    func testMonthWithoutYear() {
        let p = QueryParser.parse("снег в январе", calendar: calendar)
        XCTAssertEqual(p.text, "снег")
        XCTAssertEqual(p.dateFilter?.months, [1])
        XCTAssertNil(p.dateFilter?.from)
    }

    func testRelativeLastMonth() {
        let now = date(2026, 11, 23)
        let p = QueryParser.parse("чек в прошлом месяце", now: now, calendar: calendar)
        XCTAssertEqual(p.text, "чек")
        XCTAssertEqual(p.dateFilter?.from, date(2026, 10, 1))
        XCTAssertEqual(p.dateFilter?.to, date(2026, 11, 1))
    }

    func testYearOnly() {
        let p = QueryParser.parse("2019", calendar: calendar)
        XCTAssertEqual(p.text, "")
        XCTAssertEqual(p.dateFilter?.from, date(2019, 1, 1))
    }

    func testEnglish() {
        let p = QueryParser.parse("mountains in summer 2023", calendar: calendar)
        XCTAssertEqual(p.text, "mountains")
        XCTAssertEqual(p.dateFilter?.months, [6, 7, 8])
    }
}
