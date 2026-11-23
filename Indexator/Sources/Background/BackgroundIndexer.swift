// SPDX-License-Identifier: GPL-3.0-or-later
//
// Keeps the index fresh without the user pressing anything:
// - while the app is open: photo library changes (new and deleted photos) are picked up
//   a few seconds after they happen, document folders are re-checked every 15 minutes;
// - when the app goes to the background, a running pass gets the extra half-minute iOS allows;
// - BGAppRefreshTask: short checks a few times a day (about 20 s each, small batches);
// - BGProcessingTask: the big backfill, at night while the phone is charging.
// Every pass is resumable: finished photos and files are skipped next time.
// Background runs are recorded so the Settings screen can show whether iOS actually runs them
// (with a free Apple ID there is no Xcode to check this any other way).

import BackgroundTasks
import Combine
import Photos
import SwiftUI
import UIKit

@MainActor
final class BackgroundIndexer: ObservableObject {
    static let shared = BackgroundIndexer()

    nonisolated static let processingTaskId = "io.github.alexeytatarinov.indexator.index"
    nonisolated static let refreshTaskId = "io.github.alexeytatarinov.indexator.refresh"

    enum Trigger: String, Codable {
        case processing, refresh, leavingApp, appOpen, libraryChange, timer, manual

        var title: String {
            switch self {
            case .processing: return "ночью на зарядке"
            case .refresh: return "фоновая проверка"
            case .leavingApp: return "после выхода из приложения"
            case .appOpen: return "при открытии"
            case .libraryChange: return "изменилась медиатека"
            case .timer: return "плановая проверка"
            case .manual: return "вручную"
            }
        }

        var isBackground: Bool { self == .processing || self == .refresh }
    }

    struct Run: Codable, Identifiable, Hashable {
        var id: Date { started }
        let started: Date
        var finished: Date?
        let trigger: Trigger
        var summary: String
        var expired = false
    }

    @Published private(set) var isRunning = false
    @Published private(set) var history: [Run] = []
    @Published private(set) var lastPhotoCheck: Date?
    @Published private(set) var lastDocsCheck: Date?
    @Published private(set) var lastScheduled: Date?
    @Published private(set) var scheduleError: String?
    @Published private(set) var refreshStatus: UIBackgroundRefreshStatus = .available
    @Published private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    var lastBackgroundRun: Run? { history.first { $0.trigger.isBackground } }

    private enum Keys {
        static let history = "bg.history"
        static let lastPhotoCheck = "bg.lastPhotoCheck"
        static let lastDocsCheck = "bg.lastDocsCheck"
    }

    private let defaults = UserDefaults.standard
    private let log = AppLog.shared
    private var photoObserver: PhotoChangeObserver?
    private var changeTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var leavingTask: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []

    private init() {
        if let data = defaults.data(forKey: Keys.history),
           let runs = try? JSONDecoder().decode([Run].self, from: data) {
            history = runs
        }
        lastPhotoCheck = defaults.object(forKey: Keys.lastPhotoCheck) as? Date
        lastDocsCheck = defaults.object(forKey: Keys.lastDocsCheck) as? Date
        refreshStatus = UIApplication.shared.backgroundRefreshStatus
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.backgroundRefreshStatusDidChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in BackgroundIndexer.shared.refreshStatus = UIApplication.shared.backgroundRefreshStatus }
        })
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in BackgroundIndexer.shared.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
        })
    }

    // MARK: - Registration (must happen before the app finishes launching)

    nonisolated static func registerTasks() {
        for (id, trigger) in [(processingTaskId, Trigger.processing), (refreshTaskId, Trigger.refresh)] {
            let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
                Task { @MainActor in BackgroundIndexer.shared.handle(task, trigger: trigger) }
            }
            if !ok { AppLog.shared.add("Фоновая задача \(id) не зарегистрирована") }
        }
    }

    /// Asks iOS for the next background runs. Submitting again replaces the earlier request.
    func scheduleAll() {
        var errors: [String] = []

        let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        refresh.earliestBeginDate = Date().addingTimeInterval(30 * 60)
        do { try BGTaskScheduler.shared.submit(refresh) } catch { errors.append("проверка: \(Self.describe(error))") }

        let processing = BGProcessingTaskRequest(identifier: Self.processingTaskId)
        processing.requiresExternalPower = true
        processing.requiresNetworkConnectivity = false
        do { try BGTaskScheduler.shared.submit(processing) } catch { errors.append("ночная: \(Self.describe(error))") }

        lastScheduled = Date()
        let message = errors.isEmpty ? nil : errors.joined(separator: "; ")
        if message != scheduleError, let message { log.add("Фоновые задачи не запланированы: \(message)") }
        scheduleError = message
    }

    private nonisolated static func describe(_ error: Error) -> String {
        if let error = error as? BGTaskScheduler.Error {
            switch error.code {
            case .unavailable: return "фоновое обновление недоступно (выключено, энергосбережение или симулятор)"
            case .tooManyPendingTaskRequests: return "слишком много запросов"
            case .notPermitted: return "не разрешено в Info.plist"
            default: break
            }
        }
        return error.localizedDescription
    }

    // MARK: - Background tasks

    private func handle(_ task: BGTask, trigger: Trigger) {
        scheduleAll()  // re-arm first, in case this run is cut short
        log.add("Фоновый запуск: \(trigger.title)")
        // A refresh task gets about 30 seconds in total; leave room to save and report.
        let deadline: Date? = trigger == .refresh ? Date().addingTimeInterval(22) : nil
        let completion = CompletionOnce(task)
        let work = Task { @MainActor in
            let ok = await self.run(trigger: trigger, deadline: deadline)
            completion.finish(success: ok)
        }
        task.expirationHandler = {
            Task { @MainActor in
                BackgroundIndexer.shared.markLastRunExpired()
                SearchEngine.shared.stopIndexing()
                DocumentEngine.shared.stopIndexing()
                work.cancel()
                // The loops stop after the current item; give them a moment to save it.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                completion.finish(success: false)
            }
        }
    }

    /// One pass over photos and documents. Returns false when nothing could be checked.
    @discardableResult
    func run(trigger: Trigger, deadline: Date? = nil) async -> Bool {
        guard !isRunning else { return true }
        isRunning = true
        defer { isRunning = false }

        let record = trigger.isBackground || trigger == .manual
        var run = Run(started: Date(), trigger: trigger, summary: "…")
        if record { push(run) }

        if trigger == .refresh && lowPowerMode {
            run.summary = "пропущено: режим энергосбережения"
            run.finished = Date()
            if record { update(run) }
            return true
        }

        var parts: [String] = []
        let photos = await SearchEngine.shared.syncPhotos(reason: trigger.title, deadline: deadline)
        parts.append(photos.summary)
        if photos.skipped == nil {
            setPhotoCheck(Date())
            if photos.isComplete { AppSettings.shared.markIndexed() }
        }

        // Opening the app already re-checks folders (DocumentEngine listens for it),
        // and a photo change says nothing about documents.
        let checkDocs = trigger != .appOpen && trigger != .libraryChange
        if checkDocs && !Task.isCancelled && !DocumentEngine.shared.folders.isEmpty {
            if let deadline, Date() >= deadline {
                parts.append("документы: в следующий раз")
            } else if !UIApplication.shared.isProtectedDataAvailable {
                // Files in other apps' folders cannot be read while the phone is locked;
                // reading them now would mark them as broken.
                parts.append("документы: телефон заблокирован, позже")
            } else {
                parts.append(await DocumentEngine.shared.refreshAndWait(deadline: deadline))
                setDocsCheck(Date())
            }
        }

        // Videos are slow to index; only the long overnight task waits for them.
        if trigger.isBackground && deadline == nil && !Task.isCancelled && VideoEngine.shared.enabled {
            VideoEngine.shared.startIndexing(reason: trigger.title)
            await VideoEngine.shared.waitForIndexing()
            parts.append("видео: проверены")
        }

        run.summary = parts.joined(separator: " · ")
        run.finished = Date()
        if record {
            update(run)
            log.add("Автообновление (\(trigger.title)): \(run.summary)")
        }
        return photos.skipped == nil
    }

    // MARK: - App lifecycle

    func appDidBecomeActive() {
        refreshStatus = UIApplication.shared.backgroundRefreshStatus
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        endLeavingTask()
        startObservingPhotos()
        Task { await run(trigger: .appOpen) }
        startTimer()
    }

    func appDidEnterBackground() {
        timerTask?.cancel()
        timerTask = nil
        changeTask?.cancel()
        scheduleAll()
        let engine = SearchEngine.shared, docs = DocumentEngine.shared
        guard engine.isIndexing || docs.isIndexing, leavingTask == .invalid else { return }
        // Let the current pass go on for the half-minute iOS gives; it saves what it did.
        leavingTask = UIApplication.shared.beginBackgroundTask(withName: "indexator.finish") {
            Task { @MainActor in
                SearchEngine.shared.stopIndexing()
                DocumentEngine.shared.stopIndexing()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                BackgroundIndexer.shared.endLeavingTask()
            }
        }
        log.add("Приложение свёрнуто, индексация продолжается, пока iOS позволяет")
        Task { @MainActor in
            while SearchEngine.shared.isIndexing || DocumentEngine.shared.isIndexing {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if self.leavingTask == .invalid { return }
            }
            self.endLeavingTask()
        }
    }

    private func endLeavingTask() {
        guard leavingTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(leavingTask)
        leavingTask = .invalid
    }

    /// Starts listening to the photo library once access is granted.
    func startObservingPhotos() {
        guard photoObserver == nil, SearchEngine.shared.hasPhotoAccess else { return }
        photoObserver = PhotoChangeObserver { [weak self] in
            self?.photosChanged()
        }
    }

    private func photosChanged() {
        if isRunning {
            // A long pass is under way with an older list of photos; ask it to look again when done.
            SearchEngine.shared.indexNewPhotos(reason: Trigger.libraryChange.title)
            return
        }
        // Several changes usually come together (a burst, an import); wait for them to settle.
        changeTask?.cancel()
        changeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { return }
            await self.run(trigger: .libraryChange)
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { continue }
                await self.run(trigger: .timer)
            }
        }
    }

    // MARK: - Bookkeeping

    private func push(_ run: Run) {
        history.insert(run, at: 0)
        if history.count > 30 { history.removeLast(history.count - 30) }
        saveHistory()
    }

    private func update(_ run: Run) {
        if let i = history.firstIndex(where: { $0.started == run.started }) {
            history[i] = run
            saveHistory()
        }
    }

    private func markLastRunExpired() {
        guard var run = history.first, run.finished == nil else { return }
        run.expired = true
        update(run)
        log.add("iOS прервала фоновый запуск, продолжу в следующий раз")
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: Keys.history)
        }
    }

    private func setPhotoCheck(_ date: Date) {
        lastPhotoCheck = date
        defaults.set(date, forKey: Keys.lastPhotoCheck)
    }

    private func setDocsCheck(_ date: Date) {
        lastDocsCheck = date
        defaults.set(date, forKey: Keys.lastDocsCheck)
    }
}

/// Calls `setTaskCompleted` exactly once, whichever of "done" and "expired" comes first.
private final class CompletionOnce: @unchecked Sendable {
    private let task: BGTask
    private let lock = NSLock()
    private var done = false

    init(_ task: BGTask) { self.task = task }

    func finish(success: Bool) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { task.setTaskCompleted(success: success) }
    }
}

/// Tells when photos were added to or removed from the library. Edits and favourites are ignored.
final class PhotoChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private var fetchResult: PHFetchResult<PHAsset>
    private let lock = NSLock()
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        fetchResult = PHAsset.fetchAssets(with: options)
        self.onChange = onChange
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        lock.lock()
        guard let details = changeInstance.changeDetails(for: fetchResult) else {
            lock.unlock()
            return
        }
        fetchResult = details.fetchResultAfterChanges
        let relevant = !details.hasIncrementalChanges
            || !details.insertedObjects.isEmpty
            || !details.removedObjects.isEmpty
        lock.unlock()
        guard relevant else { return }
        let onChange = self.onChange
        Task { @MainActor in onChange() }
    }
}
