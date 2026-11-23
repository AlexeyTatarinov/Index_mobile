// SPDX-License-Identifier: GPL-3.0-or-later
//
// Folders granted through Files, indexing progress and document index settings.

import SwiftUI
import UniformTypeIdentifiers

struct DocumentSettingsView: View {
    @ObservedObject private var engine = DocumentEngine.shared
    @State private var picking = false
    @State private var pickTypes: [UTType] = [.folder]

    var body: some View {
        List {
            Section {
                ForEach(engine.folders) { folder in
                    let s = engine.folderStats(folder)
                    VStack(alignment: .leading, spacing: 2) {
                        Label(folder.name, systemImage: folder.isDirectory ? "folder" : "doc")
                        Text("Файлов: \(s.documents), фрагментов: \(s.chunks)\(s.withOCR > 0 ? ", с OCR: \(s.withOCR)" : "")\(s.failed > 0 ? ", ошибок: \(s.failed)" : "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Убрать", role: .destructive) { engine.removeFolder(folder) }
                    }
                }
                Button {
                    pickTypes = [.folder]
                    picking = true
                } label: {
                    Label("Добавить папку", systemImage: "folder.badge.plus")
                }
                Button {
                    pickTypes = Self.fileTypes
                    picking = true
                } label: {
                    Label("Добавить файлы", systemImage: "doc.badge.plus")
                }
            } header: {
                Text("Папки")
            } footer: {
                Text("Выбери папку в «Файлах» (на iPhone, в iCloud Drive или на флешке). Приложение запомнит доступ и будет само подхватывать новые и изменённые файлы. Смахни влево, чтобы убрать папку из индекса.")
            }

            Section("Индексация") {
                row("Файлов в индексе", "\(engine.stats.documents)")
                row("Фрагментов текста", "\(engine.stats.chunks)")
                row("Модель текста", modelText)
                if let ms = engine.msPerChunk {
                    row("Модель на фрагмент", String(format: "%.0f мс", ms))
                }
                Toggle("Распознавать сканы и картинки (OCR)", isOn: $engine.ocrEnabled)
                    .disabled(engine.isIndexing)
                if engine.isIndexing {
                    ProgressView(value: Double(engine.progressDone), total: Double(max(engine.progressTotal, 1))) {
                        Text("\(engine.progressDone) из \(engine.progressTotal)")
                    }
                    if !engine.currentFile.isEmpty {
                        Text(engine.currentFile)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button("Остановить", role: .destructive) { engine.stopIndexing() }
                } else {
                    Button("Проверить папки сейчас") { engine.startIndexing() }
                        .disabled(engine.folders.isEmpty)
                }
                if let error = engine.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button("Удалить индекс документов", role: .destructive) { engine.resetIndex() }
                    .disabled(engine.isIndexing)
            } footer: {
                Text("Поддерживаются PDF (и сканы), DOCX, RTF, TXT, Markdown, CSV, HTML и картинки с текстом. Всё обрабатывается на телефоне.")
            }
        }
        .navigationTitle("Документы")
        // One importer: SwiftUI ignores all but the last .fileImporter on a view.
        .fileImporter(isPresented: $picking, allowedContentTypes: pickTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { urls.forEach { engine.addFolder(url: $0) } }
        }
        .task { await engine.loadEmbedderIfNeeded() }
    }

    static let fileTypes: [UTType] = {
        var types: [UTType] = [.pdf, .plainText, .rtf, .html, .commaSeparatedText, .json, .xml, .image]
        if let docx = UTType(filenameExtension: "docx") { types.append(docx) }
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        return types
    }()

    private var modelText: String {
        switch engine.embedderState {
        case .notLoaded: return "не загружена"
        case .loading: return "загружается…"
        case .ready: return "multilingual-e5-small"
        case .unavailable: return "нет, поиск по словам"
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}

/// Standalone tab wrapper until the settings screen links DocumentSettingsView.
struct DocumentsTab: View {
    var body: some View {
        NavigationStack { DocumentSettingsView() }
    }
}
