// SPDX-License-Identifier: GPL-3.0-or-later
//
// Local mail storage: Application Support/Index/mail.sqlite.
// `messages` keeps the text of each email, `mail_fts` is an FTS5 word index,
// `mail_chunks` keeps embedding vectors (several per email), mirrored in memory
// as one flat matrix for brute-force cosine search.

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum MailStoreError: LocalizedError {
    case sqlite(String)
    var errorDescription: String? {
        if case .sqlite(let m) = self { return "SQLite (почта): \(m)" }
        return nil
    }
}

actor MailStore {
    private var db: OpaquePointer?

    private var knownIds = Set<String>()
    private var dates: [String: Double] = [:]          // message id → seconds since 1970

    // Embedding mirror: one row per chunk.
    private var chunkOwner: [String] = []
    private var chunkVectors: [Float] = []
    private var dimension = 0
    private var vectorModel: String?

    var count: Int { knownIds.count }

    init(path: String? = nil) throws {
        let file: String
        if let path {
            file = path
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let directory = base.appendingPathComponent("Index", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            file = directory.appendingPathComponent("mail.sqlite").path
        }
        var handle: OpaquePointer?
        guard sqlite3_open(file, &handle) == SQLITE_OK else { throw MailStoreError.sqlite("open failed") }
        db = handle
        try Self.exec(handle, "PRAGMA journal_mode=WAL")
        try Self.exec(handle, """
            CREATE TABLE IF NOT EXISTS messages(
                id TEXT PRIMARY KEY,
                thread_id TEXT NOT NULL,
                subject TEXT NOT NULL,
                sender TEXT NOT NULL,
                recipients TEXT NOT NULL,
                date REAL,
                snippet TEXT NOT NULL,
                body TEXT NOT NULL,
                labels TEXT NOT NULL,
                attachments TEXT NOT NULL,
                embedded_model TEXT
            )
            """)
        try Self.exec(handle, """
            CREATE VIRTUAL TABLE IF NOT EXISTS mail_fts USING fts5(
                id UNINDEXED, subject, sender, body, tokenize = 'unicode61 remove_diacritics 2'
            )
            """)
        try Self.exec(handle, """
            CREATE TABLE IF NOT EXISTS mail_chunks(
                message_id TEXT NOT NULL,
                idx INTEGER NOT NULL,
                model TEXT NOT NULL,
                vector BLOB NOT NULL,
                PRIMARY KEY(message_id, idx)
            )
            """)
        // Load ids and dates (cheap) so sync can skip what is already here.
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, "SELECT id, date FROM messages", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let c = sqlite3_column_text(stmt, 0) else { continue }
                let id = String(cString: c)
                knownIds.insert(id)
                if sqlite3_column_type(stmt, 1) != SQLITE_NULL { dates[id] = sqlite3_column_double(stmt, 1) }
            }
        }
        sqlite3_finalize(stmt)
    }

    deinit { sqlite3_close(db) }

    func contains(_ id: String) -> Bool { knownIds.contains(id) }
    func missing(from ids: [String]) -> [String] { ids.filter { !knownIds.contains($0) } }

    // MARK: - Writing

    func insert(_ messages: [MailMessage]) throws {
        try exec("BEGIN")
        defer { try? exec("COMMIT") }
        for m in messages where !knownIds.contains(m.id) {
            try withStatement("""
                INSERT OR REPLACE INTO messages(id, thread_id, subject, sender, recipients, date, snippet, body, labels, attachments)
                VALUES(?,?,?,?,?,?,?,?,?,?)
                """) { stmt in
                bind(stmt, 1, m.id); bind(stmt, 2, m.threadId); bind(stmt, 3, m.subject)
                bind(stmt, 4, m.sender); bind(stmt, 5, m.recipients)
                if let d = m.date { sqlite3_bind_double(stmt, 6, d.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 6) }
                bind(stmt, 7, m.snippet); bind(stmt, 8, m.body)
                bind(stmt, 9, m.labels.joined(separator: ",")); bind(stmt, 10, m.attachments.joined(separator: "\n"))
                try step(stmt)
            }
            try withStatement("INSERT INTO mail_fts(id, subject, sender, body) VALUES(?,?,?,?)") { stmt in
                bind(stmt, 1, m.id); bind(stmt, 2, m.subject); bind(stmt, 3, m.sender)
                bind(stmt, 4, m.body + (m.attachments.isEmpty ? "" : "\n" + m.attachments.joined(separator: " ")))
                try step(stmt)
            }
            knownIds.insert(m.id)
            if let d = m.date { dates[m.id] = d.timeIntervalSince1970 }
        }
    }

    func deleteAll() {
        try? exec("DELETE FROM messages")
        try? exec("DELETE FROM mail_fts")
        try? exec("DELETE FROM mail_chunks")
        try? exec("VACUUM")
        knownIds = []; dates = [:]
        chunkOwner = []; chunkVectors = []; dimension = 0; vectorModel = nil
    }

    // MARK: - Embeddings

    /// Emails not yet embedded with `model`, newest first.
    func pendingEmbedding(model: String, limit: Int) -> [MailMessage] {
        var result: [MailMessage] = []
        try? withStatement("""
            SELECT \(Self.columns) FROM messages
            WHERE embedded_model IS NULL OR embedded_model != ?
            ORDER BY date DESC LIMIT ?
            """) { stmt in
            bind(stmt, 1, model)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW { result.append(Self.message(from: stmt)) }
        }
        return result
    }

    func pendingEmbeddingCount(model: String) -> Int {
        var n = 0
        try? withStatement("SELECT COUNT(*) FROM messages WHERE embedded_model IS NULL OR embedded_model != ?") { stmt in
            bind(stmt, 1, model)
            if sqlite3_step(stmt) == SQLITE_ROW { n = Int(sqlite3_column_int(stmt, 0)) }
        }
        return n
    }

    func saveVectors(_ vectors: [String: [[Float]]], model: String) throws {
        loadVectorsIfNeeded(model: model)
        try exec("BEGIN")
        defer { try? exec("COMMIT") }
        for (id, chunks) in vectors {
            try withStatement("DELETE FROM mail_chunks WHERE message_id = ?") { stmt in bind(stmt, 1, id); try step(stmt) }
            for (i, v) in chunks.enumerated() {
                if dimension == 0 { dimension = v.count }
                guard v.count == dimension else { continue }
                let unit = VectorMath.normalized(v)
                try withStatement("INSERT INTO mail_chunks(message_id, idx, model, vector) VALUES(?,?,?,?)") { stmt in
                    bind(stmt, 1, id); sqlite3_bind_int(stmt, 2, Int32(i)); bind(stmt, 3, model)
                    _ = unit.withUnsafeBytes { raw in sqlite3_bind_blob(stmt, 4, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT) }
                    try step(stmt)
                }
                chunkOwner.append(id)
                chunkVectors.append(contentsOf: unit)
            }
            try withStatement("UPDATE messages SET embedded_model = ? WHERE id = ?") { stmt in
                bind(stmt, 1, model); bind(stmt, 2, id); try step(stmt)
            }
        }
    }

    private func loadVectorsIfNeeded(model: String) {
        guard vectorModel != model else { return }
        vectorModel = model
        chunkOwner = []; chunkVectors = []; dimension = 0
        try? withStatement("SELECT message_id, vector FROM mail_chunks WHERE model = ? ORDER BY rowid") { stmt in
            bind(stmt, 1, model)
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idText = sqlite3_column_text(stmt, 0), let blob = sqlite3_column_blob(stmt, 1) else { continue }
                let n = Int(sqlite3_column_bytes(stmt, 1)) / MemoryLayout<Float>.size
                if dimension == 0 { dimension = n }
                guard n == dimension else { continue }
                chunkOwner.append(String(cString: idText))
                chunkVectors.append(contentsOf: UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: n))
            }
        }
    }

    // MARK: - Search

    /// Hybrid search: FTS5 words + embedding similarity, fused by reciprocal rank.
    /// `queryVector` is nil when no embedder is available.
    func search(words: [String], queryVector: [Float]?, model: String?, filter: DateFilter?, limit: Int = 60) -> [MailHit] {
        let calendar = Calendar.current
        func allowed(_ id: String) -> Bool {
            guard let filter else { return true }
            guard let seconds = dates[id] else { return false }
            let month = UInt8(calendar.component(.month, from: Date(timeIntervalSince1970: seconds)))
            return filter.matches(seconds: seconds, month: month)
        }

        let textRanked = ftsMatches(words: words).filter(allowed)
        var semantic: [String] = []
        var best: [String: Float] = [:]
        if let queryVector, let model {
            loadVectorsIfNeeded(model: model)
            if dimension == queryVector.count, !chunkOwner.isEmpty {
                let scores = VectorMath.scores(query: VectorMath.normalized(queryVector), matrix: chunkVectors, rows: chunkOwner.count)
                for (row, score) in scores.enumerated() {
                    let id = chunkOwner[row]
                    if score > best[id] ?? -1 { best[id] = score }
                }
                let ranked = best.filter { allowed($0.key) }.sorted { $0.value > $1.value }
                if let top = ranked.first?.value {
                    // Keep emails reasonably close to the best one.
                    semantic = ranked.prefix { $0.value >= top - 0.08 }.prefix(200).map(\.key)
                }
            }
        }

        if words.isEmpty && queryVector == nil {
            // Only a date (or nothing): newest first.
            let ids = dates.filter { allowed($0.key) }.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
            return hits(for: ids, scores: [:], textMatches: [])
        }

        var fused: [String: Double] = [:]
        for (rank, id) in textRanked.enumerated() { fused[id, default: 0] += 1.0 / Double(60 + rank) }
        for (rank, id) in semantic.enumerated() { fused[id, default: 0] += 1.0 / Double(60 + rank) }
        let top = fused.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
        return hits(for: top, scores: best, textMatches: Set(textRanked))
    }

    /// Ids whose subject/sender/body contain the words, best first (bm25, subject weighs most).
    private func ftsMatches(words: [String]) -> [String] {
        let terms = words
            .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
            .filter { $0.count >= 3 || ($0.count == 2 && $0.allSatisfy(\.isNumber)) }
        guard !terms.isEmpty else { return [] }
        let match = terms.map { "\"\($0)\"*" }.joined(separator: " OR ")
        var ids: [String] = []
        try? withStatement("SELECT id FROM mail_fts WHERE mail_fts MATCH ? ORDER BY bm25(mail_fts, 0.0, 5.0, 3.0, 1.0) LIMIT 300") { stmt in
            bind(stmt, 1, match)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) { ids.append(String(cString: c)) }
            }
        }
        return ids
    }

    private func hits(for ids: [String], scores: [String: Float], textMatches: Set<String>) -> [MailHit] {
        ids.compactMap { id in
            guard let m = message(id: id) else { return nil }
            return MailHit(
                id: id, subject: m.subject.isEmpty ? "(без темы)" : m.subject, sender: m.senderName,
                snippet: m.snippet, date: m.date, score: scores[id] ?? 0, textMatch: textMatches.contains(id)
            )
        }
    }

    // MARK: - Reading

    func message(id: String) -> MailMessage? {
        var result: MailMessage?
        try? withStatement("SELECT \(Self.columns) FROM messages WHERE id = ?") { stmt in
            bind(stmt, 1, id)
            if sqlite3_step(stmt) == SQLITE_ROW { result = Self.message(from: stmt) }
        }
        return result
    }

    func newestDate() -> Date? {
        dates.values.max().map { Date(timeIntervalSince1970: $0) }
    }

    // MARK: - SQLite helpers

    private static let columns = "id, thread_id, subject, sender, recipients, date, snippet, body, labels, attachments"

    private static func message(from stmt: OpaquePointer?) -> MailMessage {
        func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        let date = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
        return MailMessage(
            id: text(0), threadId: text(1), subject: text(2), sender: text(3), recipients: text(4), date: date,
            snippet: text(6), body: text(7),
            labels: text(8).split(separator: ",").map(String.init),
            attachments: text(9).split(separator: "\n").map(String.init)
        )
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    private func exec(_ sql: String) throws { try Self.exec(db, sql) }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw MailStoreError.sqlite(message)
        }
    }

    private func withStatement(_ sql: String, _ body: (OpaquePointer?) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MailStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        try body(stmt)
    }

    private func step(_ stmt: OpaquePointer?) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw MailStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }
}
