// SPDX-License-Identifier: GPL-3.0-or-later
//
// Home screen card for documents. With no folders picked yet it asks once to pick
// iCloud Drive / On My iPhone / Downloads (iOS has no "all storage" permission, a
// folder picked once is remembered). While indexing it shows progress; afterwards
// a one-line count. Hidden by "Не сейчас" until a folder is added from Settings.

import SwiftUI
import UniformTypeIdentifiers

struct DocumentOnboardingCard: View {
    @ObservedObject private var engine = DocumentEngine.shared
    @State private var picking = false
    @AppStorage("docs.onboardingDismissed") private var dismissed = false

    var body: some View {
        Group {
            if engine.userFolders.isEmpty {
                if !dismissed { connectCard }
            } else if engine.isIndexing {
                progressCard
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { urls.forEach { engine.addFolder(url: $0) } }
        }
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Подключи документы")
                        .font(.subheadline.weight(.semibold))
                    Text("Один раз выбери, где лежат файлы, и я буду искать в PDF, Word, сканах и текстах.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Text("В окне «Файлов» открой «iCloud Drive» или «На iPhone» и нажми «Открыть», чтобы взять всё сразу. Можно выбрать несколько мест по очереди, например «Загрузки».")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    picking = true
                } label: {
                    Label("Выбрать папки", systemImage: "folder.badge.plus")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Не сейчас") { dismissed = true }
                    .font(.footnote)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var progressCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.progressTotal > 0
                     ? "Документы: \(engine.progressDone) из \(engine.progressTotal)"
                     : "Ищу документы в папках…")
                    .font(.subheadline.weight(.semibold))
                if !engine.currentFile.isEmpty {
                    Text(engine.currentFile)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
