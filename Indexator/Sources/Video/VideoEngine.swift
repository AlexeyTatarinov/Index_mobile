// SPDX-License-Identifier: GPL-3.0-or-later
//
// Video search: samples keyframes of every video in the library, embeds them
// with the same CLIP image tower as photos (so Russian queries work the same),
// and finds both the video and the moment in it. Optionally indexes speech.
// The model and its worker queue are shared with SearchEngine, so photo and
// video indexing never run predictions at the same time.

import AVFoundation
import Foundation
import Photos

struct VideoHit: Identifiable, Hashable {
    let id: String          // PHAsset.localIdentifier
    let score: Float        // CLIP similarity of the best frame
    let time: Double        // the moment to open at, seconds
    let moments: [Double]   // other good moments, best first (includes `time`)
    let duration: Double
    let speech: String?     // matching words said in the video
}

@MainActor
final class VideoEngine: ObservableObject {
    static let shared = VideoEngine()

    @Published private(set) var libraryCount = 0
    @Published private(set) var indexedCount = 0
    @Published private(set) var frameCount = 0
    @Published private(set) var isIndexing = false
    @Published private(set) var progressDone = 0
    @Published private(set) var progressTotal = 0
    @Published private(set) var skippedCloud = 0
    @Published private(set) var secondsPerVideo: Double?
    @Published private(set) var results: [VideoHit] = []
    @Published private(set) var lastQueryInfo: String?

    @Published var enabled: Bool = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Keys.enabled)
            if !enabled { stopIndexing(); results = [] }
        }
    }
    @Published var speechEnabled: Bool = UserDefaults.standard.bool(forKey: Keys.speech) {
        didSet { UserDefaults.standard.set(speechEnabled, forKey: Keys.speech) }
    }
    @Published var allowCloud: Bool = UserDefaults.standard.bool(forKey: Keys.cloud) {
        didSet { UserDefaults.standard.set(allowCloud, forKey: Keys.cloud) }
    }

    private enum Keys {
        static let enabled = "video.enabled"
        static let speech = "video.speech"
        static let cloud = "video.allowCloud"
    }

    private var store: VideoStore?
    private var indexTask: Task<Void, Never>?
    private let log = AppLog.shared

    private init() {
        do {
            store = try VideoStore(model: ClipModel.variant)
            refreshCounts()
        } catch {
            log.add("База видео не открылась: \(error.localizedDescription)")
        }
    }

    var hasIndex: Bool { indexedCount > 0 }

    func refreshLibraryCount() {
        if SearchEngine.shared.hasPhotoAccess { libraryCount = VideoLibrary.count() }
    }

    private func refreshCounts() {
        indexedCount = store?.count ?? 0
        frameCount = store?.frameCount ?? 0
    }

    // MARK: - Indexing

    /// Indexes every video that is not in the index yet. Waits for photo indexing first.
    func startIndexing(reason: String) {
        guard enabled, !isIndexing, indexTask == nil else { return }
        indexTask = Task { [weak self] in
            await self?.runIndexing(reason: reason)
            self?.indexTask = nil
        }
    }

    func waitForIndexing() async {
        await indexTask?.value
    }

    func stopIndexing() {
        indexTask?.cancel()
    }

    func resetIndex() {
        stopIndexing()
        store?.reset()
        refreshCounts()
        results = []
        log.add("Индекс видео удалён")
    }

    private func runIndexing(reason: String) async {
        let photos = SearchEngine.shared
        guard let store, photos.hasPhotoAccess else { return }
        // One model, one queue: let the photos finish first.
        while photos.isIndexing {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(2))
        }
        await photos.loadModelIfNeeded()
        guard photos.modelState == .ready else { return }

        let assets = VideoLibrary.fetchAssets()
        libraryCount = assets.count
        let todo = assets.filter { !store.contains($0.localIdentifier) }
        guard !todo.isEmpty else { return }

        var useSpeech = speechEnabled && VideoSpeech.isAvailableOffline
        if useSpeech { useSpeech = await VideoSpeech.requestAuthorization() }
        if speechEnabled && !useSpeech {
            log.add("Речь в видео: офлайн-распознавание русского недоступно или нет разрешения")
        }

        isIndexing = true
        progressDone = 0
        progressTotal = todo.count
        skippedCloud = 0
        log.add("Видео (\(reason)): \(todo.count) новых из \(assets.count), речь \(useSpeech ? "вкл" : "выкл")")
        let start = CFAbsoluteTimeGetCurrent()
        var done = 0, frames = 0, failures = 0, withSpeech = 0

        for asset in todo {
            if Task.isCancelled { break }
            guard let avAsset = await VideoLibrary.avAsset(for: asset, allowNetwork: allowCloud) else {
                skippedCloud += 1
                progressDone += 1
                continue
            }
            let duration = asset.duration
            let sampled = await sampleFrames(avAsset, duration: duration)
            if Task.isCancelled { break }
            let speech = useSpeech ? await VideoSpeech.transcribe(avAsset, duration: duration) : []
            if !speech.isEmpty { withSpeech += 1 }
            if sampled.isEmpty { failures += 1 }
            do {
                try store.insert(VideoRecord(
                    id: asset.localIdentifier,
                    created: asset.creationDate,
                    duration: duration,
                    latitude: asset.location?.coordinate.latitude,
                    longitude: asset.location?.coordinate.longitude,
                    frames: sampled,
                    speech: speech
                ))
                frames += sampled.count
                done += 1
            } catch {
                failures += 1
                log.add("Ошибка записи видео: \(error.localizedDescription)")
            }
            progressDone += 1
            secondsPerVideo = (CFAbsoluteTimeGetCurrent() - start) / Double(max(done, 1))
            if progressDone % 10 == 0 { refreshCounts() }
        }

        refreshCounts()
        isIndexing = false
        log.add(String(
            format: "Видео готово: %d за %.0f с, кадров %d, с речью %d, только в iCloud %d, без кадров %d",
            done, CFAbsoluteTimeGetCurrent() - start, frames, withSpeech, skippedCloud, failures
        ))
    }

    /// Frames at evenly spaced times, embedded one by one (only one frame in memory
    /// at a time), then thinned to scene changes.
    private func sampleFrames(_ avAsset: AVAsset, duration: Double) async -> [VideoFrame] {
        let generator = VideoLibrary.generator(for: avAsset, maxSide: 336)
        var frames: [VideoFrame] = []
        for time in VideoSampler.times(duration: duration) {
            if Task.isCancelled { break }
            guard let result = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)) else { continue }
            guard let vector = try? await SearchEngine.shared.embedFrame(result.image) else { continue }
            let actual = result.actualTime.seconds
            frames.append(VideoFrame(time: actual.isFinite ? actual : time, vector: vector))
        }
        return VideoSampler.keepSceneChanges(frames)
    }

    // MARK: - Search

    func clearResults() {
        results = []
        lastQueryInfo = nil
    }

    /// Only a date was asked: newest videos in that period.
    func search(dateFilter: DateFilter) {
        guard enabled, let store else { return clearResults() }
        let rows = (0..<store.count)
            .filter { dateFilter.matches(seconds: store.created[$0], month: store.months[$0]) }
            .sorted { store.created[$0] > store.created[$1] }
            .prefix(60)
        results = rows.map {
            VideoHit(id: store.ids[$0], score: 0, time: 0, moments: [], duration: store.durations[$0], speech: nil)
        }
        lastQueryInfo = results.isEmpty ? nil : "видео \(results.count)"
    }

    /// `photoBest` is the best photo score for the same query: videos must be about
    /// as close as the photos shown, so a query about dogs does not bring random videos.
    private var frameBaselineCache: (rows: Int, values: [Float]) = (0, [])
    /// How far below the best photo a video may be; the best video score is kept for the search check.
    static let photoMargin: Float = 0.03
    private(set) var lastTop: Float = 0

    private func frameBaselines(references: [[Float]], rows: Int) -> [Float] {
        guard let store, !references.isEmpty, rows > 0 else { return [] }
        if frameBaselineCache.rows == rows, frameBaselineCache.values.count == rows { return frameBaselineCache.values }
        var sum = [Float](repeating: 0, count: rows)
        for reference in references {
            let s = VectorMath.scores(query: reference, matrix: store.frameVectors, rows: rows)
            for i in 0..<min(rows, s.count) { sum[i] += s[i] }
        }
        let n = Float(references.count)
        let values = sum.map { $0 / n }
        frameBaselineCache = (rows, values)
        return values
    }

    /// `references` are the neutral-caption vectors photo search uses: each frame's average
    /// similarity to them is subtracted, the same "matches anything" correction as for photos.
    func search(vector: [Float], words: [String], dateFilter: DateFilter?, photoBest: Float,
                photoBestAdjusted: Float? = nil, references: [[Float]] = []) {
        lastTop = 0
        guard enabled, let store, store.count > 0 else { return clearResults() }
        let videos = store.count
        let frameRows = min(store.frameCount, store.frameVideo.count, store.frameTime.count)
        var scores = VectorMath.scores(query: vector, matrix: store.frameVectors, rows: frameRows)
        let baseline = frameBaselines(references: references, rows: frameRows)
        if baseline.count == scores.count {
            for i in scores.indices { scores[i] -= baseline[i] }
        }

        func allowed(_ row: Int) -> Bool {
            guard row >= 0 && row < videos else { return false }
            guard let dateFilter else { return true }
            return dateFilter.matches(seconds: store.created[row], month: store.months[row])
        }

        // Best frame per video, plus all its frames for "other moments".
        var best: [Int: (score: Float, time: Double)] = [:]
        var framesOf: [Int: [(score: Float, time: Double)]] = [:]
        for i in 0..<scores.count {
            let row = Int(store.frameVideo[i])
            guard allowed(row) else { continue }
            let entry: (score: Float, time: Double) = (scores[i], Double(store.frameTime[i]))
            framesOf[row, default: []].append(entry)
            if entry.score > (best[row]?.score ?? -1) { best[row] = entry }
        }

        let ranked = best.sorted { $0.value.score > $1.value.score }
        let top = ranked.first?.value.score ?? 0
        let cutoff: Float
        if baseline.isEmpty {
            // No reference captions yet: the older raw-score rule.
            let reference = max(top, photoBest)
            cutoff = max(top - 0.05, top * 0.82, reference - 0.05)
        } else {
            // A video must match about as well as the photos shown for the same query: lemurs came
            // up for «попугай» next to real parrot photos. With no photo match, a stricter floor.
            let floor = photoBestAdjusted.map { max(SearchEngine.minimumAdjusted, $0 - Self.photoMargin) }
                ?? SearchEngine.minimumAdjusted + 0.01
            cutoff = top < floor ? .infinity : max(top - SearchEngine.adjustedMargin, top * 0.5, floor)
        }
        lastTop = top
        let clipRanked = ranked.prefix { $0.value.score >= cutoff }.prefix(100).map { $0.key }

        // Words said in the video.
        let spoken = store.speechMatches(words: words).filter { allowed($0.row) }
        var speechOf: [Int: (time: Double, text: String)] = [:]
        var speechRanked: [Int] = []
        for match in spoken where speechOf[match.row] == nil {
            speechOf[match.row] = (match.time, match.text)
            speechRanked.append(match.row)
        }

        var fused: [Int: Double] = [:]
        for (rank, row) in clipRanked.enumerated() { fused[row, default: 0] += 1.0 / Double(60 + rank) }
        for (rank, row) in speechRanked.enumerated() { fused[row, default: 0] += 1.0 / Double(60 + rank) }

        results = fused.sorted { $0.value > $1.value }.prefix(60).map { entry -> VideoHit in
            let row = entry.key
            let frameBest = best[row]
            let speech = speechOf[row]
            let inClip = clipRanked.contains(row)
            let time = inClip ? (frameBest?.time ?? 0) : (speech?.time ?? frameBest?.time ?? 0)
            var moments: [Double] = [time]
            if inClip {
                let strong = (framesOf[row] ?? []).filter { $0.score >= cutoff }.sorted { $0.score > $1.score }
                for frame in strong where moments.allSatisfy({ abs($0 - frame.time) > 3 }) && moments.count < 5 {
                    moments.append(frame.time)
                }
            }
            if let speech, moments.allSatisfy({ abs($0 - speech.time) > 3 }) { moments.append(speech.time) }
            return VideoHit(
                id: store.ids[row],
                score: frameBest?.score ?? 0,
                time: time,
                moments: moments,
                duration: store.durations[row],
                speech: speech?.text
            )
        }

        var info: [String] = []
        if !results.isEmpty { info.append("видео \(results.count)") }
        if !speechRanked.isEmpty { info.append("сказано в видео: \(speechRanked.count)") }
        lastQueryInfo = info.isEmpty ? nil : info.joined(separator: ", ")
    }

    func transcript(for id: String) -> [SpeechChunk] {
        store?.transcript(for: id) ?? []
    }
}
