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
    /// One-line note after adding a folder (already connected, replaced nested ones).
    @Published private(set) var folderNotice: String?
    /// Files in iCloud that are not on the phone yet; their download was requested.
    @Published private(set) var pendingDownloads = 0

    @Published var ocrEnabled: Bool = UserDefaults.standard.object(forKey: "docs.ocrEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(ocrEnabled, forKey: "docs.ocrEnabled") }
    }
    var excludedExtensions: Set<String> {
        Set((UserDefaults.standard.stringArray(forKey: "docs.excludedExtensions") ?? []).map { $0.lowercased() })
    }
    /// Folder names skipped while walking (set from the Settings screen).
    var excludedFolderNames: Set<String> {
        let names = UserDefaults.standard.stringArray(forKey: "docs.excludedFolderNames")
            ?? ["Caches", "Cache", "tmp", ".Trash", "node_modules"]
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
        ensureAppFolder()
        removeDuplicateFolders()
        if DocumentDemo.isEnabled {
            Task { @MainActor in await DocumentDemo.run(engine: DocumentEngine.shared) }
        }
    }

    /// Name of the built-in folder: the app's own folder in Files ("На iPhone → Indexator").
    /// It is always indexed; anything dropped there is found without any setup.
    static let appFolderName = "Indexator в «Файлах»"

    /// User-picked folders (the built-in app folder does not count).
    var userFolders: [DocumentFolder] { folders.filter { !$0.bookmark.isEmpty } }

    private func ensureAppFolder() {
        guard let store, !store.folders().contains(where: { $0.bookmark.isEmpty }) else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // A visible subfolder, so the app's folder shows up in Files right away.
        try? FileManager.default.createDirectory(at: docs.appendingPathComponent("Документы"), withIntermediateDirectories: true)
        // An empty bookmark marks the app's own Documents folder; its path is resolved fresh each time.
        _ = try? store.addFolder(name: Self.appFolderName, bookmark: Data(), isDirectory: true)
        refreshState()
    }

    /// Drops folders connected twice, or lying inside another connected folder,
    /// left over from before adding checked for duplicates. The oldest copy stays.
    private func removeDuplicateFolders() {
        let resolved = folders.compactMap { f in folderURL(f).map { (folder: f, path: DocumentRelevance.normalizedPath($0)) } }
        var drop: [DocumentFolder] = []
        for (i, item) in resolved.enumerated() where !item.folder.bookmark.isEmpty {
            let covered = resolved.enumerated().contains { j, other in
                guard j != i, other.folder.isDirectory else { return false }
                if other.path == item.path { return j < i }
                return DocumentRelevance.isSameOrInside(item.path, other.path)
            }
            if covered { drop.append(item.folder) }
        }
        for folder in drop {
            if let url = resolvedFolders.removeValue(forKey: folder.id) { url.stopAccessingSecurityScopedResource() }
            store?.removeFolder(id: folder.id)
            log.add("Убран повтор папки: \(folder.name)")
        }
        if !drop.isEmpty { refreshState() }
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
            let path = DocumentRelevance.normalizedPath(url)
            // Already connected, itself or inside a connected folder: nothing to add.
            for folder in folders where folder.isDirectory || !isDirectory {
                guard let existing = folderURL(folder) else { continue }
                let existingPath = DocumentRelevance.normalizedPath(existing)
                if path == existingPath || (folder.isDirectory && DocumentRelevance.isSameOrInside(path, existingPath)) {
                    folderNotice = path == existingPath
                        ? "«\(url.lastPathComponent)» уже подключена."
                        : "«\(url.lastPathComponent)» уже внутри подключённой папки «\(folder.name)»."
                    log.add(folderNotice ?? "")
                    return
                }
            }
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            guard let store else { return }
            // A wider folder replaces the connected folders and files inside it.
            if isDirectory {
                let inside = userFolders.filter { folder in
                    folderURL(folder).map { DocumentRelevance.isSameOrInside(DocumentRelevance.normalizedPath($0), path) } ?? false
                }
                for folder in inside { removeFolder(folder) }
                folderNotice = inside.isEmpty ? nil : "Заменила вложенные: \(inside.map(\.name).joined(separator: ", "))."
            } else {
                folderNotice = nil
            }
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
        if folder.bookmark.isEmpty {
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }
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
        guard !isIndexing else {
            // A folder added mid-run (or a file changed) must not be dropped: scan again afterwards.
            rescanAfterRun = true
            return
        }
        indexTask = Task { [weak self] in
            await self?.runIndexing(folderIds: folderIds)
            guard let self else { return }
            while self.rescanAfterRun && !Task.isCancelled {
                self.rescanAfterRun = false
                await self.runIndexing(folderIds: nil)
            }
        }
    }

    private var rescanAfterRun = false

    /// What the last scan saw in each folder, shown under the folder in Settings.
    @Published private(set) var folderScanInfo: [Int64: String] = [:]

    /// Re-scans folders for new or changed files; cheap when nothing changed.
    func refreshChanged() {
        guard !folders.isEmpty else { return }
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
        var pendingCount = 0
        for folder in targets {
            guard let base = folderURL(folder) else {
                log.add("Нет доступа к «\(folder.name)». Удали и добавь папку заново.")
                folderScanInfo[folder.id] = "нет доступа: убери папку и добавь заново"
                continue
            }
            let scan = await onWorkerSafe { Self.listFiles(base: base, isDirectory: folder.isDirectory, excluded: excluded, excludedFolders: excludedFolders, maxBytes: maxBytes) }
            let files = scan.files, waiting = scan.waiting
            pendingCount += waiting
            var info = "просмотрено \(scan.seen), документов \(files.count)"
            if waiting > 0 { info += ", скачиваются из iCloud \(waiting)" }
            if let error = scan.error { info += ", ошибка: \(error)" }
            folderScanInfo[folder.id] = info
            log.add("Папка «\(folder.name)»: \(info)")
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
        pendingDownloads = pendingCount
        if pendingCount > 0 {
            log.add("Документы: \(pendingCount) файлов ещё в iCloud, попросил скачать; проиндексирую, когда скачаются")
            scheduleRecheck()
        }
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
                    let extracted = try Self.coordinatedExtract(file.url, allowOCR: useOCR)
                    var pieces = TextChunker.chunks(from: extracted.pages)
                    if pieces.isEmpty && !DocumentTextExtractor.imageExtensions.contains(file.url.pathExtension.lowercased()) {
                        // No readable text (iWork, old .doc, empty scan): still findable by its name and folder.
                        let title = (file.url.lastPathComponent as NSString).deletingPathExtension
                        let place = (file.path as NSString).deletingLastPathComponent
                        pieces = [TextChunk(page: nil, text: place.isEmpty ? title : "\(title) — \(place)")]
                    }
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

    /// Lists supported files. Returns the files ready to read and how many are still in
    /// iCloud (their download is requested; they are picked up on a later pass).
    private struct FolderScan {
        let files: [FileEntry]
        let waiting: Int
        let seen: Int
        let error: String?
    }

    nonisolated private static func listFiles(base: URL, isDirectory: Bool, excluded: Set<String>, excludedFolders: Set<String>, maxBytes: Int64) -> FolderScan {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                                      .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        var waiting = 0, seen = 0
        var firstError: String?
        func supported(_ url: URL) -> Bool {
            DocumentTextExtractor.isSupported(url) && !excluded.contains(url.pathExtension.lowercased())
        }
        func entry(_ url: URL, path: String) -> FileEntry? {
            guard supported(url), let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            if values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus, status == .notDownloaded {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                waiting += 1
                return nil
            }
            let size = Int64(values.fileSize ?? 0)
            guard size > 0, size <= maxBytes else { return nil }
            return FileEntry(url: url, path: path, size: size,
                             modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        if !isDirectory {
            let one = entry(base, path: "").map { [$0] } ?? []
            return FolderScan(files: one, waiting: waiting, seen: 1, error: nil)
        }
        // Hidden files are skipped by hand: iCloud placeholders (".name.pdf.icloud") are hidden too.
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants],
            errorHandler: { url, error in
                if firstError == nil { firstError = "\(url.lastPathComponent): \(error.localizedDescription)" }
                return true
            }
        ) else { return FolderScan(files: [], waiting: 0, seen: 0, error: "папка не открылась") }
        let basePath = base.standardizedFileURL.path
        var result: [FileEntry] = []
        for case let url as URL in enumerator {
            seen += 1
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if name.hasPrefix(".") {
                if !isDir, name.hasSuffix(".icloud") {
                    // ".Резюме.pdf.icloud" stands for "Резюме.pdf" that is not downloaded yet.
                    let realName = String(name.dropFirst().dropLast(".icloud".count))
                    let real = url.deletingLastPathComponent().appendingPathComponent(realName)
                    if supported(real) {
                        try? FileManager.default.startDownloadingUbiquitousItem(at: real)
                        waiting += 1
                    }
                }
                if isDir { enumerator.skipDescendants() }
                continue
            }
            if isDir {
                if excludedFolders.contains(name.lowercased()) { enumerator.skipDescendants() }
                continue
            }
            var path = url.standardizedFileURL.path
            if path.hasPrefix(basePath) { path = String(path.dropFirst(basePath.count)) }
            while path.hasPrefix("/") { path.removeFirst() }
            if let e = entry(url, path: path) { result.append(e) }
            if result.count >= 20_000 { break }
        }
        return FolderScan(files: result, waiting: waiting, seen: seen, error: firstError)
    }

    /// Reads through NSFileCoordinator, so files kept by a file provider (iCloud Drive,
    /// other cloud apps) are brought onto the phone before reading.
    nonisolated private static func coordinatedExtract(_ url: URL, allowOCR: Bool) throws -> ExtractedDocument {
        var coordinationError: NSError?
        var result: Result<ExtractedDocument, Error> = .failure(DocumentExtractionError.unreadable(fileName: url.lastPathComponent))
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readURL in
            result = Result { try DocumentTextExtractor.extract(from: readURL, allowOCR: allowOCR) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    private var recheckTask: Task<Void, Never>?

    /// Looks again in a minute, when requested iCloud downloads have likely arrived.
    private func scheduleRecheck() {
        recheckTask?.cancel()
        recheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshChanged()
        }
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
            if userFolders.isEmpty {
                lastQueryInfo = "папки не подключены (Настройки → Документы)"
            } else if isIndexing {
                lastQueryInfo = "ещё индексируются: \(progressDone) из \(progressTotal)"
            } else {
                lastQueryInfo = "в подключённых папках нет документов"
            }
            return
        }
        await loadEmbedderIfNeeded()
        let embedder = self.embedder
        let start = CFAbsoluteTimeGetCurrent()

        // Meaning: cosine similarity of the query with every chunk.
        var scoreOf: [Int64: Float] = [:]
        var semantic: [(Int64, Float)] = []
        if let embedder, store.vectorCount > 0 {
            let ids = store.vectorChunkIds
            let matrix = store.vectors
            let rows = store.vectorCount
            if let vector = try? await onWorker({ try embedder.embed(query: text) }) {
                let scores = await onWorkerSafe { VectorMath.scores(query: vector, matrix: matrix, rows: rows) }
                for (i, s) in scores.enumerated() { scoreOf[ids[i]] = s }
                let order = scores.indices.sorted { scores[$0] > scores[$1] }
                semantic = order.prefix(50).map { (ids[$0], scores[$0]) }
            }
        }

        // Words: a document counts only when its text, name or path holds most query words
        // (all of them for short queries). Meaning only orders these and adds a few sure hits.
        let terms = DocumentRelevance.terms(text)
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let keyword = store.keywordMatches(words: words, limit: 1000)
        let byName = store.documentTermMatches(terms: terms)
        var candidates = keyword + byName
        candidates += semantic.map(\.0)
        var unique = Set<Int64>()
        candidates = candidates.filter { unique.insert($0).inserted }
        let infos = store.chunkInfo(ids: candidates)

        struct Pick { let chunk: Int64; let coverage: Double; let score: Float; let textMatch: Bool }
        var docWords: [Int64: Set<Substring>] = [:]
        var bestChunk: [Int64: (chunk: Int64, coverage: Double, score: Float)] = [:]
        for id in candidates {
            guard let info = infos[id] else { continue }
            let chunkWords = DocumentRelevance.words(info.text + " " + info.name + " " + info.path)
            docWords[info.documentId, default: []].formUnion(chunkWords)
            let cov = DocumentRelevance.coverage(terms: terms, in: chunkWords)
            let score = scoreOf[id] ?? 0
            if let cur = bestChunk[info.documentId], (cur.coverage, cur.score) >= (cov, score) { continue }
            bestChunk[info.documentId] = (id, cov, score)
        }
        var picks: [Pick] = []
        for (docId, best) in bestChunk {
            let words = docWords[docId] ?? []
            let isText = DocumentRelevance.isTextMatch(terms: terms, words: words)
            picks.append(Pick(chunk: best.chunk, coverage: DocumentRelevance.coverage(terms: terms, in: words), score: best.score, textMatch: isText))
        }
        let textPicks = picks.filter(\.textMatch).sorted { ($0.coverage, $0.score) > ($1.coverage, $1.score) }
        let semanticPicks = picks
            .filter { !$0.textMatch && $0.score >= DocumentRelevance.semanticOnlyMinScore }
            .sorted { $0.score > $1.score }
            .prefix(DocumentRelevance.semanticOnlyLimit)
        let ranked = textPicks + semanticPicks

        let folderById = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var hits: [DocumentHit] = []
        for pick in ranked.prefix(30) {
            guard let info = infos[pick.chunk] else { continue }
            let folder = folderById[info.folderId]
            let url = folder.flatMap { f in folderURL(f).map { info.path.isEmpty ? $0 : $0.appendingPathComponent(info.path) } }
            let ext = (info.name as NSString).pathExtension
            hits.append(DocumentHit(
                id: "doc-\(info.documentId)",
                documentId: info.documentId,
                chunkId: pick.chunk,
                folderId: info.folderId,
                title: info.name,
                folderName: folder?.name ?? "",
                relativePath: info.path,
                snippet: TextChunker.snippet(of: info.text, around: words),
                page: info.page,
                date: info.modified > 0 ? Date(timeIntervalSince1970: info.modified) : nil,
                score: pick.score,
                textMatch: pick.textMatch,
                fileURL: url,
                contentType: UTType(filenameExtension: ext)?.identifier
            ))
        }
        results = hits

        var info = ["Документы: \(hits.count)"]
        if embedder == nil { info.append("только по словам") }
        if let top = semantic.first?.1 { info.append(String(format: "лучший %.2f", top)) }
        info.append("по словам: \(textPicks.count), по смыслу: \(semanticPicks.count)")
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
