// SPDX-License-Identifier: GPL-3.0-or-later
//
// Search results: filter chips, photos as a grid or as cards with metadata,
// documents and emails as cards. Every item has a quick-action menu.

import Photos
import SwiftUI

enum ResultLayout: String {
    case grid, cards
}

struct ResultsView: View {
    let items: [ResultItem]
    let info: String?
    @Binding var layout: ResultLayout
    let onOpen: (ResultItem) -> Void
    let onAddToAlbum: (ResultItem) -> Void
    let onDeleted: (ResultItem) -> Void

    @State private var kindFilter: ResultItem.Kind?
    @State private var onlyText = false
    @State private var showInfo = false

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    private var kinds: [ResultItem.Kind] {
        ResultItem.Kind.allCases.filter { kind in items.contains { $0.kind == kind } }
    }

    private var filtered: [ResultItem] {
        items.filter { item in
            (kindFilter == nil || item.kind == kindFilter) && (!onlyText || item.textMatch)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let info, !info.isEmpty {
                Text(info)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(showInfo ? nil : 1)
                    .padding(.horizontal, 16)
                    .onTapGesture { withAnimation { showInfo.toggle() } }
            }
            filters
            if filtered.isEmpty {
                ContentUnavailableView(
                    "Ничего не нашлось",
                    systemImage: "magnifyingglass",
                    description: Text("Попробуй сказать иначе или убрать фильтр по дате.")
                )
                .padding(.top, 40)
            } else {
                content
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var filters: some View {
        let textCount = items.filter(\.textMatch).count
        if kinds.count > 1 || textCount > 0 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if kinds.count > 1 {
                        Chip(title: "Все \(items.count)", isSelected: kindFilter == nil) { kindFilter = nil }
                        ForEach(kinds, id: \.self) { kind in
                            Chip(
                                title: "\(kind.title) \(items.filter { $0.kind == kind }.count)",
                                systemImage: kind.systemImage,
                                isSelected: kindFilter == kind
                            ) { kindFilter = kindFilter == kind ? nil : kind }
                        }
                    }
                    if textCount > 0 {
                        Chip(title: "С текстом \(textCount)", systemImage: "text.viewfinder", isSelected: onlyText) {
                            onlyText.toggle()
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let photos = filtered.filter { $0.kind == .photo }
        let others = filtered.filter { $0.kind != .photo }

        if !others.isEmpty {
            LazyVStack(spacing: 10) {
                ForEach(others) { item in
                    Button { onOpen(item) } label: { TextResultCard(item: item) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }

        if !photos.isEmpty {
            if layout == .grid {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(photos) { item in
                        Button { onOpen(item) } label: { PhotoGridCell(item: item) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                PhotoMenu(id: item.id, onOpen: { onOpen(item) },
                                          onAddToAlbum: { onAddToAlbum(item) }, onDeleted: { onDeleted(item) })
                            } preview: {
                                PhotoPreview(id: item.id)
                            }
                    }
                }
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(photos) { item in
                        PhotoCard(item: item, onOpen: { onOpen(item) },
                                  onAddToAlbum: { onAddToAlbum(item) }, onDeleted: { onDeleted(item) })
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

struct PhotoThumbnail: View {
    let id: String
    let side: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fill)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: id) {
                guard let asset = PhotoLibrary.asset(withId: id) else { return }
                let loaded = await PhotoLibrary.image(for: asset, side: side * 2)
                withAnimation(.easeOut(duration: 0.15)) { image = loaded }
            }
    }
}

struct PhotoGridCell: View {
    let item: ResultItem

    var body: some View {
        PhotoThumbnail(id: item.id, side: 130)
            .overlay(alignment: .bottomLeading) {
                if item.textMatch {
                    Image(systemName: "text.viewfinder")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                        .padding(4)
                        .accessibilityLabel("Найден текст")
                }
            }
    }
}

/// Larger preview shown when a photo is long-pressed.
struct PhotoPreview: View {
    let id: String
    @State private var image: UIImage?
    @State private var meta: PhotoMeta?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color(.secondarySystemBackground).frame(width: 300, height: 300)
            }
            if let meta {
                VStack(alignment: .leading, spacing: 2) {
                    if let date = Format.date(meta.date) {
                        Text(date).font(.subheadline.weight(.semibold))
                    }
                    Text(meta.kindText).font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
        .frame(width: 320)
        .task {
            meta = PhotoMeta(id: id)
            guard let asset = PhotoLibrary.asset(withId: id) else { return }
            image = await PhotoLibrary.image(for: asset, side: 700)
        }
    }
}

/// A photo with its date, place and found text, plus a menu of actions.
struct PhotoCard: View {
    let item: ResultItem
    let onOpen: () -> Void
    let onAddToAlbum: () -> Void
    let onDeleted: () -> Void
    @EnvironmentObject private var engine: SearchEngine
    @State private var meta: PhotoMeta?
    @State private var text: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onOpen) {
                PhotoThumbnail(id: item.id, side: 92)
                    .frame(width: 92, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(Format.date(meta?.date) ?? "Без даты")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let meta, meta.hasLocation, let lat = meta.latitude, let lon = meta.longitude {
                    Label(item.placeName ?? Format.coordinates(lat, lon), systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let meta {
                    Text(meta.kindText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if item.textMatch, let text, !text.isEmpty {
                    Text("«\(text)»")
                        .font(.caption)
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)

            Menu {
                PhotoMenu(id: item.id, onOpen: onOpen, onAddToAlbum: onAddToAlbum, onDeleted: onDeleted)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task(id: item.id) {
            meta = PhotoMeta(id: item.id)
            if item.textMatch {
                text = engine.recognizedText(for: item.id)?
                    .replacingOccurrences(of: "\n", with: " ")
            }
        }
    }
}

/// Card for documents and emails.
struct TextResultCard: View {
    let item: ResultItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                let meta = [item.sender, Format.date(item.date), item.page.map { "стр. \($0)" }].compactMap { $0 }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let snippet = item.snippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let url = item.fileURL {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 32, height: 32)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    private var icon: String {
        switch item.kind {
        case .mail: return "envelope.fill"
        case .photo: return "photo"
        case .document:
            let type = item.contentType ?? ""
            if type.contains("pdf") { return "doc.richtext.fill" }
            if type.contains("spreadsheet") || type.contains("csv") { return "tablecells.fill" }
            if type.contains("presentation") { return "rectangle.on.rectangle.angled" }
            return "doc.text.fill"
        }
    }
}
