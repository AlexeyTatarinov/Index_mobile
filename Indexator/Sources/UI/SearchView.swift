// SPDX-License-Identifier: GPL-3.0-or-later

import Photos
import SwiftUI
import UIKit
import Translation

struct SearchView: View {
    @EnvironmentObject private var engine: SearchEngine
    @State private var query = ""
    @State private var pendingQuery = ""
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
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Например: собака на пляже")
            .onSubmit(of: .search) { submit() }
            .translationTask(translationConfig) { session in
                let original = pendingQuery
                do {
                    let response = try await session.translate(original)
                    await engine.search(modelQuery: response.targetText, shownQuery: original)
                } catch {
                    AppLog.shared.add("Перевод не удался (\(error.localizedDescription)), ищу как есть")
                    await engine.search(modelQuery: original, shownQuery: original)
                }
            }
            .sheet(item: $selected) { hit in
                PhotoDetail(hit: hit)
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
        if text.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil {
            pendingQuery = text
            if translationConfig == nil {
                translationConfig = TranslationSession.Configuration(
                    source: Locale.Language(identifier: "ru"),
                    target: Locale.Language(identifier: "en")
                )
            } else {
                translationConfig?.invalidate()
            }
        } else {
            Task { await engine.search(modelQuery: text, shownQuery: text) }
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
    @State private var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                image = await PhotoLibrary.image(for: asset, side: 1600)
            }
        }
    }
}
