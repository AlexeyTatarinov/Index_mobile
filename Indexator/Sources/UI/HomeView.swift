// SPDX-License-Identifier: GPL-3.0-or-later
//
// What the search screen shows before a query: index status, recent queries,
// example queries. Deliberately quiet.

import SwiftUI

/// How fresh the index is, in words and colour. Shared by home and settings.
struct IndexStatus {
    enum Level { case ok, stale, empty, working, problem }

    let level: Level
    let title: String
    let detail: String
    let fraction: Double

    @MainActor
    init(engine: SearchEngine, settings: AppSettings) {
        let total = engine.libraryCount
        let indexed = engine.indexedCount
        fraction = total > 0 ? min(1, Double(indexed) / Double(total)) : (indexed > 0 ? 1 : 0)
        let updated = Format.relative(settings.lastIndexed).map { "обновлён \($0)" }

        if case .failed = engine.modelState {
            level = .problem
            title = "Модель не загрузилась"
            detail = "Подробности в Настройках → Для разработчика"
        } else if !engine.hasPhotoAccess && engine.authorization != .notDetermined {
            level = .problem
            title = "Нет доступа к фото"
            detail = "Разреши доступ в Настройках iPhone"
        } else if engine.isIndexing {
            level = .working
            title = "Индексирую: \(Format.count(engine.progressDone)) из \(Format.count(engine.progressTotal))"
            detail = "Можно искать уже сейчас"
        } else if indexed == 0 {
            level = .empty
            title = "Индекс пуст"
            detail = "Запусти индексацию, это займёт несколько минут"
        } else if total > indexed {
            level = .stale
            title = "\(Format.count(indexed)) фото в индексе"
            detail = ["ещё \(Format.count(total - indexed)) не проиндексировано", updated].compactMap { $0 }.joined(separator: " · ")
        } else {
            level = .ok
            title = "\(Format.count(indexed)) фото в индексе"
            detail = updated.map { "Актуален, \($0)" } ?? "Актуален"
        }
    }

    var color: Color {
        switch level {
        case .ok: return .green
        case .stale: return .orange
        case .empty: return .secondary
        case .working: return .accentColor
        case .problem: return .red
        }
    }

    var systemImage: String {
        switch level {
        case .ok: return "checkmark.circle.fill"
        case .stale: return "clock.badge.exclamationmark"
        case .empty: return "tray"
        case .working: return "arrow.triangle.2.circlepath"
        case .problem: return "exclamationmark.triangle.fill"
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var engine: SearchEngine
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: AppRouter
    let onQuery: (String) -> Void

    static let suggestions = [
        "собака", "закат на море", "горы и озеро", "еда", "документы с текстом",
        "скриншоты переписки", "летом 2024", "в прошлом месяце",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            statusCard
            if !settings.recentQueries.isEmpty {
                section("Недавние", trailing: AnyView(
                    Button("Очистить") { settings.clearRecent() }
                        .font(.footnote)
                )) {
                    FlowLayout {
                        ForEach(settings.recentQueries, id: \.self) { query in
                            Chip(title: query, systemImage: "clock.arrow.circlepath") { onQuery(query) }
                        }
                    }
                }
            }
            section("Попробуй") {
                FlowLayout {
                    ForEach(Self.suggestions, id: \.self) { query in
                        Chip(title: query) { onQuery(query) }
                    }
                }
            }
            Label("Всё ищется на телефоне, без интернета", systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Indexator")
                .font(.system(size: 38, weight: .bold, design: .rounded))
            Text("Найду фото и документы по смыслу")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var statusCard: some View {
        let status = IndexStatus(engine: engine, settings: settings)
        return Button {
            if status.level == .empty, engine.modelState == .ready, engine.hasPhotoAccess {
                engine.startIndexing(limit: 0)
            } else {
                router.tab = .settings
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(status.color.opacity(0.2), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: status.fraction)
                        .stroke(status.color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: status.systemImage)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(status.color)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(status.level == .empty ? "Нажми, чтобы проиндексировать все фото" : status.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .card()
        }
        .buttonStyle(.plain)
    }

    private func section<Content: View>(_ title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                trailing
            }
            content()
        }
    }
}
