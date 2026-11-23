// SPDX-License-Identifier: GPL-3.0-or-later
//
// Settings: how fresh the index is, what to search, what to skip, indexing
// controls, and developer details (model, device, log).

import Photos
import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var engine: SearchEngine
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var docs = DocumentEngine.shared
    @AppStorage("ui.indexLimit") private var limit = 0
    @State private var confirmReset = false

    private let limits = [100, 1000, 5000, 0]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    IndexHealthCard()
                }

                Section {
                    Toggle(isOn: $engine.ocrEnabled) {
                        Label("Текст на фото", systemImage: "text.viewfinder")
                    }
                    .disabled(engine.isIndexing)
                    Toggle(isOn: $settings.includeScreenshots) {
                        Label("Скриншоты", systemImage: "camera.viewfinder")
                    }
                    NavigationLink {
                        DocumentSettingsView()
                            .navigationTitle("Документы")
                    } label: {
                        LabeledContent {
                            Text(docs.folders.isEmpty ? "нет папок" : "папок: \(docs.folders.count)")
                        } label: {
                            Label("Документы", systemImage: "doc.text")
                        }
                    }
                    NavigationLink {
                        DocumentFormatsView()
                    } label: {
                        LabeledContent {
                            Text(formatsSummary)
                        } label: {
                            Label("Форматы документов", systemImage: "doc.badge.gearshape")
                        }
                    }
                    NavigationLink {
                        MailPlaceholderView()
                    } label: {
                        LabeledContent {
                            Text("не подключена")
                        } label: {
                            Label("Почта", systemImage: "envelope")
                        }
                    }
                } header: {
                    Text("Что искать")
                } footer: {
                    Text("Распознавание текста позволяет найти чеки, документы и скриншоты по словам на них.")
                }

                Section("Исключения") {
                    NavigationLink {
                        AlbumExclusionsView()
                    } label: {
                        LabeledContent {
                            Text(settings.excludedAlbumIds.isEmpty ? "нет" : "\(settings.excludedAlbumIds.count)")
                        } label: {
                            Label("Альбомы", systemImage: "rectangle.stack.badge.minus")
                        }
                    }
                    NavigationLink {
                        FolderExclusionsView()
                    } label: {
                        LabeledContent {
                            Text("\(settings.excludedFolderNames.count)")
                        } label: {
                            Label("Папки", systemImage: "folder.badge.minus")
                        }
                    }
                }

                Section {
                    Picker(selection: $limit) {
                        ForEach(limits, id: \.self) { value in
                            Text(value == 0 ? "Все" : "Последние \(value)").tag(value)
                        }
                    } label: {
                        Label("Сколько фото", systemImage: "number")
                    }
                } header: {
                    Text("Индексация")
                } footer: {
                    Text("Новые фото добавляются сами при открытии приложения. Большая медиатека доиндексируется ночью, когда телефон заряжается.")
                }

                Section("Для разработчика") {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Модель и устройство", systemImage: "cpu")
                    }
                    NavigationLink {
                        LogView()
                    } label: {
                        Label("Журнал", systemImage: "doc.plaintext")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        confirmReset = true
                    } label: {
                        Label("Удалить индекс", systemImage: "trash")
                    }
                    .disabled(engine.isIndexing)
                } footer: {
                    Text("Indexator \(appVersion) · работает без интернета · GPL-3.0")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }
            }
            .navigationTitle("Настройки")
            .confirmationDialog("Удалить индекс?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) { engine.resetIndex() }
            } message: {
                Text("Фото не удаляются. Индекс придётся строить заново.")
            }
        }
    }

    private var formatsSummary: String {
        let on = AppSettings.documentFormats.filter { settings.isFormatEnabled($0.extensions) }.count
        return on == AppSettings.documentFormats.count ? "все форматы" : "\(on) из \(AppSettings.documentFormats.count)"
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// Big freshness indicator with the main indexing button.
struct IndexHealthCard: View {
    @EnvironmentObject private var engine: SearchEngine
    @EnvironmentObject private var settings: AppSettings
    @AppStorage("ui.indexLimit") private var limit = 0

    var body: some View {
        let status = IndexStatus(engine: engine, settings: settings)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Gauge(value: engine.isIndexing
                      ? Double(engine.progressDone) / Double(max(engine.progressTotal, 1))
                      : status.fraction) {
                    EmptyView()
                } currentValueLabel: {
                    Image(systemName: status.systemImage)
                        .foregroundStyle(status.color)
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(status.color)
                .scaleEffect(1.1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(status.title)
                        .font(.headline)
                    Text(status.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 0) {
                stat("В медиатеке", engine.libraryCount)
                stat("В индексе", engine.indexedCount)
                stat("Исключено", settings.excludedPhotoIds.count)
            }

            if engine.isIndexing {
                ProgressView(value: Double(engine.progressDone), total: Double(max(engine.progressTotal, 1)))
                if let ms = engine.msPerPhoto {
                    Text(String(format: "%.0f мс на фото", ms + (engine.msOCR ?? 0)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    engine.stopIndexing()
                } label: {
                    Text("Остановить").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    engine.startIndexing(limit: limit)
                } label: {
                    Text(engine.indexedCount == 0 ? "Проиндексировать" : "Обновить индекс")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(engine.modelState != .ready || !engine.hasPhotoAccess)
                if engine.authorization == .limited {
                    Text("Доступ только к выбранным фото. Для полного поиска разреши доступ ко всем фото.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Открыть настройки iPhone") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.footnote)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Format.count(value))
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DocumentFormatsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        List {
            Section {
                ForEach(AppSettings.documentFormats) { format in
                    Toggle(isOn: Binding(
                        get: { settings.isFormatEnabled(format.extensions) },
                        set: { settings.setFormat(format.extensions, enabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(format.title)
                            Text(format.extensions.map { "." + $0 }.joined(separator: " "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Форматы")
            } footer: {
                Text("Выключенные форматы не индексируются и не попадают в выдачу.")
            }
        }
        .navigationTitle("Документы")
    }
}

struct AlbumExclusionsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var albums: [PHAssetCollection] = []

    var body: some View {
        List {
            Section {
                if albums.isEmpty {
                    Text("Альбомов нет")
                        .foregroundStyle(.secondary)
                }
                ForEach(albums, id: \.localIdentifier) { album in
                    Toggle(isOn: Binding(
                        get: { !settings.excludedAlbumIds.contains(album.localIdentifier) },
                        set: { include in
                            if include {
                                settings.excludedAlbumIds.remove(album.localIdentifier)
                            } else {
                                settings.excludedAlbumIds.insert(album.localIdentifier)
                            }
                        }
                    )) {
                        HStack(spacing: 8) {
                            Text(album.localizedTitle ?? "Без названия")
                            if AppSettings.looksLikeMessenger(album.localizedTitle) {
                                Text("мессенджер")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.18), in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            } header: {
                Text("Искать в альбомах")
            } footer: {
                Text("Фото из выключенных альбомов не показываются в результатах. Альбомы мессенджеров (WhatsApp, Telegram, Viber) выключены по умолчанию.")
            }
        }
        .navigationTitle("Альбомы")
        .task { albums = settings.userAlbums() }
    }
}

struct FolderExclusionsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                ForEach(settings.excludedFolderNames, id: \.self) { name in
                    Label(name, systemImage: "folder")
                }
                .onDelete { settings.excludedFolderNames.remove(atOffsets: $0) }
                HStack {
                    TextField("Имя папки или путь", text: $newName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    Button("Добавить", action: add)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Не индексировать папки")
            } footer: {
                Text("Папки с такими именами пропускаются при индексации документов. По умолчанию это кэши мессенджеров и временные файлы. Смахни влево, чтобы удалить.")
            }
            Section {
                Button("Вернуть по умолчанию") {
                    settings.excludedFolderNames = AppSettings.defaultExcludedFolders
                }
            }
        }
        .navigationTitle("Папки")
        .toolbar { EditButton() }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !settings.excludedFolderNames.contains(name) else { return }
        settings.excludedFolderNames.append(name)
        newName = ""
    }
}

struct MailPlaceholderView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Почта скоро", systemImage: "envelope.badge.shield.half.filled")
        } description: {
            Text("Поиск по письмам появится отдельным модулем. Почта подключается только с твоего явного согласия, письма хранятся на телефоне.")
        }
        .navigationTitle("Почта")
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var engine: SearchEngine

    var body: some View {
        List {
            Section("Фото") {
                LabeledContent("Доступ", value: accessText)
                LabeledContent("Фото в медиатеке", value: Format.count(engine.libraryCount))
                LabeledContent("В индексе", value: Format.count(engine.indexedCount))
                if let ms = engine.msPerPhoto {
                    LabeledContent("Модель на фото", value: String(format: "%.1f мс", ms))
                }
                if let ms = engine.msOCR {
                    LabeledContent("Текст на фото (OCR)", value: String(format: "%.0f мс", ms))
                }
            }
            Section("Модель") {
                LabeledContent("Состояние", value: modelText)
                if let seconds = engine.modelLoadSeconds {
                    LabeledContent("Загрузка", value: String(format: "%.1f с", seconds))
                }
                if !engine.modelSummary.isEmpty {
                    Text(engine.modelSummary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Section("Устройство") {
                LabeledContent("Система", value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
            }
        }
        .navigationTitle("Модель и устройство")
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
}

struct LogView: View {
    @ObservedObject private var log = AppLog.shared

    var body: some View {
        ScrollView {
            Text(log.text.isEmpty ? "Пока пусто" : log.text)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding()
        }
        .navigationTitle("Журнал")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Копировать") { UIPasteboard.general.string = log.text }
            }
        }
    }
}
