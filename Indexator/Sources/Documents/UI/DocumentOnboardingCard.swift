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
    @State private var pickerStart: PickerStart?
    @AppStorage("docs.onboardingDismissed") private var dismissed = false

    var body: some View {
        Group {
            if engine.userFolders.isEmpty {
                if !dismissed { connectCard }
            } else if engine.isIndexing {
                progressCard
            }
        }
        .sheet(item: $pickerStart) { start in
            FolderPicker(start: start) { urls in urls.forEach { engine.addFolder(url: $0) } }
                .ignoresSafeArea()
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
            Text("Откроется iCloud Drive: нажми «Открыть», чтобы взять его целиком со всеми папками, включая «Загрузки». Папку на iPhone можно добавить отдельно.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    pickerStart = .iCloudDrive
                } label: {
                    Label("iCloud Drive", systemImage: "icloud")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                Button {
                    pickerStart = .onMyPhone
                } label: {
                    Label("На iPhone", systemImage: "iphone")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
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
