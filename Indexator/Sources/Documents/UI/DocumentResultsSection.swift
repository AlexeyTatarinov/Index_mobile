// SPDX-License-Identifier: GPL-3.0-or-later
//
// Document results shown above the photo grid: one card per file with the best
// matching passage. Tapping opens a Quick Look preview; the menu shares the file.

import QuickLook
import SwiftUI

struct DocumentResultsSection: View {
    @ObservedObject private var engine = DocumentEngine.shared
    @State private var previewURL: URL?
    @State private var showAll = false

    var body: some View {
        if !engine.results.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Документы", systemImage: "doc.text.magnifyingglass")
                        .font(.headline)
                    Spacer()
                    if engine.results.count > 3 {
                        Button(showAll ? "Свернуть" : "Все \(engine.results.count)") { showAll.toggle() }
                            .font(.callout)
                    }
                }
                if let info = engine.lastQueryInfo {
                    Text(info)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(showAll ? engine.results : Array(engine.results.prefix(3))) { hit in
                    DocumentCard(hit: hit) { previewURL = $0 }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .quickLookPreview($previewURL)
            .onChange(of: engine.results) { _, _ in showAll = false }
        }
    }
}

struct DocumentCard: View {
    let hit: DocumentHit
    let open: (URL) -> Void

    var body: some View {
        Button {
            if let url = DocumentEngine.shared.withAccess(to: hit, { $0 }) { open(url) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: icon)
                        .foregroundStyle(Color.accentColor)
                    Text(hit.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if hit.textMatch {
                        Image(systemName: "textformat")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if hit.score > 0 {
                        Text(String(format: "%.2f", hit.score))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(hit.snippet)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                Text(details)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let url = hit.fileURL {
                ShareLink(item: url) { Label("Поделиться", systemImage: "square.and.arrow.up") }
            }
            Button {
                UIPasteboard.general.string = hit.snippet
            } label: {
                Label("Скопировать фрагмент", systemImage: "doc.on.doc")
            }
        }
    }

    private var details: String {
        var parts: [String] = []
        if let page = hit.page { parts.append("стр. \(page)") }
        let folderPath = (hit.relativePath as NSString).deletingLastPathComponent
        parts.append(folderPath.isEmpty ? hit.folderName : "\(hit.folderName)/\(folderPath)")
        if let date = hit.date { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }

    private var icon: String {
        switch (hit.title as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "docx", "rtf": return "doc.text"
        case "jpg", "jpeg", "png", "heic", "tiff", "webp": return "photo"
        case "csv": return "tablecells"
        default: return "doc.plaintext"
        }
    }
}
