// SPDX-License-Identifier: GPL-3.0-or-later
//
// Phase 1 storage: a flat float matrix plus a list of photo identifiers, saved
// as two files in Application Support. Good enough for the experiment; phase 2
// moves this into SQLite.

import Foundation

struct SearchHit: Identifiable, Hashable {
    let id: String   // PHAsset.localIdentifier
    let score: Float
}

final class EmbeddingStore {
    private(set) var ids: [String] = []
    private(set) var vectors: [Float] = []
    private(set) var dimension: Int = 0
    private var known: Set<String> = []

    private let directory: URL
    private var idsURL: URL { directory.appendingPathComponent("photo_ids.json") }
    private var vectorsURL: URL { directory.appendingPathComponent("photo_vectors.f32") }
    private var metaURL: URL { directory.appendingPathComponent("photo_meta.json") }

    private struct Meta: Codable {
        let dimension: Int
        let model: String
    }

    var count: Int { ids.count }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = base.appendingPathComponent("Index", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    func contains(_ id: String) -> Bool { known.contains(id) }

    func add(id: String, vector: [Float]) {
        guard !known.contains(id) else { return }
        if dimension == 0 { dimension = vector.count }
        guard vector.count == dimension else { return }
        ids.append(id)
        vectors.append(contentsOf: vector)
        known.insert(id)
    }

    func search(_ query: [Float], limit: Int) -> [SearchHit] {
        guard query.count == dimension, !ids.isEmpty else { return [] }
        let scores = VectorMath.scores(query: query, matrix: vectors, rows: ids.count)
        let top = scores.enumerated().sorted { $0.element > $1.element }.prefix(limit)
        return top.map { SearchHit(id: ids[$0.offset], score: $0.element) }
    }

    func save() {
        do {
            try JSONEncoder().encode(ids).write(to: idsURL, options: .atomic)
            let data = vectors.withUnsafeBufferPointer { Data(buffer: $0) }
            try data.write(to: vectorsURL, options: .atomic)
            try JSONEncoder().encode(Meta(dimension: dimension, model: MobileCLIP.variant)).write(to: metaURL, options: .atomic)
        } catch {
            AppLog.shared.add("Ошибка сохранения индекса: \(error.localizedDescription)")
        }
    }

    func reset() {
        ids = []
        vectors = []
        dimension = 0
        known = []
        try? FileManager.default.removeItem(at: idsURL)
        try? FileManager.default.removeItem(at: vectorsURL)
        try? FileManager.default.removeItem(at: metaURL)
    }

    private func load() {
        guard
            let metaData = try? Data(contentsOf: metaURL),
            let meta = try? JSONDecoder().decode(Meta.self, from: metaData),
            meta.model == MobileCLIP.variant,
            let idsData = try? Data(contentsOf: idsURL),
            let loadedIds = try? JSONDecoder().decode([String].self, from: idsData),
            let vectorData = try? Data(contentsOf: vectorsURL)
        else { return }

        let floats = vectorData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard floats.count == loadedIds.count * meta.dimension else { return }
        ids = loadedIds
        vectors = floats
        dimension = meta.dimension
        known = Set(loadedIds)
    }
}
