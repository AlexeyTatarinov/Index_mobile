// SPDX-License-Identifier: GPL-3.0-or-later
//
// SQLite storage for the document index (Application Support/Index/docs.sqlite),
// kept apart from the photo index. Folders are stored as security-scoped bookmarks,
// documents are split into chunks; each chunk has a text embedding (BLOB) and an
// FTS5 row for keyword search. Vectors are mirrored in memory for brute-force search.

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DocumentStoreError: LocalizedError {
    case sqlite(String)
    var errorDescription: String? {
        switch self {
        case .sqlite(let message): return "SQLite (документы): \(message)"
        }
    }
}

struct DocumentFolder: Identifiable, Hashable {
    let id: Int64
    let name: String
    let bookmark: Data
    let isDirectory: Bool
    let added: Date
}

struct StoredDocument {
    let id: Int64
    let folderId: Int64
    let path: String        // relative to the folder; "" when the folder entry is a single file
    let name: String
    let size: Int64
    let modified: Double
    let embedded: Bool
}

struct NewChunk {
    let page: Int?
    let text: String
    let vector: [Float]?
}

struct ChunkInfo {
    let chunkId: Int64
    let documentId: Int64
    let folderId: Int64
    let path: String
    let name: String
    let modified: Double
    let page: Int?
    let text: String
}

final class DocumentStore {
    private var db: OpaquePointer?
    let embedderName: String

    // In-memory mirror of chunks that have vectors.
    private(set) var vectorChunkIds: [Int64] = []
    private(set) var vectors: [Float] = []
    private(set) var dimension = 0

    init(embedderName: String) throws {
        self.embedderName = embedderName
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("Index", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("docs.sqlite").path
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw DocumentStoreError.sqlite("docs open failed")
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
        try exec("""
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS folders(
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                bookmark BLOB NOT NULL,
                is_dir INTEGER NOT NULL,
                added REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS documents(
                id INTEGER PRIMARY KEY,
                folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
                path TEXT NOT NULL,
                name TEXT NOT NULL,
                ext TEXT NOT NULL,
                size INTEGER NOT NULL,
                modified REAL NOT NULL,
                indexed REAL NOT NULL,
                chunks INTEGER NOT NULL,
                ocr INTEGER NOT NULL,
                embedded INTEGER NOT NULL,
                error TEXT,
                UNIQUE(folder_id, path)
            );
            CREATE TABLE IF NOT EXISTS chunks(
                id INTEGER PRIMARY KEY,
                doc_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                page INTEGER,
                text TEXT NOT NULL,
                vector BLOB
            );
            CREATE INDEX IF NOT EXISTS chunks_doc ON chunks(doc_id);
            CREATE VIRTUAL TABLE IF NOT EXISTS chunk_text USING fts5(
                text, tokenize = 'unicode61 remove_diacritics 2'
            );
            """)
        // A different embedding model makes stored vectors useless: drop them and re-embed.
        if metaValue("embedder") != embedderName {
            try exec("UPDATE chunks SET vector = NULL; UPDATE documents SET embedded = 0;")
            setMeta("embedder", embedderName)
        }
        loadVectors()
    }

    deinit {
        sqlite3_close(db)
    }

    var vectorCount: Int { vectorChunkIds.count }

    // MARK: - Folders

    func folders() -> [DocumentFolder] {
        var result: [DocumentFolder] = []
        try? withStatement("SELECT id, name, bookmark, is_dir, added FROM folders ORDER BY added") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(DocumentFolder(
                    id: sqlite3_column_int64(stmt, 0),
                    name: columnText(stmt, 1),
                    bookmark: columnData(stmt, 2) ?? Data(),
                    isDirectory: sqlite3_column_int(stmt, 3) != 0,
                    added: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                ))
            }
        }
        return result
    }

    @discardableResult
    func addFolder(name: String, bookmark: Data, isDirectory: Bool) throws -> Int64 {
        try withStatement("INSERT INTO folders(name, bookmark, is_dir, added) VALUES(?,?,?,?)") { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            bindData(stmt, 2, bookmark)
            sqlite3_bind_int(stmt, 3, isDirectory ? 1 : 0)
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
            try step(stmt)
        }
        return sqlite3_last_insert_rowid(db)
    }

    func updateBookmark(folderId: Int64, bookmark: Data) {
        try? withStatement("UPDATE folders SET bookmark = ? WHERE id = ?") { stmt in
            bindData(stmt, 1, bookmark)
            sqlite3_bind_int64(stmt, 2, folderId)
            try step(stmt)
        }
    }

    func removeFolder(id: Int64) {
        for doc in documents(folderId: id) {
            deleteDocument(id: doc.id)
        }
        try? withStatement("DELETE FROM folders WHERE id = ?") { stmt in
            sqlite3_bind_int64(stmt, 1, id)
            try step(stmt)
        }
        loadVectors()
    }

    // MARK: - Documents

    func documents(folderId: Int64) -> [StoredDocument] {
        var result: [StoredDocument] = []
        try? withStatement("SELECT id, folder_id, path, name, size, modified, embedded FROM documents WHERE folder_id = ?") { stmt in
            sqlite3_bind_int64(stmt, 1, folderId)
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(StoredDocument(
                    id: sqlite3_column_int64(stmt, 0),
                    folderId: sqlite3_column_int64(stmt, 1),
                    path: columnText(stmt, 2),
                    name: columnText(stmt, 3),
                    size: sqlite3_column_int64(stmt, 4),
                    modified: sqlite3_column_double(stmt, 5),
                    embedded: sqlite3_column_int(stmt, 6) != 0
                ))
            }
        }
        return result
    }

    struct Stats {
        var documents = 0
        var chunks = 0
        var withOCR = 0
        var failed = 0
    }

    func stats(folderId: Int64? = nil) -> Stats {
        var s = Stats()
        let filter = folderId.map { " WHERE folder_id = \($0)" } ?? ""
        try? withStatement("SELECT COUNT(*), COALESCE(SUM(chunks),0), COALESCE(SUM(ocr),0), COALESCE(SUM(error IS NOT NULL),0) FROM documents\(filter)") { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                s.documents = Int(sqlite3_column_int64(stmt, 0))
                s.chunks = Int(sqlite3_column_int64(stmt, 1))
                s.withOCR = Int(sqlite3_column_int64(stmt, 2))
                s.failed = Int(sqlite3_column_int64(stmt, 3))
            }
        }
        return s
    }

    /// Replaces a document and its chunks. Vectors are added to the in-memory mirror.
    func saveDocument(folderId: Int64, path: String, name: String, size: Int64, modified: Double,
                      chunks: [NewChunk], usedOCR: Bool, error: String?) throws {
        if let existing = documentId(folderId: folderId, path: path) {
            deleteDocument(id: existing, updateMemory: true)
        }
        let ext = (name as NSString).pathExtension.lowercased()
        let embedded = !chunks.isEmpty && chunks.allSatisfy { $0.vector != nil }
        try withStatement("""
            INSERT INTO documents(folder_id, path, name, ext, size, modified, indexed, chunks, ocr, embedded, error)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """) { stmt in
            sqlite3_bind_int64(stmt, 1, folderId)
            sqlite3_bind_text(stmt, 2, path, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, ext, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 5, size)
            sqlite3_bind_double(stmt, 6, modified)
            sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)
            sqlite3_bind_int(stmt, 8, Int32(chunks.count))
            sqlite3_bind_int(stmt, 9, usedOCR ? 1 : 0)
            sqlite3_bind_int(stmt, 10, embedded || chunks.isEmpty ? 1 : 0)
            if let error {
                sqlite3_bind_text(stmt, 11, error, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 11)
            }
            try step(stmt)
        }
        let docId = sqlite3_last_insert_rowid(db)
        for chunk in chunks {
            try withStatement("INSERT INTO chunks(doc_id, page, text, vector) VALUES(?,?,?,?)") { stmt in
                sqlite3_bind_int64(stmt, 1, docId)
                if let page = chunk.page { sqlite3_bind_int(stmt, 2, Int32(page)) } else { sqlite3_bind_null(stmt, 2) }
                sqlite3_bind_text(stmt, 3, chunk.text, -1, SQLITE_TRANSIENT)
                if let vector = chunk.vector {
                    _ = vector.withUnsafeBytes { raw in
                        sqlite3_bind_blob(stmt, 4, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
                    }
                } else {
                    sqlite3_bind_null(stmt, 4)
                }
                try step(stmt)
            }
            let chunkId = sqlite3_last_insert_rowid(db)
            // Title words help keyword search find the file by name.
            try withStatement("INSERT INTO chunk_text(rowid, text) VALUES(?, ?)") { stmt in
                sqlite3_bind_int64(stmt, 1, chunkId)
                sqlite3_bind_text(stmt, 2, name + "\n" + chunk.text, -1, SQLITE_TRANSIENT)
                try step(stmt)
            }
            if let vector = chunk.vector {
                if dimension == 0 { dimension = vector.count }
                if vector.count == dimension {
                    vectorChunkIds.append(chunkId)
                    vectors.append(contentsOf: vector)
                }
            }
        }
    }

    func deleteDocument(id: Int64, updateMemory: Bool = false) {
        try? withStatement("DELETE FROM chunk_text WHERE rowid IN (SELECT id FROM chunks WHERE doc_id = ?)") { stmt in
            sqlite3_bind_int64(stmt, 1, id)
            try step(stmt)
        }
        try? withStatement("DELETE FROM chunks WHERE doc_id = ?") { stmt in
            sqlite3_bind_int64(stmt, 1, id)
            try step(stmt)
        }
        try? withStatement("DELETE FROM documents WHERE id = ?") { stmt in
            sqlite3_bind_int64(stmt, 1, id)
            try step(stmt)
        }
        if updateMemory { needsReload = true }
    }

    /// Set when chunks were deleted; the caller reloads vectors once after a batch.
    private(set) var needsReload = false

    func reloadIfNeeded() {
        if needsReload { loadVectors() }
    }

    func reset() {
        try? exec("DELETE FROM chunk_text; DELETE FROM chunks; DELETE FROM documents;")
        loadVectors()
    }

    func begin() { try? exec("BEGIN") }
    func commit() { try? exec("COMMIT") }

    // MARK: - Search

    /// Chunk ids whose text matches the words (prefix match), best first.
    func keywordMatches(words: [String], limit: Int = 300) -> [Int64] {
        let terms = DocumentRelevance.terms(words.joined(separator: " "))
        guard !terms.isEmpty else { return [] }
        let match = terms.map { "\"\($0)\"*" }.joined(separator: " OR ")
        var ids: [Int64] = []
        try? withStatement("SELECT rowid FROM chunk_text WHERE chunk_text MATCH ? ORDER BY rank LIMIT ?") { stmt in
            sqlite3_bind_text(stmt, 1, match, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.append(sqlite3_column_int64(stmt, 0))
            }
        }
        return ids
    }

    /// Frequent words that would match almost every chunk as a prefix.
    static let stopWords: Set<String> = [
        "как", "что", "это", "для", "при", "где", "или", "его", "она", "они", "все", "мне", "меня",
        "был", "была", "было", "про", "без", "над", "под", "чем", "тот", "эта", "этот", "так", "уже",
        "the", "and", "for", "with", "from", "that", "this", "are", "was", "what", "how", "about",
        "мой", "моя", "моё", "мое", "мои", "моих", "мою", "свой", "своё", "найди", "найти", "покажи",
        "на", "по", "за", "не", "от", "до", "из", "во", "со", "об", "то", "же", "ли", "бы", "да", "он",
        "мы", "вы", "ты", "их", "ее", "её", "но", "уж", "ко",
        "of", "to", "in", "on", "at", "is", "it", "by", "an", "or", "as", "be", "my", "me", "we", "us",
        "do", "no", "so", "up", "find", "show",
    ]

    /// Crude stemming for prefix search: "налоговый" → "налогов", "договора" → "догово".
    static func stem(_ word: String) -> String {
        let isCyrillic = word.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil
        if isCyrillic && word.count >= 6 { return String(word.dropLast(2)) }
        if isCyrillic && word.count == 5 { return String(word.dropLast(1)) }
        if !isCyrillic && word.count >= 6 && word.hasSuffix("s") { return String(word.dropLast()) }
        return word
    }

    func chunkInfo(ids: [Int64]) -> [Int64: ChunkInfo] {
        guard !ids.isEmpty else { return [:] }
        var result: [Int64: ChunkInfo] = [:]
        let list = ids.map(String.init).joined(separator: ",")
        try? withStatement("""
            SELECT c.id, c.doc_id, d.folder_id, d.path, d.name, d.modified, c.page, c.text
            FROM chunks c JOIN documents d ON d.id = c.doc_id
            WHERE c.id IN (\(list))
            """) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let info = ChunkInfo(
                    chunkId: sqlite3_column_int64(stmt, 0),
                    documentId: sqlite3_column_int64(stmt, 1),
                    folderId: sqlite3_column_int64(stmt, 2),
                    path: columnText(stmt, 3),
                    name: columnText(stmt, 4),
                    modified: sqlite3_column_double(stmt, 5),
                    page: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 6)),
                    text: columnText(stmt, 7)
                )
                result[info.chunkId] = info
            }
        }
        return result
    }

    /// Documents whose file name or path contains any of the stems, as their first chunk.
    func documentTermMatches(terms: [String], limit: Int = 200) -> [Int64] {
        guard !terms.isEmpty else { return [] }
        let clause = terms.map { _ in "(d.name LIKE ? OR d.path LIKE ?)" }.joined(separator: " OR ")
        var ids: [Int64] = []
        try? withStatement("""
            SELECT MIN(c.id) FROM documents d JOIN chunks c ON c.doc_id = d.id
            WHERE \(clause) GROUP BY d.id LIMIT ?
            """) { stmt in
            var index: Int32 = 1
            for term in terms {
                for _ in 0..<2 {
                    sqlite3_bind_text(stmt, index, "%\(term)%", -1, SQLITE_TRANSIENT)
                    index += 1
                }
            }
            sqlite3_bind_int(stmt, index, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.append(sqlite3_column_int64(stmt, 0))
            }
        }
        return ids
    }

    // MARK: - Internals

    private func documentId(folderId: Int64, path: String) -> Int64? {
        var id: Int64?
        try? withStatement("SELECT id FROM documents WHERE folder_id = ? AND path = ?") { stmt in
            sqlite3_bind_int64(stmt, 1, folderId)
            sqlite3_bind_text(stmt, 2, path, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW { id = sqlite3_column_int64(stmt, 0) }
        }
        return id
    }

    private func loadVectors() {
        vectorChunkIds = []
        vectors = []
        dimension = 0
        needsReload = false
        try? withStatement("SELECT id, vector FROM chunks WHERE vector IS NOT NULL ORDER BY id") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let blob = sqlite3_column_blob(stmt, 1) else { continue }
                let count = Int(sqlite3_column_bytes(stmt, 1)) / MemoryLayout<Float>.size
                if dimension == 0 { dimension = count }
                guard count == dimension else { continue }
                vectorChunkIds.append(sqlite3_column_int64(stmt, 0))
                vectors.append(contentsOf: UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: count))
            }
        }
    }

    private func metaValue(_ key: String) -> String? {
        var value: String?
        try? withStatement("SELECT value FROM meta WHERE key = ?") { stmt in
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW { value = columnText(stmt, 0) }
        }
        return value
    }

    private func setMeta(_ key: String, _ value: String) {
        try? withStatement("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)") { stmt in
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
            try step(stmt)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? ""
    }

    private func columnData(_ stmt: OpaquePointer?, _ index: Int32) -> Data? {
        guard let blob = sqlite3_column_blob(stmt, index) else { return nil }
        return Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, index)))
    }

    private func bindData(_ stmt: OpaquePointer?, _ index: Int32, _ data: Data) {
        _ = data.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
        }
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw DocumentStoreError.sqlite(message)
        }
    }

    private func withStatement(_ sql: String, _ body: (OpaquePointer?) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DocumentStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        try body(stmt)
    }

    private func step(_ stmt: OpaquePointer?) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DocumentStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }
}
