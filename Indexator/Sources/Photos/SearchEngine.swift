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
        // Load the offline city table off the main thread before the first search needs it.
        Task.detached(priority: .utility) { _ = PlaceIndex.shared.count }
        await runAutomation()
        if hasPhotoAccess {
            BackgroundIndexer.shared.startObservingPhotos()
            indexNewPhotos()
        }
        VideoEngine.shared.refreshLibraryCount()
        if VideoEngine.shared.hasIndex {
            VideoEngine.shared.startIndexing(reason: "новые видео")
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
        if defaults.bool(forKey: "autoIndex") {
            VideoEngine.shared.startIndexing(reason: "автотест")
            await VideoEngine.shared.waitForIndexing()
        }
        if let queries = defaults.string(forKey: "searchEval"), !queries.isEmpty {
            await runSearchEval(queries.components(separatedBy: "|"))
        }
        if let query = defaults.string(forKey: "autoQuery"), !query.isEmpty {
            await search(text: query)
        }
    }

    /// CI search-quality check: `-searchEval "собака|еда|…"` runs each query and writes
    /// Documents/search-eval.json with the top photo file names, scores and scene labels,
    /// so scripts/check-search-eval.py can compare them with expectations.
    private func runSearchEval(_ queries: [String]) async {
        guard let database else { return }
        func fileName(_ id: String) -> String {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return id }
            return PHAssetResource.assetResources(for: asset).first?.originalFilename ?? id
        }
        var report: [[String: Any]] = []
        for query in queries where !query.isEmpty {
            await search(text: query)
            report.append([
                "query": query,
                "info": lastQueryInfo ?? "",
                "hits": results.prefix(20).map {
                    ["file": fileName($0.id), "score": Double($0.score), "adj": Double(lastAdjusted[$0.id] ?? 0), "text": $0.textMatch]
                },
                // The photos just below the cutoff, to see how close the misses were.
                "near": lastAdjusted.sorted { $0.value > $1.value }.prefix(12).map { ["file": fileName($0.key), "adj": Double($0.value)] },
            ])
        }
        var photos: [String: [String]] = [:]
        for id in database.ids {
            photos[fileName(id)] = (database.labelsById[id] ?? []).prefix(5).map { String(format: "%@ %.2f", $0.0, $0.1) }
        }
        let json: [String: Any] = ["queries": report, "photos": photos]
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: dir.appendingPathComponent("search-eval.json"))
        log.add("Проверка поиска: \(report.count) запросов записано")
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
            if !Task.isCancelled { VideoEngine.shared.startIndexing(reason: "вручную") }
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
        VideoEngine.shared.stopIndexing()
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
        if !outcome.cancelled { await labelMissingPhotos(deadline: deadline) }
        result.added = outcome.added
        result.remaining = outcome.remaining
        result.isCancelled = outcome.cancelled
        return result
    }

    /// Photos indexed before scene labels existed get them here, without redoing CLIP or OCR.
    private func labelMissingPhotos(deadline: Date?) async {
        guard let database else { return }
        let missing = database.idsWithoutLabels
        guard !missing.isEmpty else { return }
        log.add("Метки сцен: \(missing.count) фото без меток")
        var done = 0
        let start = CFAbsoluteTimeGetCurrent()
        for id in missing {
            if Task.isCancelled { break }
            if let deadline, Date() >= deadline { break }
            guard let asset = PhotoLibrary.asset(withId: id),
                  let image = await PhotoLibrary.cgImage(for: asset, side: 360) else {
                database.setLabels([], for: id)
                continue
            }
            let labels = (try? await onWorker { autoreleasepool { ImageLabeler.labels(for: image) } }) ?? []
            database.setLabels(labels, for: id)
            done += 1
        }
        log.add(String(format: "Метки сцен: готово %d за %.0f с", done, CFAbsoluteTimeGetCurrent() - start))
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
                let (vector, text, labels, tClip, tOCR) = try await onWorker { () throws -> ([Float], String, [(String, Float)], Double, Double) in
                    // Drain Core ML and Vision temporaries after every photo, so memory stays flat
                    // through tens of thousands of photos (matters most in the background).
                    try autoreleasepool {
                        let t0 = CFAbsoluteTimeGetCurrent()
                        let v = try clip.embed(image: image)
                        let t1 = CFAbsoluteTimeGetCurrent()
                        let s = useOCR ? TextRecognizer.recognize(in: image) : ""
                        let l = ImageLabeler.labels(for: image)
                        return (v, s, l, t1 - t0, CFAbsoluteTimeGetCurrent() - t1)
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
                database.setLabels(labels, for: asset.localIdentifier)
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
        VideoEngine.shared.resetIndex()
        indexedCount = 0
        results = []
        log.add("Индекс удалён")
    }

    /// Video indexing shares the model and the worker queue, so only one
    /// prediction runs at a time and memory stays flat.
    func embedFrame(_ image: CGImage) async throws -> [Float] {
        guard let clip else { throw ClipModelError.noOutput }
        return try await onWorker { try clip.embed(image: image) }
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

        // A city in the query becomes a GPS filter, and its words leave the semantic part:
        // «архитектура Валенсии» = photos taken in Valencia that look like architecture.
        var modelText = modelText
        var placeMatch: PlaceMatch?
        if let match = PlaceIndex.shared.match(in: parsed.text) {
            // Only a city where photos were actually taken counts; otherwise the word
            // probably means something else and stays in the query.
            if Self.photosNear(match, in: database) != nil {
                placeMatch = match
                let glue: Set<String> = ["в", "во", "из", "на", "у", "около", "возле", "рядом", "под",
                                         "in", "at", "from", "near", "around"]
                let rest = PlaceIndex.normalize(modelText).split(separator: " ")
                    .map(String.init)
                    .filter { !match.words.contains($0) && !glue.contains($0) }
                modelText = rest.joined(separator: " ")
            }
        }

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
        // Rows can shift while the encoder runs (deleted photos), so the place filter is built now.
        let place = placeMatch.flatMap { Self.photosNear($0, in: database) }
        let placeRows = place.map { Set($0.1) }

        // Candidate rows after the date filter.
        var allowed: [Bool]? = nil
        if let filter = parsed.dateFilter {
            allowed = (0..<count).map { filter.matches(seconds: database.created[$0], month: database.months[$0]) }
        }
        func isAllowed(_ row: Int) -> Bool {
            row >= 0 && row < count && (allowed?[row] ?? true) && (placeRows?.contains(row) ?? true)
        }

        var info: [String] = []
        if let place {
            info.append("место: \(place.0.displayName) (\(place.1.count) фото)")
        }
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
            if let filter = parsed.dateFilter {
                VideoEngine.shared.search(dateFilter: filter)
            } else {
                VideoEngine.shared.clearResults()
            }
            lastQueryInfo = info.joined(separator: " · ")
            return
        }

        // Some photos score high against almost any text (a deer and a lioness came up for
        // «собака», «попугай» and «еда» alike). Subtracting each photo's average score over a
        // set of unrelated captions removes that bias, so the ranking reflects the query.
        let baseline = await photoBaselines(count: count)

        do {
            let scores = VectorMath.scores(query: vector, matrix: database.vectors, rows: count)
            func score(_ row: Int) -> Float { row < scores.count ? scores[row] : 0 }
            func adjusted(_ row: Int) -> Float { score(row) - (row < baseline.count ? baseline[row] : 0) }

            // Keep only photos close to the best one by the adjusted score, so a rare subject
            // is not padded with lookalikes, and nothing at all when even the best is weak.
            let candidates = (0..<scores.count).filter(isAllowed).sorted { adjusted($0) > adjusted($1) }
            let best = candidates.map(score).max() ?? 0
            let bestAdjusted = candidates.first.map(adjusted) ?? 0
            // Nothing is shown when even the best photo barely beats its own average
            // («попугай» with no parrots: +0.02; a real match: +0.04 and more).
            let cutoff = max(bestAdjusted - Self.adjustedMargin, bestAdjusted * 0.5, Self.minimumAdjusted / 2)
            let clipRanked = bestAdjusted < Self.minimumAdjusted ? [] :
                Array(candidates.prefix { adjusted($0) >= cutoff }.filter { score($0) >= Self.minimumScore }.prefix(300))
            lastAdjusted = Dictionary(uniqueKeysWithValues: candidates.prefix(40).map { (database.ids[$0], adjusted($0)) })

            // Text on the photo is explicit evidence and may add photos on its own, but the
            // city words are already a GPS filter and do not count as text here.
            let placeWords = placeMatch?.words ?? []
            let words = (parsed.text + " " + semantic)
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                .filter { !placeWords.contains(PlaceIndex.normalize($0)) }
            let textRanked = words.isEmpty ? [] : database.textMatches(words: words).filter(isAllowed)
            let textSet = Set(textRanked)

            // Scene labels from Apple's classifier never add photos by themselves (a GPS tag
            // plus a vague label pulled in a catamaran for «архитектура»). They lift photos
            // CLIP already likes, and add ones CLIP is at least mildly positive about.
            let wantedLabels = LabelQuery.labels(for: semantic).labels
            var labelScore: [Int: Float] = [:]
            if !wantedLabels.isEmpty {
                for row in candidates.prefix(600) where adjusted(row) >= 0.005 {
                    guard row < database.ids.count, let labels = database.labelsById[database.ids[row]] else { continue }
                    let sure = labels.filter { wantedLabels.contains($0.0) }.map(\.1).max() ?? 0
                    if sure >= 0.3 { labelScore[row] = sure }
                }
            }
            // A sure label rescues a photo CLIP is mildly positive about, even when CLIP alone shows
            // nothing: broad words like «еда» are where Apple's classifier beats CLIP.
            let clipSet = Set(clipRanked)
            let rescued = labelScore.filter { !clipSet.contains($0.key) && $0.value >= 0.6 }.map(\.key)
            // Ties (common: the classifier often gives several photos the same confidence) are
            // broken by CLIP, so the order is stable and labels never reshuffle CLIP's ranking.
            let labelRanked = labelScore.sorted { ($0.value, adjusted($0.key)) > ($1.value, adjusted($1.key)) }.map(\.key)

            // Reciprocal rank fusion over the photos that made it in.
            var fused: [Int: Double] = [:]
            for (rank, row) in clipRanked.enumerated() { fused[row, default: 0] += 1.0 / Double(60 + rank) }
            for row in rescued { fused[row, default: 0] += 0 }
            for (rank, row) in textRanked.enumerated() { fused[row, default: 0] += 1.0 / Double(60 + rank) }
            for (rank, row) in labelRanked.enumerated() where fused[row] != nil {
                fused[row, default: 0] += 0.5 / Double(60 + rank)
            }
            let top = fused.sorted { ($0.value, adjusted($0.key)) > ($1.value, adjusted($1.key)) }.prefix(90)
            results = top.map { SearchHit(id: database.ids[$0.key], score: score($0.key), textMatch: textSet.contains($0.key)) }
            VideoEngine.shared.search(vector: vector, words: words, dateFilter: parsed.dateFilter, photoBest: best,
                                      references: referenceVectors)

            let done = CFAbsoluteTimeGetCurrent()
            if let via { info.insert(via, at: 0) }
            info.insert("Ищу: «\(semantic)»", at: 0)
            info.append(String(format: "похожих %d, лучший %.2f (%+.3f)", clipRanked.count, best, bestAdjusted))
            info.append(String(format: "текст %.0f мс, поиск %.0f мс", (encoded - start) * 1000, (done - encoded) * 1000))
            if !textRanked.isEmpty { info.append("совпадений в тексте на фото: \(textRanked.count)") }
            if !wantedLabels.isEmpty { info.append("усилено метками сцен: \(labelRanked.count)") }
            lastQueryInfo = info.joined(separator: " · ")
            log.add("Запрос «\(shownQuery)» → «\(semantic)»: \(lastQueryInfo ?? "")")
        }
    }

    // MARK: - Places

    /// Picks the city the user most likely means (the one with photos taken there) and
    /// returns the rows inside it. Nil when no photo was taken in any city of that name.
    private static func photosNear(_ match: PlaceMatch, in database: IndexDatabase) -> (Place, [Int])? {
        var best: (Place, [Int])?
        for candidate in match.places.prefix(30) {
            let radius = PlaceIndex.radiusKm(for: candidate)
            var rows: [Int] = []
            for row in 0..<min(database.latitudes.count, database.longitudes.count) {
                let lat = database.latitudes[row], lon = database.longitudes[row]
                if lat.isNaN || lon.isNaN { continue }
                if abs(lat - candidate.latitude) > 1 { continue }
                if PlaceIndex.distanceKm(lat, lon, candidate.latitude, candidate.longitude) <= radius { rows.append(row) }
            }
            if !rows.isEmpty && rows.count > (best?.1.count ?? 0) { best = (candidate, rows) }
        }
        return best
    }

    private var placeNameCache: [String: String] = [:]

    /// Nearest city for a photo in the index, e.g. «Валенсия». Nil without GPS.
    func placeName(for id: String) -> String? {
        if let cached = placeNameCache[id] { return cached.isEmpty ? nil : cached }
        guard let database, let row = database.row(of: id), row < database.latitudes.count else { return nil }
        let name = placeName(latitude: database.latitudes[row], longitude: database.longitudes[row])
        placeNameCache[id] = name ?? ""
        return name
    }

    func placeName(latitude: Double, longitude: Double) -> String? {
        PlaceIndex.shared.nearest(latitude: latitude, longitude: longitude)?.displayName
    }

    // MARK: - Helpers

    /// Raw CLIP similarity below which a photo is never shown.
    nonisolated static let minimumScore: Float = 0.20
    /// How far below the best adjusted score a photo may be and still be shown.
    nonisolated static let adjustedMargin: Float = 0.025
    /// The best photo must beat its own average by this much, or nothing is shown.
    nonisolated static let minimumAdjusted: Float = 0.03

    /// Adjusted scores of the last search's top photos, for the CI quality report.
    private(set) var lastAdjusted: [String: Float] = [:]

    /// Captions about unrelated everyday subjects in both languages; a photo's average
    /// similarity to them is its general "matches anything" level.
    private static let referenceCaptions = [
        "a photo", "фотография", "a photo of a person", "фото человека", "a photo of an animal", "фото животного",
        "a photo of food", "фото еды", "a photo of a landscape", "фото природы", "a photo of a building", "фото здания",
        "a photo of a document", "фото документа", "a photo of a car", "фото машины", "a photo of a room", "фото комнаты",
        "a screenshot", "скриншот",
    ]
    private var referenceVectors: [[Float]] = []
    private var baselineCache: (count: Int, values: [Float]) = (0, [])

    private func photoBaselines(count: Int) async -> [Float] {
        guard let clip, let database, count > 0 else { return [] }
        if baselineCache.count == count, baselineCache.values.count == count { return baselineCache.values }
        if referenceVectors.isEmpty {
            let captions = Self.referenceCaptions
            referenceVectors = (try? await onWorker { try captions.map { try clip.embed(text: $0) } }) ?? []
        }
        guard !referenceVectors.isEmpty else { return [] }
        var sum = [Float](repeating: 0, count: count)
        for reference in referenceVectors {
            let s = VectorMath.scores(query: reference, matrix: database.vectors, rows: count)
            for i in 0..<min(count, s.count) { sum[i] += s[i] }
        }
        let n = Float(referenceVectors.count)
        let values = sum.map { $0 / n }
        baselineCache = (count, values)
        return values
    }

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
