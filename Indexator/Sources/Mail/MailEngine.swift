// SPDX-License-Identifier: GPL-3.0-or-later
//
// Mail module entry point. Network is used only during an explicit sync with
// Gmail (after the user's consent). Emails are stored on the phone and searched
// offline: words via FTS5 and meaning via the shared multilingual text embedder.

import Foundation

@MainActor
final class MailEngine: ObservableObject {
    static let shared = MailEngine()

    /// Raw value is the number of days; 0 = all mail, -1 = since a chosen date.
    enum SyncPeriod: Int, CaseIterable, Identifiable {
        case week = 7, month = 30, months3 = 90, year1 = 365, all = 0, custom = -1
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .week: return "Неделя"
            case .month: return "Месяц"
            case .months3: return "3 месяца"
            case .year1: return "1 год"
            case .all: return "Вся почта"
            case .custom: return "С выбранной даты"
            }
        }
    }

    // Settings (UserDefaults; tokens are in the Keychain).
    @Published var consentGiven: Bool = UserDefaults.standard.bool(forKey: "mail.consent") {
        didSet { UserDefaults.standard.set(consentGiven, forKey: "mail.consent") }
    }
    @Published var clientId: String = UserDefaults.standard.string(forKey: "mail.clientId") ?? "" {
        didSet { UserDefaults.standard.set(clientId, forKey: "mail.clientId") }
    }
    @Published var period: SyncPeriod = SyncPeriod(rawValue: UserDefaults.standard.object(forKey: "mail.periodDays") as? Int ?? 30) ?? .month {
        didSet { UserDefaults.standard.set(period.rawValue, forKey: "mail.periodDays") }
    }
    @Published var customStart: Date = UserDefaults.standard.object(forKey: "mail.customStart") as? Date
        ?? Calendar.current.date(byAdding: .day, value: -14, to: Date())! {
        didSet { UserDefaults.standard.set(customStart, forKey: "mail.customStart") }
    }
    @Published var skipPromotions: Bool = UserDefaults.standard.object(forKey: "mail.skipPromotions") as? Bool ?? true {
        didSet { UserDefaults.standard.set(skipPromotions, forKey: "mail.skipPromotions") }
    }
    @Published private(set) var account: String? = UserDefaults.standard.string(forKey: "mail.account") {
        didSet { UserDefaults.standard.set(account, forKey: "mail.account") }
    }
    @Published private(set) var lastSync: Date? = UserDefaults.standard.object(forKey: "mail.lastSync") as? Date {
        didSet { UserDefaults.standard.set(lastSync, forKey: "mail.lastSync") }
    }

    // State.
    @Published private(set) var isConnecting = false
    @Published private(set) var isSyncing = false
    @Published private(set) var syncStage = ""
    @Published private(set) var progressDone = 0
    @Published private(set) var progressTotal = 0
    @Published private(set) var storedCount = 0
    @Published private(set) var pendingVectors = 0
    @Published private(set) var embedderStatus = "не проверен"
    @Published private(set) var lastError: String?
    @Published private(set) var results: [MailHit] = []
    @Published private(set) var lastQueryInfo: String?

    private let store: MailStore?
    private let auth = GmailAuth.shared
    private var syncTask: Task<Void, Never>?
    private var embedder: MailTextEmbedding?
    private var embedderChecked = false
    private let log = AppLog.shared

    var isConnected: Bool { account != nil }
    var config: GoogleOAuthConfig? { GoogleOAuthConfig(clientId: clientId) }

    private init() {
        do {
            store = try MailStore()
        } catch {
            store = nil
            AppLog.shared.add("Почтовая база не открылась: \(error.localizedDescription)")
        }
        Task {
            await refreshCounts()
            await runAutomation()
            // Emails downloaded before the text model was available get their vectors now.
            if storedCount > 0 { await indexPending() }
        }
        Task { await auth.configure(GoogleOAuthConfig(clientId: clientId)) }
    }

    // MARK: - Account

    func connect() async {
        guard consentGiven else { lastError = "Сначала подтверди согласие."; return }
        guard let config else { lastError = GmailAuthError.badClientId.errorDescription; return }
        isConnecting = true
        lastError = nil
        defer { isConnecting = false }
        do {
            let request = GmailAuth.makeSignInRequest(config: config)
            let callback = try await WebAuthenticator.shared.authenticate(url: request.url, callbackScheme: config.redirectScheme)
            try await auth.finishSignIn(request, callback: callback)
            let profile = try await GmailClient(auth: auth).profile()
            account = profile.emailAddress
            log.add("Gmail подключён: \(profile.emailAddress), писем в ящике: \(profile.messagesTotal ?? 0)")
        } catch GmailAuthError.cancelled {
            log.add("Вход в Gmail отменён")
        } catch {
            lastError = error.localizedDescription
            log.add("Вход в Gmail не удался: \(error.localizedDescription)")
        }
    }

    /// Revokes access at Google; `deleteMail` also removes everything downloaded.
    func disconnect(deleteMail: Bool) async {
        stopSync()
        await auth.signOut()
        account = nil
        if deleteMail {
            await store?.deleteAll()
            lastSync = nil
            results = []
        }
        await refreshCounts()
        log.add(deleteMail ? "Gmail отключён, письма удалены с телефона" : "Gmail отключён, скачанные письма оставлены")
    }

    func deleteLocalMail() async {
        stopSync()
        await store?.deleteAll()
        lastSync = nil
        results = []
        await refreshCounts()
        log.add("Скачанные письма удалены с телефона")
    }

    // MARK: - Sync

    /// Gmail search query for the chosen period, without spam, trash and (optionally) promotions.
    nonisolated static func gmailQuery(period: SyncPeriod, since: Date? = nil, skipPromotions: Bool) -> String {
        var parts = ["-in:spam", "-in:trash", "-in:chats"]
        switch period {
        case .all:
            break
        case .custom:
            if let since {
                let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: since)
                parts.append(String(format: "after:%04d/%02d/%02d", c.year ?? 2000, c.month ?? 1, c.day ?? 1))
            }
        default:
            parts.append("newer_than:\(period.rawValue)d")
        }
        if skipPromotions { parts += ["-category:promotions", "-category:social"] }
        return parts.joined(separator: " ")
    }

    func startSync() {
        guard !isSyncing, isConnected, let store else { return }
        isSyncing = true
        lastError = nil
        let query = Self.gmailQuery(period: period, since: customStart, skipPromotions: skipPromotions)
        syncTask = Task { [weak self] in
            guard let self else { return }
            await self.runSync(store: store, query: query)
            await self.indexPending()
            self.isSyncing = false
            self.syncStage = ""
        }
    }

    func stopSync() {
        syncTask?.cancel()
    }

    private func runSync(store: MailStore, query: String) async {
        let client = GmailClient(auth: auth)
        let started = Date()
        do {
            syncStage = "Получаю список писем…"
            progressDone = 0; progressTotal = 0
            let ids = try await client.messageIds(query: query, limit: 0) { [weak self] n in
                await MainActor.run { self?.syncStage = "Получаю список писем… \(n)" }
            }
            let todo = await store.missing(from: ids)
            log.add("Почта: по запросу «\(query)» найдено \(ids.count), новых \(todo.count)")
            syncStage = "Скачиваю письма"
            progressTotal = todo.count

            var batch: [MailMessage] = []
            var failures = 0
            var pending = todo.makeIterator()
            let parallel = 8
            try await withThrowingTaskGroup(of: MailMessage?.self) { group in
                for _ in 0..<parallel {
                    if let id = pending.next() { group.addTask { try await Self.fetch(client, id) } }
                }
                while let result = try await group.next() {
                    if let m = result { batch.append(m) } else { failures += 1 }
                    progressDone += 1
                    if batch.count >= 50 {
                        try await store.insert(batch)
                        batch = []
                        storedCount = await store.count
                    }
                    try Task.checkCancellation()
                    if let id = pending.next() { group.addTask { try await Self.fetch(client, id) } }
                }
            }
            try await store.insert(batch)
            lastSync = Date()
            log.add(String(format: "Почта скачана: %d писем за %.0f с, ошибок %d", progressDone - failures, Date().timeIntervalSince(started), failures))
        } catch is CancellationError {
            log.add("Синхронизация почты остановлена")
        } catch {
            lastError = error.localizedDescription
            log.add("Ошибка синхронизации почты: \(error.localizedDescription)")
            if case .notSignedIn? = error as? GmailAuthError { account = nil }
        }
        await refreshCounts()
    }

    /// One email, or nil when it failed to download (a failure does not stop the sync).
    nonisolated private static func fetch(_ client: GmailClient, _ id: String) async throws -> MailMessage? {
        do {
            return MailParser.parse(try await client.message(id: id))
        } catch is CancellationError {
            throw CancellationError()
        } catch GmailAuthError.notSignedIn {
            throw GmailAuthError.notSignedIn
        } catch {
            AppLog.shared.add("Письмо \(id) не скачалось: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Embeddings

    private func loadEmbedder() -> MailTextEmbedding? {
        if embedderChecked { return embedder }
        embedderChecked = true
        MailEmbedderProvider.installDefault()
        guard let make = MailEmbedderProvider.make else {
            embedderStatus = "нет (поиск только по словам)"
            return nil
        }
        do {
            embedder = try make()
            embedderStatus = embedder?.modelName ?? "?"
        } catch {
            embedderStatus = "ошибка: \(error.localizedDescription)"
            log.add("Текстовая модель для почты не загрузилась: \(error.localizedDescription)")
        }
        return embedder
    }

    /// Embeds emails that have no vectors yet. Runs on device, no network.
    func indexPending() async {
        guard let store, let embedder = loadEmbedder() else { return }
        let model = embedder.modelName
        let total = await store.pendingEmbeddingCount(model: model)
        guard total > 0 else { return }
        syncStage = "Индексирую смысл писем"
        progressDone = 0
        progressTotal = total
        let started = Date()
        while !Task.isCancelled {
            let batch = await store.pendingEmbedding(model: model, limit: 32)
            if batch.isEmpty { break }
            let vectors: [String: [[Float]]]
            do {
                vectors = try await Task.detached(priority: .utility) {
                    var out: [String: [[Float]]] = [:]
                    for m in batch {
                        try autoreleasepool {
                            out[m.id] = try embedder.embed(passages: MailParser.passages(for: m))
                        }
                    }
                    return out
                }.value
                try await store.saveVectors(vectors, model: model)
            } catch {
                lastError = error.localizedDescription
                log.add("Ошибка индексации писем: \(error.localizedDescription)")
                break
            }
            progressDone += batch.count
            pendingVectors = max(0, total - progressDone)
        }
        log.add(String(format: "Смысловой индекс почты: %d писем за %.0f с", progressDone, Date().timeIntervalSince(started)))
        await refreshCounts()
    }

    func refreshCounts() async {
        guard let store else { return }
        storedCount = await store.count
        if let embedder = embedderChecked ? embedder : nil {
            pendingVectors = await store.pendingEmbeddingCount(model: embedder.modelName)
        }
    }

    // MARK: - Search

    /// Searches downloaded emails offline. Raw user text: Russian works directly.
    @discardableResult
    func search(_ query: String) async -> [MailHit] {
        guard let store else { return [] }
        let parsed = QueryParser.parse(query)
        let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var vector: [Float]?
        let embedder = text.isEmpty ? nil : loadEmbedder()
        if let embedder {
            vector = try? await Task.detached(priority: .userInitiated) { try embedder.embed(query: text) }.value
        }
        let start = Date()
        let hits = await store.search(words: words, queryVector: vector, model: embedder?.modelName, filter: parsed.dateFilter)
        results = hits
        var info = ["писем: \(hits.count)"]
        if let filter = parsed.dateFilter { info.append("фильтр: \(filter.label)") }
        if vector == nil && !text.isEmpty { info.append("только по словам") }
        info.append(String(format: "%.0f мс", Date().timeIntervalSince(start) * 1000))
        lastQueryInfo = info.joined(separator: " · ")
        return hits
    }

    func message(id: String) async -> MailMessage? {
        await store?.message(id: id)
    }

    /// Links of an email downloaded before links were stored: fetched once from Gmail.
    func fetchMissingLinks(id: String) async -> [MailLink] {
        guard isConnected, let store else { return [] }
        do {
            let parsed = MailParser.parse(try await GmailClient(auth: auth).message(id: id))
            await store.setLinks(parsed.links, for: id)
            return parsed.links
        } catch {
            log.add("Ссылки письма не получены: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - CI / demo

    /// `-mailDemo YES` fills the store with a few sample emails (simulator screenshots),
    /// `-autoMailQuery "..."` runs a search right away.
    func runAutomation() async {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "mailDemo"), let store {
            consentGiven = true
            try? await store.insert(MailDemo.messages)
            await refreshCounts()
            await indexPending()
        }
        if let q = defaults.string(forKey: "autoMailQuery"), !q.isEmpty {
            await search(q)
        }
    }
}
