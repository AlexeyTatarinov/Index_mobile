// SPDX-License-Identifier: GPL-3.0-or-later
//
// Home screen and lock screen widgets that open search or voice search, and a
// Control Center control that can also be put on the Action button.

import AppIntents
import SwiftUI
import WidgetKit

struct StaticEntry: TimelineEntry {
    let date: Date
}

struct StaticProvider: TimelineProvider {
    func placeholder(in context: Context) -> StaticEntry { StaticEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (StaticEntry) -> Void) {
        completion(StaticEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StaticEntry>) -> Void) {
        completion(Timeline(entries: [StaticEntry(date: .now)], policy: .never))
    }
}

private let brand = Color(red: 0.36, green: 0.33, blue: 0.95)

struct SearchWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill")
                    .font(.title2.weight(.semibold))
            }
            .widgetURL(LaunchAction.voice.url)
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.headline)
                VStack(alignment: .leading) {
                    Text("Indexator").font(.headline)
                    Text("Найти фото").font(.caption)
                }
            }
            .widgetURL(LaunchAction.search.url)
        case .systemMedium:
            medium
        default:
            small
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Text("Найти")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            Text("фото и документы по смыслу")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.8))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(LaunchAction.search.url)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.title3.weight(.semibold))
                Text("Indexator")
                    .font(.headline)
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .opacity(0.7)
            }
            .foregroundStyle(.white)
            HStack(spacing: 10) {
                Link(destination: LaunchAction.search.url) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                        Text("Что найти?")
                        Spacer()
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.9))
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Color.white.opacity(0.2), in: Capsule())
                }
                Link(destination: LaunchAction.voice.url) {
                    Image(systemName: "mic.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(brand)
                        .frame(width: 44, height: 44)
                        .background(.white, in: Circle())
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct SearchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "io.github.alexeytatarinov.indexator.search", provider: StaticProvider()) { _ in
            SearchWidgetView()
                .containerBackground(for: .widget) {
                    LinearGradient(
                        colors: [brand, Color(red: 0.18, green: 0.62, blue: 0.86)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
        }
        .configurationDisplayName("Поиск")
        .description("Быстрый поиск по фото и документам, голосом или текстом.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

/// Control Center / lock screen / Action button: start voice search.
struct VoiceSearchControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.github.alexeytatarinov.indexator.voice") {
            ControlWidgetButton(action: StartVoiceSearchIntent()) {
                Label("Голосовой поиск", systemImage: "waveform.badge.magnifyingglass")
            }
        }
        .displayName("Голосовой поиск")
        .description("Открывает Indexator и сразу слушает запрос.")
    }
}

struct SearchControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.github.alexeytatarinov.indexator.searchControl") {
            ControlWidgetButton(action: StartSearchIntent()) {
                Label("Поиск Indexator", systemImage: "sparkle.magnifyingglass")
            }
        }
        .displayName("Поиск Indexator")
        .description("Открывает строку поиска.")
    }
}

@main
struct IndexatorWidgets: WidgetBundle {
    var body: some Widget {
        SearchWidget()
        VoiceSearchControl()
        SearchControl()
    }
}
