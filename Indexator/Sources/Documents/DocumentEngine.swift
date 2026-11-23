// SPDX-License-Identifier: GPL-3.0-or-later
//
// Document search: folders granted through Files (security-scoped bookmarks) are
// scanned, text is extracted (PDF, text, docx, OCR for scans and images), split into
// chunks and embedded with multilingual-e5-small, so Russian queries work directly.
// Search fuses meaning (vectors) and words (FTS5) and returns the best chunk per file.

import Foundation
import UIKit
import UniformTypeIdentifiers

struct DocumentHit: Identifiable, Hashable {
    let id: String            // "doc-<documentId>"
    let documentId: Int64
    let chunkId: Int64
    let folderId: Int64
    let title: String         // file name
    let folderName: String
    let relativePath: String
    let snippet: String
    let page: Int?
    let date: Date?           // file modification date
    let score: Float          // vector similarity, 0 when only words matched
    let textMatch: Bool       // query words were found in the text
    let fileURL: URL?
    let contentType: String?  // UTType identifier
}

@MainActor
final class DocumentEngine: ObservableObject {
    static let shared = DocumentEngine()

    enum EmbedderState: Equatable {
        case notLoaded, loading, ready, unavailable(String)
    }

    @Published private(set) var folders: [DocumentFolder] = []
    @Published private(set) var embedderState: EmbedderState = .notLoaded
    @Published private(set) var isIndexing = false
    @Published private(set) var progressDone = 0
    @Published private(set) var progressTotal = 0
    @Published private(set) var currentFile = ""
    @Published private(set) var stats = DocumentStore.Stats()
    @Published private(set) var msPerChunk: Double?
    @Published private(set) var results: [DocumentHit] = []
    @Published private(set) var lastQueryInfo: String?
    @Published private(set) var lastError: String?

    @Published var ocrEnabled: Bool = UserDefaults.standard.object(forKey: "docs.ocrEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(ocrEnabled, forKey: "docs.ocrEnabled") }
    }
    var excludedExtensions: Set<String> {
        Set((UserDefaults.standard.stringArray(forKey: "docs.excludedExtensions") ?? []).map { $0.lowercased() })
    }
    /// Folder names skipped while walking (set from the Settings screen).
    var excludedFolderNames: Set<String> {
        let names = UserDefaults.standard.stringArray(forKey: "docs.excludedFolderNames")
            ?? ["WhatsApp", "Telegram", "Viber", "Caches", "tmp", ".Trash", "node_modules"]
        return Set(names.map { $0.lowercased() })
    }
    var maxFileBytes: Int64 {
        let mb = UserDefaults.standard.object(forKey: "docs.maxFileMB") as? Int ?? 50
        return Int64(max(mb, 1)) * 1_000_000
    }

    private var store: DocumentStore?
    private var embedder: TextEmbedder?
    private var indexTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var resolvedFolders: [Int64: URL] = [:]
    private let worker = DispatchQueue(label: "indexator.docs", qos: .userInitiated)
    private let log = AppLog.shared

    private init() {
        do {
            store = try DocumentStore(embedderName: TextEmbedder.modelName)
            refreshState()
        } catch {
            lastError = error.localizedDescription
            log.add("База документов не открылась: \(error.localizedDescription)")
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in DocumentEngine.shared.refreshChanged() }
        }
        if DocumentDemo.isEnabled {
            Task { @MainActor in await DocumentDemo.run(engine: DocumentEngine.shared) }
        }
    }

    var indexedChunks: Int { stats.chunks }

    // MARK: - Model

    /// Loads the model once; concurrent callers (indexing and search) wait for the same load.
    func loadEmbedderIfNeeded() async {
        if embedder != nil { return }
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { @MainActor in
            embedderState = .loading
            let start = CFAbsoluteTimeGetCurrent()
            do {
                embedder = try await onWorker { try TextEmbedder.shared() }
                embedderState = .ready
                log.add(String(format: "Модель текста %@ загружена за %.1f с", TextEmbedder.modelName, CFAbsoluteTimeGetCurrent() - start))
            } catch {
                embedderState = .unavailable(error.localizedDescription)
                log.add("Модель текста недоступна, документы ищутся только по словам: \(error.localizedDescription)")
            }
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    // MARK: - Folders

    /// Adds a folder or a single file picked in Files. The URL must be security-scoped.
    func addFolder(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            guard let store else { return }
            let id = try store.addFolder(name: url.lastPathComponent, bookmark: bookmark, isDirectory: isDirectory)
            log.add("Добавлена \(isDirectory ? "папка" : "файл"): \(url.lastPathComponent)")
            refreshState()
            startIndexing(folderIds: [id])
        } catch {
            lastError = "Не удалось сохранить доступ к «\(url.lastPathComponent)»: \(error.localizedDescription)"
            log.add(lastError ?? "")
        }
    }

    func removeFolder(_ folder: DocumentFolder) {
        stopIndexing()
        if let url = resolvedFolders.removeValue(forKey: folder.id) {
            url.stopAccessingSecurityScopedResource()
        }
        store?.removeFolder(id: folder.id)
        results = []
        refreshState()
        log.add("Убрана папка: \(folder.name)")
    }

    func folderStats(_ folder: DocumentFolder) -> DocumentStore.Stats {
        store?.stats(folderId: folder.id) ?? .init()
    }

    /// Resolves a folder bookmark and keeps its security scope open while the app runs,
    /// so results can be previewed, shared and opened without extra bookkeeping.
    func folderURL(_ folder: DocumentFolder) -> URL? {
        if let url = resolvedFolders[folder.id] { return url }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: folder.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        _ = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            store?.updateBookmark(folderId: folder.id, bookmark: fresh)
        }
        resolvedFolders[folder.id] = url
        return url
    }

    /// Runs `body` with the hit's file URL inside its folder's security scope.
    func withAccess<T>(to hit: DocumentHit, _ body: (URL) throws -> T) rethrows -> T? {
        guard let url = fileURL(folderId: hit.folderId, path: hit.relativePath) else { return nil }
        return try body(url)
    }

    private func fileURL(folderId: Int64, path: String) -> URL? {
        guard let folder = folders.first(where: { $0.id == folderId }), let base = folderURL(folder) else { return nil }
        return path.isEmpty ? base : base.appendingPathComponent(path)
    }

    // MARK: - Indexing

    func startIndexing(folderIds: [Int64]? = nil) {
        guard !isIndexing else { return }
        indexTask = Task { [weak self] in
            await self?.runIndexing(folderIds: folderIds)
        }
    }

    /// Re-scans folders for new or changed files; cheap when nothing changed.
    func refreshChanged() {
        guard !folders.isEmpty, !isIndexing else { return }
        startIndexing()
    }

    func stopIndexing() {
        indexTask?.cancel()
    }

    /// Short summary of the last pass, for the background run history.
    private(set) var lastRunSummary = ""

    /// Re-scans all folders and waits for the result. Used by background tasks:
    /// `deadline` stops before the next file once the time is up; the rest is picked
    /// up next time, because finished files are skipped by size and date.
    func refreshAndWait(deadline: Date? = nil) async -> String {
        guard !folders.isEmpty else { return "документы: папок нет" }
        if isIndexing, let indexTask {
            await indexTask.value
            return lastRunSummary
        }
        indexTask = Task { [weak self] in
            await self?.runIndexing(folderIds: nil, deadline: deadline)
        }
        await indexTask?.value
        return lastRunSummary
    }

    func resetIndex() {
        stopIndexing()
        store?.reset()
        results = []
        refreshState()
        log.add("Индекс документов удалён")
    }

    private struct FileEntry {
        let url: URL
        let path: String
        let size: Int64
        let modified: Double
    }

    private func runIndexing(folderIds: [Int64]?, deadline: Date? = nil) async {
        guard let store else { return }
        await loadEmbedderIfNeeded()
        let embedder = self.embedder
        let useOCR = ocrEnabled
        let excluded = excludedExtensions
        let excludedFolders = excludedFolderNames
        let maxBytes = maxFileBytes
        let targets = folders.filter { folderIds == nil || folderIds!.contains($0.id) }

        isIndexing = true
        progressDone = 0
        progressTotal = 0
        defer {
            isIndexing = false
            currentFile = ""
            store.reloadIfNeeded()
            refreshState()
        }

        // 1. Collect what needs (re)indexing.
        var todo: [(DocumentFolder, FileEntry)] = []
        var removed = 0
        for folder in targets {
            guard let base = folderURL(folder) else {
                log.add("Нет доступа к «\(folder.name)». Удали и добавь папку заново.")
                continue
            }
            let files = await onWorkerSafe { Self.listFiles(base: base, isDirectory: folder.isDirectory, excluded: excluded, excludedFolders: excludedFolders, maxBytes: maxBytes) }
            let known = Dictionary(store.documents(folderId: folder.id).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            let present = Set(files.map(\.path))
            for doc in known.values where !present.contains(doc.path) {
                store.deleteDocument(id: doc.id, updateMemory: true)
                removed += 1
            }
            for file in files {
                if let doc = known[file.path], doc.size == file.size, abs(doc.modified - file.modified) < 1,
                   doc.embedded || embedder == nil {
                    continue
                }
                todo.append((folder, file))
            }
        }
        store.reloadIfNeeded()
        if removed > 0 { log.add("Документы: убрано \(removed) удалённых файлов") }
        lastRunSummary = removed > 0 ? "документы: −\(removed)" : "документы: без изменений"
        guard !todo.isEmpty else { return }

        progressTotal = todo.count
        log.add("Документы: к индексации \(todo.count) файлов, OCR \(useOCR ? "вкл" : "выкл"), модель \(embedder == nil ? "нет" : "есть")")
        let wallStart = CFAbsoluteTimeGetCurrent()
        var chunkCount = 0, failures = 0, embedSeconds = 0.0

        for (folder, file) in todo {
            if Task.isCancelled { break }
            if let deadline, Date() >= deadline { break }
            currentFile = file.path.isEmpty ? folder.name : file.path
            let result = await onWorkerSafe { () -> (ExtractedDocument?, [NewChunk], String?, Double) in
                do {
                    let extracted = try DocumentTextExtractor.extract(from: file.url, allowOCR: useOCR)
                    let pieces = TextChunker.chunks(from: extracted.pages)
                    let t0 = CFAbsoluteTimeGetCurrent()
                    var chunks: [NewChunk] = []
                    for piece in pieces {
                        let vector = try? embedder?.embed(passage: piece.text)
                        chunks.append(NewChunk(page: piece.page, text: piece.text, vector: vector))
                    }
                    return (extracted, chunks, nil, CFAbsoluteTimeGetCurrent() - t0)
                } catch {
                    return (nil, [], error.localizedDescription, 0)
                }
            }
            let (extracted, chunks, error, seconds) = result
            embedSeconds += seconds
            chunkCount += chunks.count
            if error != nil {
                failures += 1
                if failures <= 5 { log.add("Ошибка в «\(currentFile)»: \(error ?? "")") }
            }
            let name = file.path.isEmpty ? folder.name : (file.path as NSString).lastPathComponent
            store.begin()
            do {
                try store.saveDocument(folderId: folder.id, path: file.path, name: name, size: file.size,
                                       modified: file.modified, chunks: chunks,
                                       usedOCR: extracted?.usedOCR ?? false, error: error)
            } catch {
                log.add("Не записал «\(name)»: \(error.localizedDescription)")
            }
            store.commit()
            progressDone += 1
            if chunkCount > 0 && embedder != nil { msPerChunk = embedSeconds / Double(chunkCount) * 1000 }
            if progressDone % 10 == 0 { refreshState() }
        }

        let left = todo.count - progressDone
        lastRunSummary = "документы: +\(progressDone)" + (removed > 0 ? ", −\(removed)" : "") + (left > 0 ? ", осталось \(left)" : "")
        log.add(String(format: "Документы готовы: %d файлов, %d фрагментов за %.0f с (%.0f мс на фрагмент), ошибок %d",
                       progressDone, chunkCount, CFAbsoluteTimeGetCurrent() - wallStart, msPerChunk ?? 0, failures))
    }

    nonisolated private static func listFiles(base: URL, isDirectory: Bool, excluded: Set<String>, excludedFolders: Set<String>, maxBytes: Int64) -> [FileEntry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        func entry(_ url: URL, path: String) -> FileEntry? {
            guard DocumentTextExtractor.isSupported(url), !excluded.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            let size = Int64(values.fileSize ?? 0)
            guard size > 0, size <= maxBytes else { return nil }
            return FileEntry(url: url, path: path, size: size,
                             modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        if !isDirectory {
            return entry(base, path: "").map { [$0] } ?? []
        }
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let basePath = base.standardizedFileURL.path
        var result: [FileEntry] = []
        for case let url as URL in enumerator {
            if excludedFolders.contains(url.lastPathComponent.lowercased()),
               (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                enumerator.skipDescendants()
                continue
            }
            var path = url.standardizedFileURL.path
            if path.hasPrefix(basePath) { path = String(path.dropFirst(basePath.count)) }
            while path.hasPrefix("/") { path.removeFirst() }
            if let e = entry(url, path: path) { result.append(e) }
            if result.count >= 20_000 { break }
        }
        return result
    }

    private func refreshState() {
        folders = store?.folders() ?? []
        stats = store?.stats() ?? .init()
    }

    // MARK: - Search

    /// Searches documents with the user's raw query (Russian or English, no translation).
    func search(_ query: String) async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !text.isEmpty else {
            results = []
            lastQueryInfo = nil
            return
        }
        guard stats.chunks > 0 else {
            results = []
            lastQueryInfo = nil
            return
        }
        await loadEmbedderIfNeeded()
        let embedder = self.embedder
        let start = CFAbsoluteTimeGetCurrent()

        // Meaning: cosine similarity of the query with every chunk.
        var semantic: [(Int64, Float)] = []
        var scoreOf: [Int64: Float] = [:]
        if let embedder, store.vectorCount > 0 {
            let ids = store.vectorChunkIds
            let matrix = store.vectors
            let rows = store.vectorCount
            if let vector = try? await onWorker({ try embedder.embed(query: text) }) {
                let scores = await onWorkerSafe { VectorMath.scores(query: vector, matrix: matrix, rows: rows) }
                for (i, s) in scores.enumerated() { scoreOf[ids[i]] = s }
                let order = scores.indices.sorted { scores[$0] > scores[$1] }
                let best = order.first.map { scores[$0] } ?? 0
                // e5 similarities sit in a narrow band; keep chunks close to the best one.
                let cutoff = best - 0.06
                semantic = order.prefix { scores[$0] >= cutoff }.prefix(300).map { (ids[$0], scores[$0]) }
            }
        }

        // Words: FTS5 prefix match plus file names.
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let keyword = store.keywordMatches(words: words)
        let byName = store.documentNameMatches(text)
        let keywordSet = Set(keyword).union(byName)

        // Reciprocal rank fusion at chunk level.
        var fused: [Int64: Double] = [:]
        for (rank, (id, _)) in semantic.enumerated() { fused[id, default: 0] += 1.0 / Double(60 + rank) }
        for (rank, id) in keyword.enumerated() { fused[id, default: 0] += 1.0 / Double(60 + rank) }
        for (rank, id) in byName.enumerated() { fused[id, default: 0] += 1.0 / Double(60 + rank) }
        let rankedChunks = fused.sorted { $0.value > $1.value }.prefix(400).map(\.key)

        // Best chunk per document.
        let infos = store.chunkInfo(ids: rankedChunks)
        var seen = Set<Int64>()
        var hits: [DocumentHit] = []
        let folderById = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in rankedChunks {
            guard let info = infos[id], !seen.contains(info.documentId) else { continue }
            seen.insert(info.documentId)
            let folder = folderById[info.folderId]
            let url = folder.flatMap { f in folderURL(f).map { info.path.isEmpty ? $0 : $0.appendingPathComponent(info.path) } }
            let ext = (info.name as NSString).pathExtension
            hits.append(DocumentHit(
                id: "doc-\(info.documentId)",
                documentId: info.documentId,
                chunkId: id,
                folderId: info.folderId,
                title: info.name,
                folderName: folder?.name ?? "",
                relativePath: info.path,
                snippet: TextChunker.snippet(of: info.text, around: words),
                page: info.page,
                date: info.modified > 0 ? Date(timeIntervalSince1970: info.modified) : nil,
                score: scoreOf[id] ?? 0,
                textMatch: keywordSet.contains(id),
                fileURL: url,
                contentType: UTType(filenameExtension: ext)?.identifier
            ))
            if hits.count >= 30 { break }
        }
        results = hits

        var info = ["Документы: \(hits.count)"]
        if embedder == nil { info.append("только по словам") }
        if let top = semantic.first?.1 { info.append(String(format: "лучший %.2f", top)) }
        if !keyword.isEmpty { info.append("совпадений слов: \(keyword.count)") }
        info.append(String(format: "%.0f мс", (CFAbsoluteTimeGetCurrent() - start) * 1000))
        lastQueryInfo = info.joined(separator: " · ")
        log.add("Документы «\(text)»: \(lastQueryInfo ?? "")")
    }

    func clearResults() {
        results = []
        lastQueryInfo = nil
    }

    // MARK: - Helpers

    private func onWorker<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            worker.async { continuation.resume(with: Result { try body() }) }
        }
    }

    private func onWorkerSafe<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            worker.async { continuation.resume(returning: body()) }
        }
    }
}
