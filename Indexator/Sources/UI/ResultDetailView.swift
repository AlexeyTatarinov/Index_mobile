// SPDX-License-Identifier: GPL-3.0-or-later
//
// Full-screen view of a found photo. Swipe left/right through the results;
// metadata and found text below; actions in the bottom bar.

import SwiftUI
import UIKit

struct PhotoPagerView: View {
    let items: [ResultItem]
    @State var current: String
    let onDeleted: (ResultItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var albumFor: ResultItem?

    private var currentItem: ResultItem? { items.first { $0.id == current } }

    var body: some View {
        NavigationStack {
            TabView(selection: $current) {
                ForEach(items) { item in
                    PhotoDetailPage(item: item)
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color(.systemBackground))
            .navigationTitle(position)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") { dismiss() }
                }
                if let item = currentItem {
                    ToolbarItemGroup(placement: .bottomBar) {
                        ShareLink(item: SharedPhoto(id: item.id), preview: SharePreview("Фото")) {
                            Label("Поделиться", systemImage: "square.and.arrow.up")
                        }
                        Spacer()
                        Button {
                            albumFor = item
                        } label: {
                            Label("В альбом", systemImage: "rectangle.stack.badge.plus")
                        }
                        Spacer()
                        Button {
                            PhotoActions.openPhotosApp()
                        } label: {
                            Label("Открыть «Фото»", systemImage: "photo.on.rectangle")
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task {
                                if await PhotoActions.delete(id: item.id) {
                                    onDeleted(item)
                                    if items.count <= 1 { dismiss() }
                                }
                            }
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                }
            }
            .sheet(item: $albumFor) { item in
                AlbumPicker(photoId: item.id)
            }
        }
    }

    private var position: String {
        guard let index = items.firstIndex(where: { $0.id == current }) else { return "" }
        return "\(index + 1) из \(items.count)"
    }
}

struct PhotoDetailPage: View {
    let item: ResultItem
    @EnvironmentObject private var engine: SearchEngine
    @State private var image: UIImage?
    @State private var meta: PhotoMeta?
    @State private var text: String?
    @State private var zoom: CGFloat = 1

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(zoom)
                            .gesture(
                                MagnifyGesture()
                                    .onChanged { zoom = max(1, min(4, $0.magnification)) }
                                    .onEnded { _ in withAnimation(.spring) { zoom = 1 } }
                            )
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 320)
                    }
                }
                .frame(maxWidth: .infinity)
                .zIndex(1)

                VStack(alignment: .leading, spacing: 12) {
                    if let meta {
                        metaRow("calendar", Format.date(meta.date) ?? "Дата неизвестна")
                        if let lat = meta.latitude, let lon = meta.longitude {
                            Button {
                                PhotoActions.openInMaps(latitude: lat, longitude: lon)
                            } label: {
                                HStack {
                                    metaRow("mappin.and.ellipse", item.placeName ?? Format.coordinates(lat, lon))
                                    Spacer()
                                    Text("Карты")
                                        .font(.footnote)
                                    Image(systemName: "arrow.up.right")
                                        .font(.footnote)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        metaRow(meta.isScreenshot ? "camera.viewfinder" : "photo", meta.kindText)
                        if meta.isFavorite {
                            metaRow("heart.fill", "В избранном")
                        }
                    }
                    if item.score > 0 {
                        metaRow("sparkle.magnifyingglass", String(format: "Сходство с запросом %.2f", item.score))
                    }
                    if let text, !text.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label("Текст на фото", systemImage: "text.viewfinder")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Button {
                                    UIPasteboard.general.string = text
                                } label: {
                                    Label("Копировать", systemImage: "doc.on.doc")
                                        .font(.footnote)
                                }
                            }
                            Text(text)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                        .card()
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 24)
        }
        .task(id: item.id) {
            meta = PhotoMeta(id: item.id)
            text = engine.recognizedText(for: item.id)
            guard let asset = PhotoLibrary.asset(withId: item.id) else { return }
            if image == nil {
                image = await PhotoLibrary.image(for: asset, side: 600)
            }
            image = await PhotoLibrary.image(for: asset, side: 2000) ?? image
        }
    }

    private func metaRow(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(.subheadline)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 22)
        }
    }
}
