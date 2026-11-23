// SPDX-License-Identifier: GPL-3.0-or-later
//
// Loads the CLIP model, indexes photos (vector + OCR text + date/place) into SQLite,
// and answers queries with hybrid ranking: meaning (CLIP) + words found on photos.

import BackgroundTasks
import Foundation
import Photos

/// What one pass of `syncPhotos` did, for the log and the Settings screen.
struct PhotoSyncResult {
    var added = 0
    var removed = 0
    var remaining = 0
    var isCancelled = false
    var skipped: String?

    var isComplete: Bool { skipped == nil && remaining == 0 }

    var summary: String {
        if let skipped { return "фото: \(skipped)" }
        var parts: [String] = []
        if added > 0 { parts.append("+\(added)") }
        if removed > 0 { parts.append("−\(removed)") }
        if remaining > 0 { parts.append("осталось \(remaining)") }
        return parts.isEmpty ? "фото: без изменений" : "фото: " + parts.joined(separator: ", ")
    }
}

struct SearchHit: Identifiable, Hashable {
    let id: String        // PHAsset.localIdentifier
    let score: Float      // CLIP similarity, for display
    let textMatch: Bool   // query words were found on the photo
}

@MainActor
final class SearchEngine: ObservableObject {
    static let shared = SearchEngine()

    enum ModelState: Equatable {
        case notLoaded
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var modelState: ModelState = .notLoaded
    @Published private(set) var modelSummary = ""
    @Published private(set) var modelLoadSeconds: Double?
    @Published private(set) var authorization: PHAuthorizationStatus = PhotoLibrary.status
    @Published private(set) var libraryCount = 0
    @Published private(set) var indexedCount = 0
    @Published private(set) var isIndexing = false
    @Published private(set) var progressDone = 0
    @Published private(set) var progressTotal = 0
    @Published private(set) var msPerPhoto: Double?
    @Published private(set) var msOCR: Double?
    @Published private(set) var results: [SearchHit] = []
    @Published private(set) var lastQueryInfo: String?
    @Published var ocrEnabled: Bool = UserDefaults.standard.object(forKey: "ocrEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(ocrEnabled, forKey: "ocrEnabled") }
    }

    private var clip: ClipModel?
    private var database: IndexDatabase?
    private var indexTask: Task<Void, Never>?
    private var syncTask: Task<PhotoSyncResult, Never>?
    private var resyncRequested = false
    private let worker = DispatchQueue(label: "indexator.clip", qos: .userInitiated)
    private let log = AppLog.shared

    private init() {
        do {
            database = try IndexDatabase(model: ClipModel.variant)
            indexedCount = database?.count ?? 0
        } catch {
            log.add("База индекса не открылась: \(error.localizedDescription)")
        }
    }

    // MARK: - Setup

    func prepare() async {
        // Load the model while the permission dialog is on screen.
        async let model: Void = loadModelIfNeeded()
        if authorization == .notDetermined {
            authorization = await PhotoLibrary.requestAccess()
        } else {
            authorization = PhotoLibrary.status
        }
        log.add("Доступ к фото: \(authorization.rawValue)")
        if hasPhotoAccess {
            libraryCount = PhotoLibrary.imageCount()
        }
        await model
        await runAutomation()
        if hasPhotoAccess {
            BackgroundIndexer.shared.startObservingPhotos()
            indexNewPhotos()
        }
    }

    var hasPhotoAccess: Bool {
        authorization == .authorized || authorization == .limited
    }

    /// CI screenshot mode: `-autoIndex YES` indexes everything, `-autoQuery "a dog"` runs a query.
    private func runAutomation() async {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "autoIndex") {
            startIndexing(limit: 0)
            await indexTask?.value
        }
        if let query = defaults.string(forKey: "autoQuery"), !query.isEmpty {
            await search(text: query)
        }
    }

    func loadModelIfNeeded() async {
        guard clip == nil, modelState != .loading else { return }
        modelState = .loading
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let loaded = try await onWorker { try ClipModel() }
            clip = loaded
            modelSummary = loaded.summary
            modelLoadSeconds = CFAbsoluteTimeGetCurrent() - start
            modelState = .ready
            log.add(String(format: "Модель %@ загружена за %.1f с", ClipModel.variant, modelLoadSeconds ?? 0))
            log.add(loaded.summary)
        } catch {
            modelState = .failed(error.localizedDescription)
            log.add("Не удалось загрузить модель: \(error)")
        }
    }

    // MARK: - Indexing

    /// The "Обновить индекс" button and CI automation: `limit == 0` means all photos.
    func startIndexing(limit: Int) {
        guard !isIndexing, syncTask == nil else { return }
        indexTask = Task { [weak self] in
            _ = await self?.syncPhotos(reason: "вручную", limit: limit)
        }
    }

    /// Picks up new and deleted photos without blocking the caller.
    func indexNewPhotos(reason: String = "новые фото") {
        guard hasPhotoAccess, !isIndexing, syncTask == nil else {
            if isIndexing || syncTask != nil { resyncRequested = true }
            return
        }
        Task { [weak self] in _ = await self?.syncPhotos(reason: reason) }
    }

    func stopIndexing() {
        indexTask?.cancel()
        syncTask?.cancel()
    }

    /// Brings the index in line with the library: forgets deleted photos and indexes the
    /// missing ones, newest first. Safe to interrupt at any point: everything written so far
    /// stays, and the next pass continues where this one stopped.
    /// `deadline` bounds the time spent (short background refresh); `limit` overrides the
    /// "Сколько фото" setting.
    func syncPhotos(reason: String, deadline: Date? = nil, limit: Int? = nil) async -> PhotoSyncResult {
        if let syncTask {
            resyncRequested = true
            return await syncTask.value
        }
        authorization = PhotoLibrary.status
        guard hasPhotoAccess else { return PhotoSyncResult(skipped: "нет доступа к фото") }
        guard !isIndexing else {
            resyncRequested = true
            return PhotoSyncResult(skipped: "индексация уже идёт")
        }
        let task = Task { [weak self] () -> PhotoSyncResult in
            guard let self else { return PhotoSyncResult(skipped: "нет движка") }
            return await self.performSync(reason: reason, deadline: deadline, limit: limit)
        }
        syncTask = task
        let result = await task.value
        syncTask = nil
        if resyncRequested {
            resyncRequested = false
            // Something changed while we were busy; foreground passes catch up right away.
            if deadline == nil && !result.isCancelled { indexNewPhotos(reason: "изменения во время индексации") }
        }
        return result
    }

    private func performSync(reason: String, deadline: Date?, limit: Int?) async -> PhotoSyncResult {
        await loadModelIfNeeded()
        guard clip != nil, let database else { return PhotoSyncResult(skipped: "модель не загружена") }

        // Listing 50k assets takes a moment; keep it off the main thread.
        let assets: [PHAsset] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: PhotoLibrary.fetchImageAssets(limit: 0))
            }
        }
        libraryCount = assets.count
        var result = PhotoSyncResult()

        // Deleted photos. With "selected photos only" access the rest of the library is
        // invisible, not deleted, so nothing is removed then.
        if authorization == .authorized {
            let present = Set(assets.map(\.localIdentifier))
            let gone = Set(database.ids.filter { !present.contains($0) })
            // An empty library next to a big index is more likely a glitch than a mass deletion.
            if !gone.isEmpty && !(assets.isEmpty && database.count > 20) {
                database.remove(ids: gone)
                indexedCount = database.count
                results.removeAll { gone.contains($0.id) }
                result.removed = gone.count
                log.add("Убрано из индекса: \(gone.count) фото, которых больше нет в медиатеке")
            }
        }

        let maxCount = limit ?? UserDefaults.standard.integer(forKey: "ui.indexLimit")
        let wanted = maxCount > 0 ? Array(assets.prefix(maxCount)) : assets
        let outcome = await runIndexing(assets: wanted, reason: reason, deadline: deadline)
        result.added = outcome.added
        result.remaining = outcome.remaining
        result.isCancelled = outcome.cancelled
        return result
    }

    private struct IndexingOutcome {
        var added = 0
        var remaining = 0
        var cancelled = false
    }

    private func runIndexing(assets: [PHAsset], reason: String, deadline: Date? = nil) async -> IndexingOutcome {
        guard let clip, let database else { return IndexingOutcome() }
        let todo = assets.filter { !database.contains($0.localIdentifier) }
        guard !todo.isEmpty else { return IndexingOutcome() }

        isIndexing = true
        progressTotal = todo.count
        progressDone = 0
        let useOCR = ocrEnabled
        log.add("Индексация (\(reason)): \(todo.count) новых из \(assets.count), OCR \(useOCR ? "вкл" : "выкл")")

        var clipSeconds = 0.0, ocrSeconds = 0.0
        var embedded = 0, failures = 0, withText = 0
        let wallStart = CFAbsoluteTimeGetCurrent()
        database.begin()

        var stopReason: String?
        for asset in todo {
            if Task.isCancelled { stopReason = "остановлено"; break }
            if let deadline, Date() >= deadline { stopReason = "кончилось фоновое время"; break }
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal == .serious || thermal == .critical { stopReason = "телефон нагрелся, пауза"; break }
            let side: CGFloat = useOCR ? 1024 : 256
            guard let image = await PhotoLibrary.cgImage(for: asset, side: side) else {
                failures += 1
                progressDone += 1
                continue
            }
            do {
                let (vector, text, tClip, tOCR) = try await onWorker { () throws -> ([Float], String, Double, Double) in
                    // Drain Core ML and Vision temporaries after every photo, so memory stays flat
                    // through tens of thousands of photos (matters most in the background).
                    try autoreleasepool {
                        let t0 = CFAbsoluteTimeGetCurrent()
                        let v = try clip.embed(image: image)
                        let t1 = CFAbsoluteTimeGetCurrent()
                        let s = useOCR ? TextRecognizer.recognize(in: image) : ""
                        return (v, s, t1 - t0, CFAbsoluteTimeGetCurrent() - t1)
                    }
                }
                clipSeconds += tClip
                ocrSeconds += tOCR
                embedded += 1
                if !text.isEmpty { withText += 1 }
                let location = asset.location?.coordinate
                try database.insert(PhotoRecord(
                    id: asset.localIdentifier,
                    created: asset.creationDate,
                    latitude: location?.latitude,
                    longitude: location?.longitude,
                    vector: vector,
                    text: text
                ))
            } catch {
                failures += 1
                if failures <= 5 {
                    log.add("Ошибка на фото: \(error.localizedDescription)")
                }
            }
            progressDone += 1
            if embedded > 0 {
                msPerPhoto = clipSeconds / Double(embedded) * 1000
                msOCR = useOCR ? ocrSeconds / Double(embedded) * 1000 : nil
            }
            if progressDone % 50 == 0 {
                database.commit()
                database.begin()
                indexedCount = database.count
            }
        }

        database.commit()
        indexedCount = database.count
        isIndexing = false
        let wall = CFAbsoluteTimeGetCurrent() - wallStart
        let remaining = todo.count - progressDone
        log.add(String(
            format: "Готово: %d фото за %.0f с (модель %.1f мс, OCR %.0f мс на фото), с текстом %d, ошибок %d",
            embedded, wall, msPerPhoto ?? 0, msOCR ?? 0, withText, failures
        ) + (stopReason.map { ". Прервано: \($0), осталось \(remaining)" } ?? ""))
        return IndexingOutcome(added: embedded, remaining: remaining, cancelled: stopReason == "остановлено")
    }

    func resetIndex() {
        stopIndexing()
        database?.reset()
        indexedCount = 0
        results = []
        log.add("Индекс удалён")
    }

    func recognizedText(for id: String) -> String? {
        database?.text(for: id)
    }

    // MARK: - Search

    /// Main entry point: any language, date words are turned into a filter.
    func search(text: String) async {
        let parsed = QueryParser.parse(text)
        await search(parsed: parsed, modelText: parsed.text, shownQuery: text)
    }

    /// `modelText` is what goes into the CLIP text encoder; `parsed.text` is the
    /// user's own words without the date part, used for keyword search on OCR text.
    /// `via` says how the Russian query became English, shown above the results.
    func search(parsed: ParsedQuery, modelText: String, shownQuery: String, via: String? = nil) async {
        guard let clip, let database else { return }
        let start = CFAbsoluteTimeGetCurrent()

        let semantic = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        log.add("Запрос «\(shownQuery)»: ищу…")

        // Encode first. Indexing may add rows while we wait, so every row-based
        // array below is built after this point from one snapshot of the count.
        var vector: [Float] = []
        if !semantic.isEmpty {
            do {
                // CLIP was trained on captions, so "a photo of parrot" matches better than "parrot".
                let prompt = Self.prompt(for: semantic)
                vector = try await onWorker { try clip.embed(text: prompt) }
            } catch {
                lastQueryInfo = "Ошибка: \(error.localizedDescription)"
                log.add("Ошибка кодирования запроса: \(error)")
                return
            }
        }
        let encoded = CFAbsoluteTimeGetCurrent()
        let count = min(database.count, database.ids.count, database.created.count, database.months.count)

        // Candidate rows after the date filter.
        var allowed: [Bool]? = nil
        if let filter = parsed.dateFilter {
            allowed = (0..<count).map { filter.matches(seconds: database.created[$0], month: database.months[$0]) }
        }
        func isAllowed(_ row: Int) -> Bool { row >= 0 && row < count && (allowed?[row] ?? true) }

        var info: [String] = []
        if let filter = parsed.dateFilter {
            let n = allowed?.filter { $0 }.count ?? 0
            info.append("фильтр: \(filter.label) (\(n) фото)")
        }

        if semantic.isEmpty {
            // Only a date was given: newest first inside the filter.
            let rows = (0..<count).filter(isAllowed)
                .sorted { database.created[$0] > database.created[$1] }
                .prefix(120)
            results = rows.map { SearchHit(id: database.ids[$0], score: 0, textMatch: false) }
            lastQueryInfo = info.joined(separator: " · ")
            return
        }

        do {
            let scores = VectorMath.scores(query: vector, matrix: database.vectors, rows: count)
            func score(_ row: Int) -> Float { row < scores.count ? scores[row] : 0 }

            // Keep only photos reasonably close to the best one, so a rare subject
            // does not get padded with unrelated photos.
            let candidates = (0..<scores.count).filter(isAllowed).sorted { scores[$0] > scores[$1] }
            let best = candidates.first.map(score) ?? 0
            // Below about 0.23 ViT-B/32 is guessing (in tests an irrelevant query like
            // "билет на поезд" topped out at 0.22), so such photos are not shown at all.
            let cutoff = max(best - 0.05, best * 0.82, Self.minimumScore)
            let clipRanked = Array(candidates.prefix { score($0) >= cutoff }.prefix(400))
            let words = (parsed.text + " " + semantic).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let textRanked = database.textMatches(words: words).filter(isAllowed)
            let textSet = Set(textRanked)

            // Reciprocal rank fusion of the two lists.
            var fused: [Int: Double] = [:]
            for (rank, row) in clipRanked.enumerated() { fused[row, default: 0] += 1.0 / Double(60 + rank) }
            for (rank, row) in textRanked.enumerated() { fused[row, default: 0] += 1.0 / Double(60 + rank) }
            let top = fused.sorted { $0.value > $1.value }.prefix(90)
            results = top.map { SearchHit(id: database.ids[$0.key], score: score($0.key), textMatch: textSet.contains($0.key)) }

            let done = CFAbsoluteTimeGetCurrent()
            if let via { info.insert(via, at: 0) }
            info.insert("Ищу: «\(semantic)»", at: 0)
            info.append(String(format: "похожих %d, лучший %.2f", clipRanked.count, best))
            info.append(String(format: "текст %.0f мс, поиск %.0f мс", (encoded - start) * 1000, (done - encoded) * 1000))
            if !textRanked.isEmpty { info.append("совпадений в тексте на фото: \(textRanked.count)") }
            lastQueryInfo = info.joined(separator: " · ")
            log.add("Запрос «\(shownQuery)» → «\(semantic)»: \(lastQueryInfo ?? "")")
        }
    }

    // MARK: - Helpers

    nonisolated static let minimumScore: Float = 0.23

    nonisolated static func prompt(for text: String) -> String {
        // The multilingual text tower takes other languages as they are.
        if text.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil { return text }
        let lower = text.lowercased()
        if lower.hasPrefix("a photo") || lower.hasPrefix("photo of") || lower.split(separator: " ").count > 6 {
            return text
        }
        return "a photo of \(text)"
    }

    private func onWorker<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            worker.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}
