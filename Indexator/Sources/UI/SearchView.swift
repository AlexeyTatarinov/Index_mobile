// SPDX-License-Identifier: GPL-3.0-or-later

import Photos
import SwiftUI
import UIKit
import Translation

struct SearchView: View {
    @EnvironmentObject private var engine: SearchEngine
    @State private var query = UserDefaults.standard.string(forKey: "autoQuery") ?? ""
    @State private var pendingQuery = ""
    @State private var pendingParsed = ParsedQuery(text: "", dateFilter: nil)
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var selected: SearchHit?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    status
                    if let info = engine.lastQueryInfo {
                        Text(info)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(engine.results) { hit in
                            Button {
                                selected = hit
                            } label: {
                                PhotoThumbnail(id: hit.id, side: 104)
                                    .overlay(alignment: .topLeading) {
                                        if hit.textMatch {
                                            Image(systemName: "text.viewfinder")
                                                .font(.caption)
                                                .padding(3)
                                                .background(.black.opacity(0.55))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .overlay(alignment: .bottomTrailing) {
                                        Text(String(format: "%.2f", hit.score))
                                            .font(.caption2.monospacedDigit())
                                            .padding(3)
                                            .background(.black.opacity(0.55))
                                            .foregroundStyle(.white)
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Поиск")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Например: собака на пляже летом 2024")
            .onSubmit(of: .search) { submit() }
            .translationTask(translationConfig) { session in
                let original = pendingQuery
                let parsed = pendingParsed
                do {
                    let response = try await session.translate(parsed.text)
                    await engine.search(parsed: parsed, modelText: response.targetText, shownQuery: original)
                } catch {
                    AppLog.shared.add("Перевод не удался (\(error.localizedDescription)), ищу как есть")
                    await engine.search(parsed: parsed, modelText: parsed.text, shownQuery: original)
                }
            }
            .sheet(item: $selected) { hit in
                PhotoDetail(hit: hit)
                    .environmentObject(engine)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch engine.modelState {
        case .ready where engine.indexedCount == 0:
            hint("Индекс пуст. Открой вкладку «Индекс» и запусти индексацию.")
        case .ready:
            EmptyView()
        case .loading, .notLoaded:
            hint("Загружаю модель…")
        case .failed(let message):
            hint("Модель не загрузилась: \(message)")
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding()
    }

    private func submit() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let parsed = QueryParser.parse(text)
        if parsed.text.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil {
            pendingQuery = text
            pendingParsed = parsed
            if translationConfig == nil {
                translationConfig = TranslationSession.Configuration(
                    source: Locale.Language(identifier: "ru"),
                    target: Locale.Language(identifier: "en")
                )
            } else {
                translationConfig?.invalidate()
            }
        } else {
            Task { await engine.search(parsed: parsed, modelText: parsed.text, shownQuery: text) }
        }
    }
}

struct PhotoThumbnail: View {
    let id: String
    let side: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Color.gray.opacity(0.15)
            .aspectRatio(1, contentMode: .fill)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: id) {
                guard let asset = PhotoLibrary.asset(withId: id) else { return }
                image = await PhotoLibrary.image(for: asset, side: side * 2)
            }
    }
}

struct PhotoDetail: View {
    let hit: SearchHit
    @EnvironmentObject private var engine: SearchEngine
    @State private var image: UIImage?
    @State private var info = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                    }
                    if !info.isEmpty {
                        Text(info)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.horizontal)
                    }
                }
            }
            .navigationTitle(String(format: "Сходство %.3f", hit.score))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
                if let image {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("Фото", image: Image(uiImage: image)))
                    }
                }
            }
            .task {
                guard let asset = PhotoLibrary.asset(withId: hit.id) else { return }
                var lines: [String] = []
                if let date = asset.creationDate {
                    lines.append(date.formatted(date: .long, time: .shortened))
                }
                if let c = asset.location?.coordinate {
                    lines.append(String(format: "%.4f, %.4f", c.latitude, c.longitude))
                }
                if let text = engine.recognizedText(for: hit.id), !text.isEmpty {
                    lines.append("Текст на фото:\n" + text)
                }
                info = lines.joined(separator: "\n")
                image = await PhotoLibrary.image(for: asset, side: 1600)
            }
        }
    }
}
