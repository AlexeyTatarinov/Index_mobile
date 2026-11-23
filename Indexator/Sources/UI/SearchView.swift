// SPDX-License-Identifier: GPL-3.0-or-later
//
// Main screen: a quiet home with the index status and example queries, the
// search bar with a voice button at the bottom, and results as a grid or cards.

import Photos
import QuickLook
import SwiftUI
import UIKit
import Translation

struct SearchView: View {
    @EnvironmentObject private var engine: SearchEngine
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var docs = DocumentEngine.shared
    @State private var previewURL: URL?
    @State private var query = UserDefaults.standard.string(forKey: "autoQuery") ?? ""
    @State private var pendingQuery = ""
    @State private var pendingParsed = ParsedQuery(text: "", dateFilter: nil)
    @State private var translationConfig: TranslationSession.Configuration?
    @StateObject private var speech = SpeechInput()
    @FocusState private var searchFocused: Bool
    @AppStorage("ui.resultLayout") private var layout: ResultLayout = .grid
    @State private var opened: ResultItem?
    @State private var albumFor: ResultItem?
    @State private var hidden: Set<String> = []
    @State private var didAutoOpen = false
    @State private var submittedQuery = UserDefaults.standard.string(forKey: "autoQuery") ?? ""

    /// All results, mapped to the shared card model, minus excluded and deleted photos.
    private var items: [ResultItem] {
        let documents = docs.results.map(ResultItem.init(document:))
        let photos = engine.results
            .filter { !settings.isExcluded(photoId: $0.id) && !hidden.contains($0.id) }
            .map(ResultItem.init(photo:))
        return documents + photos
    }

    private var showingResults: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
            && !submittedQuery.isEmpty
            && (engine.lastQueryInfo != nil || !engine.results.isEmpty || !docs.results.isEmpty)
    }

    private var queryInfo: String? {
        let parts = [engine.lastQueryInfo, docs.lastQueryInfo.map { "документы: \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func openItem(_ item: ResultItem) {
        switch item.kind {
        case .photo:
            opened = item
        case .document:
            if let hit = docs.results.first(where: { $0.id == item.id }) {
                previewURL = docs.withAccess(to: hit) { $0 }
            }
        case .mail:
            break
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    status
                    if let error = speech.error {
                        Label(error, systemImage: "mic.slash")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }
                    if showingResults {
                        ResultsView(
                            items: items,
                            info: queryInfo,
                            layout: $layout,
                            onOpen: openItem,
                            onAddToAlbum: { albumFor = $0 },
                            onDeleted: { hidden.insert($0.id) }
                        )
                    } else {
                        HomeView(onQuery: run(query:))
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    if speech.isRecording {
                        ListeningBanner(transcript: speech.transcript)
                    }
                    SearchBar(
                        text: $query,
                        focus: $searchFocused,
                        isRecording: speech.isRecording,
                        onSubmit: send,
                        onMic: toggleVoice
                    )
                }
                .background(alignment: .bottom) {
                    LinearGradient(
                        colors: [Color(.systemBackground).opacity(0), Color(.systemBackground).opacity(0.9)],
                        startPoint: .top, endPoint: .center
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
                .animation(.snappy, value: speech.isRecording)
            }
            .navigationTitle(showingResults ? submittedQuery : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(showingResults ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        query = ""
                        submittedQuery = ""
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .accessibilityLabel("На главную")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("Вид", selection: $layout) {
                        Image(systemName: "square.grid.3x3").tag(ResultLayout.grid)
                        Image(systemName: "rectangle.grid.1x2").tag(ResultLayout.cards)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 96)
                }
            }
            .onChange(of: speech.transcript) { _, text in
                if speech.isRecording && !text.isEmpty { query = text }
            }
            .onChange(of: query) { _, text in
                if text.isEmpty { submittedQuery = "" }
            }
            .onChange(of: router.focusRequest) { _, _ in searchFocused = true }
            .onChange(of: router.voiceRequest) { _, _ in
                if !speech.isRecording { toggleVoice() }
            }
            .translationTask(translationConfig) { session in
                let original = pendingQuery
                let parsed = pendingParsed
                do {
                    try await session.prepareTranslation()
                    let response = try await session.translate(parsed.text)
                    AppLog.shared.add("Перевод: «\(parsed.text)» → «\(response.targetText)»")
                    await engine.search(parsed: parsed, modelText: response.targetText, shownQuery: original, via: "перевод")
                } catch {
                    AppLog.shared.add("Системный перевод не удался: \(String(describing: error))")
                    await searchWithDictionary(parsed: parsed, original: original)
                }
            }
            .quickLookPreview($previewURL)
            .sheet(item: $opened) { item in
                PhotoPagerView(
                    items: items.filter { $0.kind == item.kind },
                    current: item.id,
                    onDeleted: { hidden.insert($0.id) }
                )
                .environmentObject(engine)
            }
            .sheet(item: $albumFor) { item in
                AlbumPicker(photoId: item.id)
            }
            .onChange(of: engine.results) { _, _ in
                // CI screenshots: `-autoOpenFirst YES` opens the first result once.
                if UserDefaults.standard.bool(forKey: "autoOpenFirst"), !didAutoOpen, let first = items.first {
                    didAutoOpen = true
                    opened = first
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch engine.modelState {
        case .loading, .notLoaded:
            Label("Загружаю модель…", systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        default:
            EmptyView()
        }
    }

    /// Entry point for typed, tapped and spoken queries.
    private func run(query text: String) {
        query = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchFocused = false
        submittedQuery = trimmed
        settings.remember(query: trimmed)
        submit()
    }

    /// Mic: dictation fills the field; the user checks it and presses Send.
    private func toggleVoice() {
        searchFocused = false
        speech.toggle { text in
            query = text
        }
    }

    /// Send button or keyboard Return: stop dictation if needed, then search.
    private func send() {
        if speech.isRecording { speech.stop() }
        run(query: query)
    }

    private func submit() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task { await DocumentEngine.shared.search(text) }
        let parsed = QueryParser.parse(text)
        if parsed.text.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil {
            pendingQuery = text
            pendingParsed = parsed
            Task {
                let status = await LanguageAvailability().status(
                    from: Locale.Language(identifier: "ru"),
                    to: Locale.Language(identifier: "en")
                )
                AppLog.shared.add("Перевод ru→en: \(status == .installed ? "установлен" : status == .supported ? "можно скачать" : "не поддерживается")")
                if status == .unsupported {
                    await searchWithDictionary(parsed: parsed, original: text)
                } else {
                    startTranslation()
                }
            }
        } else {
            Task { await engine.search(parsed: parsed, modelText: parsed.text, shownQuery: text) }
        }
    }

    private func startTranslation() {
        if translationConfig == nil {
            translationConfig = TranslationSession.Configuration(
                source: Locale.Language(identifier: "ru"),
                target: Locale.Language(identifier: "en")
            )
        } else {
            translationConfig?.invalidate()
        }
    }

    /// Built-in word list, used when the system translator is missing or fails.
    private func searchWithDictionary(parsed: ParsedQuery, original: String) async {
        if let english = FallbackDictionary.translate(parsed.text) {
            AppLog.shared.add("Словарь: «\(parsed.text)» → «\(english)»")
            await engine.search(parsed: parsed, modelText: english, shownQuery: original, via: "встроенный словарь")
        } else {
            AppLog.shared.add("Не смог перевести «\(parsed.text)», ищу только по тексту на фото")
            await engine.search(parsed: parsed, modelText: parsed.text, shownQuery: original,
                                via: "не переведено: скачай русский и английский в Настройки → Приложения → Перевод")
        }
    }
}
