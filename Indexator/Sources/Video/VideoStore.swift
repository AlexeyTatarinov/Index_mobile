// SPDX-License-Identifier: GPL-3.0-or-later
//
// SQLite storage for the video index (Application Support/Index/videos.sqlite).
// Each video has a few keyframe vectors with their time in the video, so a
// search can say not only which video matches but also at which second.
// Speech recognized in the video goes to an FTS5 table, also with times.

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct VideoFrame {
    let time: Double
    let vector: [Float]
}

struct SpeechChunk: Equatable {
    let time: Double
    let text: String
}

struct VideoRecord {
    let id: String
    let created: Date?
    let duration: Double
    let latitude: Double?
    let longitude: Double?
    let frames: [VideoFrame]
    let speech: [SpeechChunk]
}

final class VideoStore {
    private var db: OpaquePointer?
    let model: String

    // Per video, in memory.
    private(set) var ids: [String] = []
    private(set) var created: [Double] = []     // NaN when unknown
    private(set) var months: [UInt8] = []
    private(set) var durations: [Double] = []
    private var rowOf: [String: Int] = [:]

    // Per keyframe, in memory: one flat matrix for brute-force search.
    private(set) var frameVideo: [Int32] = []
    private(set) var frameTime: [Float] = []
    private(set) var frameVectors: [Float] = []
    private(set) var dimension = 0

    var count: Int { ids.count }
    var frameCount: Int { frameVideo.count }

    init(model: String) throws {
        self.model = model
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("Index", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("videos.sqlite").path
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw IndexDatabaseError.sqlite("open failed")
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("""
            CREATE TABLE IF NOT EXISTS videos(
                id TEXT PRIMARY KEY,
                created REAL,
                duration REAL NOT NULL DEFAULT 0,
                lat REAL,
                lon REAL,
                model TEXT NOT NULL
            )
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS video_frames(
                video TEXT NOT NULL,
                time REAL NOT NULL,
                vector BLOB NOT NULL
            )
            """)
        try exec("CREATE INDEX IF NOT EXISTS video_frames_video ON video_frames(video)")
        try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS video_speech USING fts5(
                video UNINDEXED, time UNINDEXED, text, tokenize = 'unicode61 remove_diacritics 2'
            )
            """)
        try loadAll()
    }

    deinit { sqlite3_close(db) }

    func contains(_ id: String) -> Bool { rowOf[id] != nil }
    func row(of id: String) -> Int? { rowOf[id] }

    // MARK: - Writing

    func insert(_ record: VideoRecord) throws {
        guard !contains(record.id) else { return }
        let frames = record.frames.filter { dimension == 0 || $0.vector.count == dimension }
        try exec("BEGIN")
        do {
            try withStatement("INSERT OR REPLACE INTO videos(id, created, duration, lat, lon, model) VALUES(?,?,?,?,?,?)") { stmt in
                sqlite3_bind_text(stmt, 1, record.id, -1, SQLITE_TRANSIENT)
                bindOptional(stmt, 2, record.created?.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 3, record.duration)
                bindOptional(stmt, 4, record.latitude)
                bindOptional(stmt, 5, record.longitude)
                sqlite3_bind_text(stmt, 6, model, -1, SQLITE_TRANSIENT)
                try step(stmt)
            }
            for frame in frames {
                try withStatement("INSERT INTO video_frames(video, time, vector) VALUES(?,?,?)") { stmt in
                    sqlite3_bind_text(stmt, 1, record.id, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_double(stmt, 2, frame.time)
                    _ = frame.vector.withUnsafeBytes { raw in
                        sqlite3_bind_blob(stmt, 3, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
                    }
                    try step(stmt)
                }
            }
            for chunk in record.speech where !chunk.text.isEmpty {
                try withStatement("INSERT INTO video_speech(video, time, text) VALUES(?,?,?)") { stmt in
                    sqlite3_bind_text(stmt, 1, record.id, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_double(stmt, 2, chunk.time)
                    sqlite3_bind_text(stmt, 3, chunk.text, -1, SQLITE_TRANSIENT)
                    try step(stmt)
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        let row = appendVideo(id: record.id, created: record.created?.timeIntervalSince1970, duration: record.duration)
        for frame in frames { appendFrame(row: row, time: frame.time, vector: frame.vector) }
    }

    func reset() {
        try? exec("DELETE FROM videos")
        try? exec("DELETE FROM video_frames")
        try? exec("DELETE FROM video_speech")
        ids = []; created = []; months = []; durations = []; rowOf = [:]
        frameVideo = []; frameTime = []; frameVectors = []; dimension = 0
    }

    // MARK: - Reading

    /// Speech chunks matching any of the words: (video row, time, text), best first.
    func speechMatches(words: [String], limit: Int = 200) -> [(row: Int, time: Double, text: String)] {
        let terms = words
            .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
            .filter { $0.count >= 3 }
        guard !terms.isEmpty else { return [] }
        let match = terms.map { "\"\($0)\"*" }.joined(separator: " OR ")
        var result: [(row: Int, time: Double, text: String)] = []
        try? withStatement("SELECT video, time, text FROM video_speech WHERE video_speech MATCH ? ORDER BY rank LIMIT ?") { stmt in
            sqlite3_bind_text(stmt, 1, match, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let c = sqlite3_column_text(stmt, 0), let row = rowOf[String(cString: c)] else { continue }
                let text = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                result.append((row, sqlite3_column_double(stmt, 1), text))
            }
        }
        return result
    }

    /// Everything said in a video, in order.
    func transcript(for id: String) -> [SpeechChunk] {
        var chunks: [SpeechChunk] = []
        try? withStatement("SELECT time, text FROM video_speech WHERE video = ? ORDER BY time") { stmt in
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let text = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                chunks.append(SpeechChunk(time: sqlite3_column_double(stmt, 0), text: text))
            }
        }
        return chunks
    }

    // MARK: - Internals

    private func loadAll() throws {
        try withStatement("SELECT id, created, duration FROM videos WHERE model = ? ORDER BY rowid") { stmt in
            sqlite3_bind_text(stmt, 1, model, -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idText = sqlite3_column_text(stmt, 0) else { continue }
                let createdValue = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 1)
                _ = appendVideo(id: String(cString: idText), created: createdValue, duration: sqlite3_column_double(stmt, 2))
            }
        }
        try withStatement("SELECT video, time, vector FROM video_frames ORDER BY rowid") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idText = sqlite3_column_text(stmt, 0),
                      let row = rowOf[String(cString: idText)],
                      let blob = sqlite3_column_blob(stmt, 2) else { continue }
                let n = Int(sqlite3_column_bytes(stmt, 2)) / MemoryLayout<Float>.size
                let vector = Array(UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: n))
                appendFrame(row: row, time: sqlite3_column_double(stmt, 1), vector: vector)
            }
        }
    }

    private func appendVideo(id: String, created seconds: Double?, duration: Double) -> Int {
        let row = ids.count
        rowOf[id] = row
        ids.append(id)
        created.append(seconds ?? .nan)
        months.append(seconds.map { UInt8(Calendar.current.component(.month, from: Date(timeIntervalSince1970: $0))) } ?? 0)
        durations.append(duration)
        return row
    }

    private func appendFrame(row: Int, time: Double, vector: [Float]) {
        if dimension == 0 { dimension = vector.count }
        guard vector.count == dimension else { return }
        frameVideo.append(Int32(row))
        frameTime.append(Float(time))
        frameVectors.append(contentsOf: vector)
    }

    private func bindOptional(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
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
}
