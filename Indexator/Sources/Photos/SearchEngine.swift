// SPDX-License-Identifier: GPL-3.0-or-later
//
// Phase 1 engine: loads MobileCLIP, indexes the newest N photos, answers text queries.

import Foundation
import Photos

@MainActor
final class SearchEngine: ObservableObject {
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
    @Published private(set) var results: [SearchHit] = []
    @Published private(set) var lastQueryInfo: String?

    private var clip: MobileCLIP?
    private let store = EmbeddingStore()
    private var indexTask: Task<Void, Never>?
    private let worker = DispatchQueue(label: "indexator.clip", qos: .userInitiated)
    private let log = AppLog.shared

    init() {
        indexedCount = store.count
    }

    // MARK: - Setup

    func prepare() async {
        if authorization == .notDetermined {
            authorization = await PhotoLibrary.requestAccess()
        } else {
            authorization = PhotoLibrary.status
        }
        if authorization == .authorized || authorization == .limited {
            libraryCount = PhotoLibrary.imageCount()
        }
        await loadModelIfNeeded()
        await runAutomation()
    }

    /// CI screenshot mode: `-autoIndex YES` indexes everything, `-autoQuery "a dog"` runs a query.
    private func runAutomation() async {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "autoIndex") {
            startIndexing(limit: 0)
            await indexTask?.value
        }
        if let query = defaults.string(forKey: "autoQuery"), !query.isEmpty {
            await search(modelQuery: query, shownQuery: query)
        }
    }

    private func loadModelIfNeeded() async {
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
        guard let clip, !isIndexing else { return }
        isIndexing = true
        indexTask = Task { [weak self] in
            guard let self else { return }
            let assets = PhotoLibrary.fetchImageAssets(limit: limit)
            let todo = assets.filter { !self.store.contains($0.localIdentifier) }
            self.progressTotal = todo.count
            self.progressDone = 0
            self.log.add("Индексация: \(todo.count) новых из \(assets.count)")

            var embedSeconds = 0.0
            var embedded = 0
            var failures = 0
            let wallStart = CFAbsoluteTimeGetCurrent()

            for asset in todo {
                if Task.isCancelled { break }
                guard let image = await PhotoLibrary.cgImage(for: asset, side: 256) else {
                    failures += 1
                    self.progressDone += 1
                    continue
                }
                let start = CFAbsoluteTimeGetCurrent()
                do {
                    let vector = try await self.onWorker { try clip.embed(image: image) }
                    embedSeconds += CFAbsoluteTimeGetCurrent() - start
                    embedded += 1
                    self.store.add(id: asset.localIdentifier, vector: vector)
                } catch {
                    failures += 1
                    if failures <= 5 {
                        self.log.add("Ошибка на фото: \(error.localizedDescription)")
                    }
                }
                self.progressDone += 1
                if embedded > 0 {
                    self.msPerPhoto = embedSeconds / Double(embedded) * 1000
                }
                if self.progressDone % 100 == 0 {
                    self.store.save()
                    self.indexedCount = self.store.count
                }
            }

            self.store.save()
            self.indexedCount = self.store.count
            self.isIndexing = false
            let wall = CFAbsoluteTimeGetCurrent() - wallStart
            self.log.add(String(
                format: "Готово: %d фото за %.0f с (модель %.1f мс/фото), ошибок %d",
                embedded, wall, self.msPerPhoto ?? 0, failures
            ))
        }
    }

    func stopIndexing() {
        indexTask?.cancel()
    }

    func resetIndex() {
        stopIndexing()
        store.reset()
        indexedCount = 0
        results = []
        log.add("Индекс удалён")
    }

    // MARK: - Search

    /// `modelQuery` is what goes into the text encoder (English), `shownQuery` is what the user typed.
    func search(modelQuery: String, shownQuery: String) async {
        guard let clip else { return }
        let trimmed = modelQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            lastQueryInfo = nil
            return
        }
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let vector = try await onWorker { try clip.embed(text: trimmed) }
            let encoded = CFAbsoluteTimeGetCurrent()
            results = store.search(vector, limit: 60)
            let done = CFAbsoluteTimeGetCurrent()
            var info = String(format: "текст %.0f мс, поиск %.0f мс", (encoded - start) * 1000, (done - encoded) * 1000)
            if trimmed != shownQuery {
                info = "«\(trimmed)» · " + info
            }
            lastQueryInfo = info
            log.add("Запрос «\(shownQuery)» → «\(trimmed)»: \(info), лучший \(String(format: "%.3f", results.first?.score ?? 0))")
        } catch {
            lastQueryInfo = "Ошибка: \(error.localizedDescription)"
            log.add("Ошибка поиска: \(error)")
        }
    }

    // MARK: - Helpers

    private func onWorker<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            worker.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}
