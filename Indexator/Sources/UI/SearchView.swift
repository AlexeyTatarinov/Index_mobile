// SPDX-License-Identifier: GPL-3.0-or-later
//
// Main screen: a quiet home with the index status and example queries, the
// search bar with a voice button at the bottom, and results as a grid or cards.

import Photos
import QuickLook
import SwiftUI
import UIKit

struct SearchView: View {
    @EnvironmentObject private var engine: SearchEngine
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var docs = DocumentEngine.shared
    @ObservedObject private var mail = MailEngine.shared
    @ObservedObject private var video = VideoEngine.shared
    @State private var openedVideo: ResultItem?
    @State private var openedMail: ResultItem?
    @State private var previewURL: URL?
    @State private var query = UserDefaults.standard.string(forKey: "autoQuery") ?? ""
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
        let emails = mail.results.map(ResultItem.init(mail:))
        let videos = video.results
            .filter { !settings.isExcluded(photoId: $0.id) && !hidden.contains($0.id) }
            .map(ResultItem.init(video:))
        return documents + emails + Self.mergeByScore(photos, videos)
    }

    /// Photos and videos in one list: a video goes before the first photo it beats.
    private static func mergeByScore(_ photos: [ResultItem], _ videos: [ResultItem]) -> [ResultItem] {
        var merged: [ResultItem] = []
        merged.reserveCapacity(photos.count + videos.count)
        var p = 0, v = 0
        while p < photos.count || v < videos.count {
            if v < videos.count && (p >= photos.count || videos[v].score > photos[p].score || videos[v].textMatch && !photos[p].textMatch) {
                merged.append(videos[v]); v += 1
            } else {
                merged.append(photos[p]); p += 1
            }
        }
        return merged
    }

    private var showingResults: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
            && !submittedQuery.isEmpty
            && (engine.lastQueryInfo != nil || docs.lastQueryInfo != nil || !engine.results.isEmpty || !docs.results.isEmpty || !mail.results.isEmpty || !video.results.isEmpty)
    }

    private var queryInfo: String? {
        let parts = [engine.lastQueryInfo, video.lastQueryInfo, docs.lastQueryInfo.map { "документы: \($0)" },
                     mail.results.isEmpty ? nil : mail.lastQueryInfo.map { "почта: \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func openItem(_ item: ResultItem) {
        switch item.kind {
        case .photo:
            opened = item
        case .video:
            openedVideo = item
        case .document:
            if let hit = docs.results.first(where: { $0.id == item.id }) {
                previewURL = docs.withAccess(to: hit) { $0 }
            }
        case .mail:
            openedMail = item
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
                            onDeleted: { hidden.insert($0.id) },
                            intent: QueryIntent.detect(submittedQuery),
                            docsConnected: !docs.folders.isEmpty,
                            mailConnected: mail.isConnected,
                            onConnectDocs: { router.openSettings(.documents) },
                            onConnectMail: { router.openSettings(.mail) }
                        )
                        .id(submittedQuery)
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
            .sheet(item: $openedVideo) { item in
                VideoPlayerView(item: item, onDeleted: { hidden.insert($0.id) })
            }
            .sheet(item: $openedMail) { item in
                NavigationStack {
                    MailDetailView(messageId: item.id)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Готово") { openedMail = nil }
                            }
                        }
                }
            }
            .onChange(of: engine.results) { _, _ in
                // CI screenshots: `-autoOpenFirst YES` opens the first result once.
                // `-autoOpenKind video` opens the first result of that kind instead.
                let kind = UserDefaults.standard.string(forKey: "autoOpenKind")
                if UserDefaults.standard.bool(forKey: "autoOpenFirst"), !didAutoOpen,
                   let first = items.first(where: { kind == nil || $0.kind.rawValue == kind }) {
                    didAutoOpen = true
                    openItem(first)
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
        if mail.consentGiven { Task { await mail.search(text) } }
        Task { await engine.search(text: text) }
    }
}
