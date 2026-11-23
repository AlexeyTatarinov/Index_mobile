// SPDX-License-Identifier: GPL-3.0-or-later
//
// SQLite storage for the photo index. Vectors live in the `photos` table and are
// also kept in memory as one flat matrix for brute-force search. Text found on
// photos (OCR) goes to an FTS5 table for keyword search.

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum IndexDatabaseError: LocalizedError {
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message): return "SQLite: \(message)"
        }
    }
}

struct PhotoRecord {
    let id: String
    let created: Date?
    let latitude: Double?
    let longitude: Double?
    let vector: [Float]
    let text: String
}

final class IndexDatabase {
    private var db: OpaquePointer?

    // In-memory mirror used for search.
    private(set) var ids: [String] = []
    private(set) var created: [Double] = []      // seconds since 1970, NaN when unknown
    private(set) var months: [UInt8] = []        // 1...12, 0 when unknown
    private(set) var latitudes: [Double] = []    // NaN when unknown
    private(set) var longitudes: [Double] = []
    private(set) var vectors: [Float] = []
    private(set) var dimension = 0
    private var rowOf: [String: Int] = [:]

    let model: String
    var count: Int { ids.count }
    var newestCreated: Date? {
        let valid = created.filter { !$0.isNaN }
        return valid.max().map { Date(timeIntervalSince1970: $0) }
    }

    init(model: String) throws {
        self.model = model
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("Index", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("index.sqlite").path

        if sqlite3_open(path, &db) != SQLITE_OK {
            throw IndexDatabaseError.sqlite("open failed")
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("""
            CREATE TABLE IF NOT EXISTS photos(
                id TEXT PRIMARY KEY,
                created REAL,
                lat REAL,
                lon REAL,
                model TEXT NOT NULL,
                vector BLOB NOT NULL,
                ocr TEXT NOT NULL DEFAULT ''
            )
            """)
        try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS photo_text USING fts5(
                id UNINDEXED, text, tokenize = 'unicode61 remove_diacritics 2'
            )
            """)
        try loadAll()
        removeLegacyFiles(in: directory)
    }

    deinit {
        sqlite3_close(db)
    }

    func contains(_ id: String) -> Bool { rowOf[id] != nil }

    // MARK: - Writing

    func begin() { try? exec("BEGIN") }
    func commit() { try? exec("COMMIT") }

    func insert(_ record: PhotoRecord) throws {
        guard !contains(record.id) else { return }
        if dimension == 0 { dimension = record.vector.count }
        guard record.vector.count == dimension else { return }

        let sql = "INSERT OR REPLACE INTO photos(id, created, lat, lon, model, vector, ocr) VALUES(?,?,?,?,?,?,?)"
        try withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, record.id, -1, SQLITE_TRANSIENT)
            bindOptional(stmt, 2, record.created?.timeIntervalSince1970)
            bindOptional(stmt, 3, record.latitude)
            bindOptional(stmt, 4, record.longitude)
            sqlite3_bind_text(stmt, 5, model, -1, SQLITE_TRANSIENT)
            _ = record.vector.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 6, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_text(stmt, 7, record.text, -1, SQLITE_TRANSIENT)
            try step(stmt)
        }
        if !record.text.isEmpty {
            try withStatement("INSERT INTO photo_text(id, text) VALUES(?, ?)") { stmt in
                sqlite3_bind_text(stmt, 1, record.id, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, record.text, -1, SQLITE_TRANSIENT)
                try step(stmt)
            }
        }
        appendInMemory(id: record.id, created: record.created?.timeIntervalSince1970,
                       lat: record.latitude, lon: record.longitude, vector: record.vector)
    }

    func reset() {
        try? exec("DELETE FROM photos")
        try? exec("DELETE FROM photo_text")
        ids = []; created = []; months = []; latitudes = []; longitudes = []
        vectors = []; dimension = 0; rowOf = [:]
    }

    // MARK: - Reading

    func text(for id: String) -> String? {
        var result: String?
        try? withStatement("SELECT ocr FROM photos WHERE id = ?") { stmt in
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
                result = String(cString: c)
            }
        }
        return result
    }

    /// Row indexes whose OCR text matches any of the words, best match first.
    func textMatches(words: [String], limit: Int = 300) -> [Int] {
        let terms = words
            .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
            .filter { $0.count >= 3 }
        guard !terms.isEmpty else { return [] }
        let match = terms.map { "\"\($0)\"*" }.joined(separator: " OR ")
        var rows: [Int] = []
        try? withStatement("SELECT id FROM photo_text WHERE photo_text MATCH ? ORDER BY rank LIMIT ?") { stmt in
            sqlite3_bind_text(stmt, 1, match, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0), let row = rowOf[String(cString: c)] {
                    rows.append(row)
                }
            }
        }
        return rows
    }

    // MARK: - Internals

    private func loadAll() throws {
        try withStatement("SELECT id, created, lat, lon, vector FROM photos WHERE model = ? ORDER BY rowid") { stmt in
            sqlite3_bind_text(stmt, 1, model, -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idText = sqlite3_column_text(stmt, 0), let blob = sqlite3_column_blob(stmt, 4) else { continue }
                let bytes = Int(sqlite3_column_bytes(stmt, 4))
                let count = bytes / MemoryLayout<Float>.size
                let vector = Array(UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: count))
                if dimension == 0 { dimension = count }
                guard count == dimension else { continue }
                appendInMemory(
                    id: String(cString: idText),
                    created: columnDouble(stmt, 1),
                    lat: columnDouble(stmt, 2),
                    lon: columnDouble(stmt, 3),
                    vector: vector
                )
            }
        }
    }

    private func appendInMemory(id: String, created seconds: Double?, lat: Double?, lon: Double?, vector: [Float]) {
        rowOf[id] = ids.count
        ids.append(id)
        created.append(seconds ?? .nan)
        if let seconds {
            months.append(UInt8(Calendar.current.component(.month, from: Date(timeIntervalSince1970: seconds))))
        } else {
            months.append(0)
        }
        latitudes.append(lat ?? .nan)
        longitudes.append(lon ?? .nan)
        vectors.append(contentsOf: vector)
    }

    private func columnDouble(_ stmt: OpaquePointer?, _ index: Int32) -> Double? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, index)
    }

    private func bindOptional(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw IndexDatabaseError.sqlite(message)
        }
    }

    private func withStatement(_ sql: String, _ body: (OpaquePointer?) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw IndexDatabaseError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        try body(stmt)
    }

    private func step(_ stmt: OpaquePointer?) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw IndexDatabaseError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Phase 1 kept the index in flat files; it is rebuilt rather than migrated.
    private func removeLegacyFiles(in directory: URL) {
        for name in ["photo_ids.json", "photo_vectors.f32", "photo_meta.json"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
