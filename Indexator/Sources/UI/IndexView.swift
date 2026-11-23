// SPDX-License-Identifier: GPL-3.0-or-later

import Photos
import SwiftUI
import UIKit

struct IndexView: View {
    @EnvironmentObject private var engine: SearchEngine
    @State private var limit = 1000

    private let limits = [100, 1000, 5000, 0]

    var body: some View {
        NavigationStack {
            List {
                Section("Фото") {
                    row("Доступ", accessText)
                    row("Фото в медиатеке", "\(engine.libraryCount)")
                    row("В индексе", "\(engine.indexedCount)")
                    if let ms = engine.msPerPhoto {
                        row("Модель на фото", String(format: "%.1f мс", ms))
                    }
                    if let ms = engine.msOCR {
                        row("Текст на фото (OCR)", String(format: "%.0f мс", ms))
                    }
                    if engine.authorization == .limited {
                        Text("Доступ только к выбранным фото. Для полного поиска разреши доступ ко всем фото в Настройках.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Индексация") {
                    Picker("Сколько последних фото", selection: $limit) {
                        ForEach(limits, id: \.self) { value in
                            Text(value == 0 ? "Все" : "\(value)").tag(value)
                        }
                    }
                    Toggle("Распознавать текст на фото", isOn: $engine.ocrEnabled)
                        .disabled(engine.isIndexing)
                    if engine.isIndexing {
                        ProgressView(value: Double(engine.progressDone), total: Double(max(engine.progressTotal, 1))) {
                            Text("\(engine.progressDone) из \(engine.progressTotal)")
                        }
                        Text("Если свернуть приложение, индексация продолжится ночью, когда телефон на зарядке.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Остановить", role: .destructive) { engine.stopIndexing() }
                    } else {
                        Button("Запустить индексацию") { engine.startIndexing(limit: limit) }
                            .disabled(engine.modelState != .ready || !hasAccess)
                    }
                }

                Section("Модель") {
                    row("Состояние", modelText)
                    if let seconds = engine.modelLoadSeconds {
                        row("Загрузка", String(format: "%.1f с", seconds))
                    }
                    if !engine.modelSummary.isEmpty {
                        Text(engine.modelSummary)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section("Устройство") {
                    row("Система", "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                    row("Версия приложения", appVersion)
                }

                Section {
                    Button("Удалить индекс", role: .destructive) { engine.resetIndex() }
                        .disabled(engine.isIndexing)
                }
            }
            .navigationTitle("Индекс")
        }
    }

    private var hasAccess: Bool {
        engine.authorization == .authorized || engine.authorization == .limited
    }

    private var accessText: String {
        switch engine.authorization {
        case .authorized: return "ко всем фото"
        case .limited: return "к выбранным"
        case .denied, .restricted: return "запрещён"
        case .notDetermined: return "не запрошен"
        @unknown default: return "неизвестно"
        }
    }

    private var modelText: String {
        switch engine.modelState {
        case .notLoaded: return "не загружена"
        case .loading: return "загружается"
        case .ready: return MobileCLIP.variant
        case .failed(let message): return "ошибка: \(message)"
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

struct LogView: View {
    @ObservedObject private var log = AppLog.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(log.text.isEmpty ? "Пока пусто" : log.text)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .navigationTitle("Журнал")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Копировать") { UIPasteboard.general.string = log.text }
                }
            }
        }
    }
}
