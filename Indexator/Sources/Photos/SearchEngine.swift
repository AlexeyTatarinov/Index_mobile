// SPDX-License-Identifier: GPL-3.0-or-later
//
// Loads MobileCLIP, indexes photos (vector + OCR text + date/place) into SQLite,
// and answers queries with hybrid ranking: meaning (CLIP) + words found on photos.

import BackgroundTasks
import Foundation
import Photos

struct SearchHit: Identifiable, Hashable {
    let id: String        // PHAsset.localIdentifier
    let score: Float      // CLIP similarity, for display
    let textMatch: Bool   // query words were found on the photo
}

@MainActor
final class SearchEngine: ObservableObject {
    static let shared = SearchEngine()
    static let backgroundTaskId = "io.github.alexeytatarinov.indexator.index"

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

    private var clip: MobileCLIP?
    private var database: IndexDatabase?
    private var indexTask: Task<Void, Never>?
    private let worker = DispatchQueue(label: "indexator.clip", qos: .userInitiated)
    private let log = AppLog.shared

    private init() {
        do {
            database = try IndexDatabase(model: MobileCLIP.variant)
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
        if indexedCount > 0 && !isIndexing {
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
            let parsed = QueryParser.parse(query)
            await search(parsed: parsed, modelText: parsed.text, shownQuery: query)
        }
    }

    func loadModelIfNeeded() async {
        guard clip == nil, modelState != .loading else { return }
        modelState = .loading
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let loaded = try await onWorker { try MobileCLIP() }
            clip = loaded
            modelSummary = loaded.summary
            modelLoadSeconds = CFAbsoluteTimeGetCurrent() - start
            modelState = .ready
            log.add(String(format: "Модель %@ загружена за %.1f с", MobileCLIP.variant, modelLoadSeconds ?? 0))
            log.add(loaded.summary)
        } catch {
            modelState = .failed(error.localizedDescription)
            log.add("Не удалось загрузить модель: \(error)")
        }
    }

    // MARK: - Indexing

    func startIndexing(limit: Int) {
        guard !isIndexing else { return }
        indexTask = Task { [weak self] in
            guard let self else { return }
            await self.runIndexing(assets: PhotoLibrary.fetchImageAssets(limit: limit), reason: "вручную")
        }
    }

    /// Photos taken after the newest indexed one.
    func indexNewPhotos() {
        guard !isIndexing, let newest = database?.newestCreated else { return }
        indexTask = Task { [weak self] in
            guard let self else { return }
            let assets = PhotoLibrary.fetchImageAssets(limit: 0, newerThan: newest)
            guard !assets.isEmpty else { return }
            await self.runIndexing(assets: assets, reason: "новые фото")
        }
    }

    func stopIndexing() {
        indexTask?.cancel()
    }

    /// Called from a BGProcessingTask: index everything that is not indexed yet.
    func runBackgroundIndexing() async {
        await loadModelIfNeeded()
        authorization = PhotoLibrary.status
        guard hasPhotoAccess, !isIndexing else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runIndexing(assets: PhotoLibrary.fetchImageAssets(limit: 0), reason: "в фоне")
        }
        indexTask = task
        await task.value
    }

    static func scheduleBackgroundIndexing() {
        let request = BGProcessingTaskRequest(identifier: backgroundTaskId)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLog.shared.add("Фоновая задача не запланирована: \(error.localizedDescription)")
        }
    }

    private func runIndexing(assets: [PHAsset], reason: String) async {
        guard let clip, let database else { return }
        let todo = assets.filter { !database.contains($0.localIdentifier) }
        guard !todo.isEmpty else { return }

        isIndexing = true
        progressTotal = todo.count
        progressDone = 0
        let useOCR = ocrEnabled
        log.add("Индексация (\(reason)): \(todo.count) новых из \(assets.count), OCR \(useOCR ? "вкл" : "выкл")")

        var clipSeconds = 0.0, ocrSeconds = 0.0
        var embedded = 0, failures = 0, withText = 0
        let wallStart = CFAbsoluteTimeGetCurrent()
        database.begin()

        for asset in todo {
            if Task.isCancelled { break }
            let side: CGFloat = useOCR ? 1024 : 256
            guard let image = await PhotoLibrary.cgImage(for: asset, side: side) else {
                failures += 1
                progressDone += 1
                continue
            }
            do {
                let (vector, text, tClip, tOCR) = try await onWorker { () throws -> ([Float], String, Double, Double) in
                    let t0 = CFAbsoluteTimeGetCurrent()
                    let v = try clip.embed(image: image)
                    let t1 = CFAbsoluteTimeGetCurrent()
                    let s = useOCR ? TextRecognizer.recognize(in: image) : ""
                    return (v, s, t1 - t0, CFAbsoluteTimeGetCurrent() - t1)
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
        log.add(String(
            format: "Готово: %d фото за %.0f с (модель %.1f мс, OCR %.0f мс на фото), с текстом %d, ошибок %d",
            embedded, wall, msPerPhoto ?? 0, msOCR ?? 0, withText, failures
        ))
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

    /// `modelText` is what goes into the CLIP text encoder (English); `parsed.text` is the
    /// user's own words without the date part, used for keyword search on OCR text.
    /// `via` says how the Russian query became English, shown above the results.
    func search(parsed: ParsedQuery, modelText: String, shownQuery: String, via: String? = nil) async {
        guard let clip, let database else { return }
        let start = CFAbsoluteTimeGetCurrent()

        // Candidate rows after the date filter.
        var allowed: [Bool]? = nil
        if let filter = parsed.dateFilter {
            allowed = (0..<database.count).map { filter.matches(seconds: database.created[$0], month: database.months[$0]) }
        }
        func isAllowed(_ row: Int) -> Bool { allowed?[row] ?? true }

        let semantic = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        // CLIP only understands English: with Russian left over, rely on words found on photos.
        let untranslated = semantic.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil
        var info: [String] = []
        if let filter = parsed.dateFilter {
            let n = allowed?.filter { $0 }.count ?? 0
            info.append("фильтр: \(filter.label) (\(n) фото)")
        }

        if semantic.isEmpty {
            // Only a date was given: newest first inside the filter.
            let rows = (0..<database.count).filter(isAllowed)
                .sorted { database.created[$0] > database.created[$1] }
                .prefix(120)
            results = rows.map { SearchHit(id: database.ids[$0], score: 0, textMatch: false) }
            lastQueryInfo = info.joined(separator: " · ")
            return
        }

        do {
            // CLIP was trained on captions, so "a photo of a parrot" matches better than "parrot".
            let prompt = Self.prompt(for: semantic)
            let vector = try await onWorker { try clip.embed(text: prompt) }
            let encoded = CFAbsoluteTimeGetCurrent()
            let scores = VectorMath.scores(query: vector, matrix: database.vectors, rows: database.count)

            // Keep only photos reasonably close to the best one, so a rare subject
            // does not get padded with unrelated photos.
            let candidates = (0..<scores.count).filter(isAllowed).sorted { scores[$0] > scores[$1] }
            let best = candidates.first.map { scores[$0] } ?? 0
            let cutoff = max(best - 0.05, best * 0.82)
            let clipRanked = untranslated ? [] : Array(candidates.prefix { scores[$0] >= cutoff }.prefix(400))
            let words = (parsed.text + " " + semantic).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let textRanked = database.textMatches(words: words).filter(isAllowed)
            let textSet = Set(textRanked)

            // Reciprocal rank fusion of the two lists.
            var fused: [Int: Double] = [:]
            for (rank, row) in clipRanked.enumerated() { fused[row, default: 0] += 1.0 / Double(60 + rank) }
            for (rank, row) in textRanked.enumerated() { fused[row, default: 0] += 1.0 / Double(60 + rank) }
            let top = fused.sorted { $0.value > $1.value }.prefix(90)
            results = top.map { SearchHit(id: database.ids[$0.key], score: scores[$0.key], textMatch: textSet.contains($0.key)) }

            let done = CFAbsoluteTimeGetCurrent()
            if let via { info.insert(via, at: 0) }
            info.insert("Ищу: «\(untranslated ? parsed.text : semantic)»", at: 0)
            if !untranslated { info.append(String(format: "похожих %d, лучший %.2f", clipRanked.count, best)) }
            info.append(String(format: "текст %.0f мс, поиск %.0f мс", (encoded - start) * 1000, (done - encoded) * 1000))
            if !textRanked.isEmpty { info.append("совпадений в тексте на фото: \(textRanked.count)") }
            lastQueryInfo = info.joined(separator: " · ")
            log.add("Запрос «\(shownQuery)» → «\(semantic)»: \(lastQueryInfo ?? "")")
        } catch {
            lastQueryInfo = "Ошибка: \(error.localizedDescription)"
            log.add("Ошибка поиска: \(error)")
        }
    }

    // MARK: - Helpers

    nonisolated static func prompt(for text: String) -> String {
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
