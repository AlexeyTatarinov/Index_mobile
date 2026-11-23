// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pulls time expressions out of a query ("летом 2024", "в прошлом месяце",
// "march") and turns them into a filter. What is left goes to semantic search.

import Foundation

struct DateFilter: Equatable {
    var from: Date?
    var to: Date?
    var months: Set<Int> = []   // used when no year is given: "летом" = any summer
    var label: String

    func matches(seconds: Double, month: UInt8) -> Bool {
        if seconds.isNaN { return false }
        if let from, seconds < from.timeIntervalSince1970 { return false }
        if let to, seconds >= to.timeIntervalSince1970 { return false }
        if !months.isEmpty && !months.contains(Int(month)) { return false }
        return true
    }
}

struct ParsedQuery: Equatable {
    var text: String
    var dateFilter: DateFilter?
}

enum QueryParser {
    private static let monthStems: [(String, Int)] = [
        ("январ", 1), ("феврал", 2), ("март", 3), ("апрел", 4), ("мая", 5), ("май", 5), ("мае", 5),
        ("июн", 6), ("июл", 7), ("август", 8), ("сентябр", 9), ("октябр", 10), ("ноябр", 11), ("декабр", 12),
        ("january", 1), ("february", 2), ("march", 3), ("april", 4), ("may", 5), ("june", 6),
        ("july", 7), ("august", 8), ("september", 9), ("october", 10), ("november", 11), ("december", 12),
    ]

    private static let seasonStems: [(String, [Int], String)] = [
        ("зим", [12, 1, 2], "зима"), ("весн", [3, 4, 5], "весна"), ("летом", [6, 7, 8], "лето"),
        ("лето", [6, 7, 8], "лето"), ("летн", [6, 7, 8], "лето"), ("осен", [9, 10, 11], "осень"),
        ("winter", [12, 1, 2], "зима"), ("spring", [3, 4, 5], "весна"), ("summer", [6, 7, 8], "лето"),
        ("autumn", [9, 10, 11], "осень"),
    ]

    /// Words that only make sense next to a date and are dropped once a date was found.
    private static let dateGlue: Set<String> = [
        "в", "во", "на", "за", "году", "год", "года", "г", "прошлом", "прошлой", "прошлую", "этом", "этой",
        "in", "on", "of", "during", "last", "this", "year",
    ]

    static func parse(_ query: String, now: Date = Date(), calendar: Calendar = .current) -> ParsedQuery {
        let tokens = query.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        let lower = tokens.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }

        var used = Set<Int>()
        var year: Int?
        var months: Set<Int> = []
        var labels: [String] = []
        var relative: (Date, Date, String)?

        func startOfDay(_ d: Date) -> Date { calendar.startOfDay(for: d) }
        func add(_ c: Calendar.Component, _ v: Int, to d: Date) -> Date { calendar.date(byAdding: c, value: v, to: d)! }

        func monthRange(offset: Int) -> (Date, Date) {
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            let from = add(.month, offset, to: start)
            return (from, add(.month, 1, to: from))
        }
        func yearRange(_ y: Int) -> (Date, Date) {
            let from = calendar.date(from: DateComponents(year: y, month: 1, day: 1))!
            return (from, add(.year, 1, to: from))
        }

        let joined = lower.joined(separator: " ")
        let today = startOfDay(now)
        let relatives: [(String, () -> (Date, Date), String)] = [
            ("сегодня", { (today, add(.day, 1, to: today)) }, "сегодня"),
            ("today", { (today, add(.day, 1, to: today)) }, "сегодня"),
            ("вчера", { (add(.day, -1, to: today), today) }, "вчера"),
            ("yesterday", { (add(.day, -1, to: today), today) }, "вчера"),
            ("прошлой неделе", { (add(.day, -14, to: today), add(.day, -7, to: today)) }, "прошлая неделя"),
            ("last week", { (add(.day, -14, to: today), add(.day, -7, to: today)) }, "прошлая неделя"),
            ("этой неделе", { (add(.day, -7, to: today), add(.day, 1, to: today)) }, "эта неделя"),
            ("прошлом месяце", { monthRange(offset: -1) }, "прошлый месяц"),
            ("last month", { monthRange(offset: -1) }, "прошлый месяц"),
            ("этом месяце", { monthRange(offset: 0) }, "этот месяц"),
            ("прошлом году", { yearRange(calendar.component(.year, from: now) - 1) }, "прошлый год"),
            ("last year", { yearRange(calendar.component(.year, from: now) - 1) }, "прошлый год"),
            ("этом году", { yearRange(calendar.component(.year, from: now)) }, "этот год"),
            ("this year", { yearRange(calendar.component(.year, from: now)) }, "этот год"),
        ]


        for (phrase, range, label) in relatives where joined.contains(phrase) {
            let (from, to) = range()
            relative = (from, to, label)
            let words = phrase.split(separator: " ").map(String.init)
            for (i, w) in lower.enumerated() where words.contains(w) { used.insert(i) }
            break
        }

        for (i, word) in lower.enumerated() where !used.contains(i) {
            if word.count == 4, let y = Int(word), (1990...2100).contains(y) {
                year = y
                used.insert(i)
                continue
            }
            if let hit = monthStems.first(where: { word.hasPrefix($0.0) && (word.count <= $0.0.count + 3) }) {
                months.insert(hit.1)
                labels.append(word)
                used.insert(i)
                continue
            }
            if let hit = seasonStems.first(where: { word.hasPrefix($0.0) }) {
                months.formUnion(hit.1)
                labels.append(hit.2)
                used.insert(i)
            }
        }

        var filter: DateFilter?
        if let relative {
            filter = DateFilter(from: relative.0, to: relative.1, label: relative.2)
        } else if let year {
            let (from, to) = yearRange(year)
            filter = DateFilter(from: from, to: to, months: months, label: (labels + [String(year)]).joined(separator: " "))
        } else if !months.isEmpty {
            filter = DateFilter(from: nil, to: nil, months: months, label: labels.joined(separator: " "))
        }

        guard filter != nil else {
            return ParsedQuery(text: query.trimmingCharacters(in: .whitespaces), dateFilter: nil)
        }

        let rest = tokens.enumerated()
            .filter { !used.contains($0.offset) && !dateGlue.contains(lower[$0.offset]) }
            .map { $0.element }
            .joined(separator: " ")
        return ParsedQuery(text: rest, dateFilter: filter)
    }
}
