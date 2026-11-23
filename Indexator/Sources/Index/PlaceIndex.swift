// SPDX-License-Identifier: GPL-3.0-or-later
//
// Offline city lookup from GeoNames (cities over 15 000 people, CC BY 4.0).
// Two jobs: find a city named in a query («архитектура Валенсии»), and give a
// photo's coordinates a readable place name. Nothing leaves the phone.

import Foundation

struct Place {
    let latitude: Double
    let longitude: Double
    let population: Int
    let country: String
    let name: String
    let russianName: String

    var displayName: String { russianName.isEmpty ? name : russianName }
}

struct PlaceMatch {
    let places: [Place]      // candidates with this name, most populous first
    let words: Set<String>   // query words that named the place
}

final class PlaceIndex {
    static let shared = PlaceIndex()

    private var places: [Place] = []
    private var byName: [String: [Int]] = [:]
    private var byStem: [String: [Int]] = [:]
    private var grid: [Int: [Int]] = [:]
    private let lock = NSLock()
    private var loaded = false

    /// Words that are also small-town names somewhere but almost always mean something else.
    private static let stopWords: Set<String> = [
        "фото", "photo", "море", "лес", "парк", "сад", "дом", "мост", "озеро", "река", "горы", "пляж",
        "город", "улица", "центр", "еда", "мир", "красный", "белый", "новый", "старый", "собака", "кот",
        "для", "без", "под", "над", "при", "все", "мой", "моя", "мои", "как", "что", "это", "где", "там",
        "the", "and", "for", "with", "home", "park", "beach", "lake", "river", "city", "center", "garden", "food", "new", "old",
    ]

    var count: Int { ensureLoaded(); return places.count }

    private func ensureLoaded() {
        lock.lock()
        defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        guard let url = Bundle.main.url(forResource: "places", withExtension: "tsv", subdirectory: "Models")
                ?? Bundle.main.url(forResource: "places", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            AppLog.shared.add("База городов не найдена")
            return
        }
        text.enumerateLines { line, _ in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 7, let lat = Double(f[0]), let lon = Double(f[1]) else { return }
            let index = self.places.count
            self.places.append(Place(
                latitude: lat, longitude: lon, population: Int(f[2]) ?? 0, country: String(f[3]),
                name: String(f[4]), russianName: String(f[5])
            ))
            for name in f[6].split(separator: "|") {
                let n = String(name)
                self.byName[n, default: []].append(index)
                if Self.isCyrillic(n) { self.byStem[Self.stem(n), default: []].append(index) }
            }
            self.grid[Self.cell(lat, lon), default: []].append(index)
        }
    }

    // MARK: - Query

    /// Finds a city named in the query. One- and two-word names; Russian case endings
    /// are ignored («в Валенсии», «из Барселоны»).
    func match(in text: String) -> PlaceMatch? {
        ensureLoaded()
        let words = Self.normalize(text).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        var best: PlaceMatch?
        func consider(_ indices: [Int], _ used: [String]) {
            let candidates = indices.map { places[$0] }.sorted { $0.population > $1.population }
            guard let top = candidates.first else { return }
            if let best, let current = best.places.first, current.population >= top.population { return }
            best = PlaceMatch(places: candidates, words: Set(used))
        }
        for i in words.indices {
            if i + 1 < words.count {
                let pair = [words[i], words[i + 1]]
                if let hit = lookup(pair.joined(separator: " ")) { consider(hit, pair) }
            }
            let word = words[i]
            guard word.count >= 3, !Self.stopWords.contains(word) else { continue }
            if let hit = lookup(word) { consider(hit, [word]) }
        }
        return best
    }

    private func lookup(_ phrase: String) -> [Int]? {
        if let exact = byName[phrase] { return exact }
        if Self.isCyrillic(phrase), let stemmed = byStem[Self.stem(phrase)] { return stemmed }
        return nil
    }

    // MARK: - Reverse lookup

    /// Nearest known city within `maxKm`, for showing where a photo was taken.
    func nearest(latitude: Double, longitude: Double, maxKm: Double = 30) -> Place? {
        ensureLoaded()
        guard !latitude.isNaN, !longitude.isNaN else { return nil }
        var best: (Place, Double)?
        let lat0 = Int(floor(latitude)), lon0 = Int(floor(longitude))
        for dLat in -1...1 {
            for dLon in -1...1 {
                for index in grid[Self.cell(Double(lat0 + dLat), Double(lon0 + dLon))] ?? [] {
                    let p = places[index]
                    let d = Self.distanceKm(latitude, longitude, p.latitude, p.longitude)
                    // A big city a bit further away is a better answer than a suburb next door.
                    let weighted = d / (1 + log10(Double(max(p.population, 15_000)) / 15_000))
                    if d <= maxKm, best == nil || weighted < best!.1 { best = (p, weighted) }
                }
            }
        }
        return best?.0
    }

    // MARK: - Helpers

    static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }

    /// Radius that counts as "in this city": bigger cities spread further.
    static func radiusKm(for place: Place) -> Double {
        switch place.population {
        case 1_000_000...: return 35
        case 200_000...: return 20
        default: return 12
        }
    }

    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        let cleaned = lowered.map { $0.isLetter ? $0 : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    static func stem(_ word: String) -> String {
        for ending in ["иями", "ией", "ии", "ия", "ие", "ию", "ой", "ом", "ем", "ей", "а", "я", "ы", "и", "е", "у", "ю"]
        where word.count > ending.count + 2 && word.hasSuffix(ending) {
            return String(word.dropLast(ending.count))
        }
        return word
    }

    private static func isCyrillic(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    private static func cell(_ lat: Double, _ lon: Double) -> Int {
        Int(floor(lat) + 90) * 1000 + Int(floor(lon) + 180)
    }
}
