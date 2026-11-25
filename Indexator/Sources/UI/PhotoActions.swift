// SPDX-License-Identifier: GPL-3.0-or-later
//
// Quick actions on a found photo: share through the system Share Sheet, add to
// an album, open Photos or Maps, copy, delete. Plus the photo's metadata.

import CoreTransferable
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Date, place and kind of a photo, read from the library.
struct PhotoMeta: Equatable {
    var date: Date?
    var latitude: Double?
    var longitude: Double?
    var pixelWidth = 0
    var pixelHeight = 0
    var isScreenshot = false
    var isFavorite = false
    var isLive = false

    init?(id: String) {
        guard let asset = PhotoLibrary.asset(withId: id) else { return nil }
        date = asset.creationDate
        latitude = asset.location?.coordinate.latitude
        longitude = asset.location?.coordinate.longitude
        pixelWidth = asset.pixelWidth
        pixelHeight = asset.pixelHeight
        isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        isFavorite = asset.isFavorite
        isLive = asset.mediaSubtypes.contains(.photoLive)
    }

    var hasLocation: Bool { latitude != nil && longitude != nil }

    var kindText: String {
        var parts: [String] = []
        if isScreenshot { parts.append("Скриншот") } else if isLive { parts.append("Live Photo") } else { parts.append("Фото") }
        if pixelWidth > 0 {
            let mp = Double(pixelWidth * pixelHeight) / 1_000_000
            parts.append("\(pixelWidth)×\(pixelHeight)")
            parts.append(String(format: "%.1f Мп", mp))
        }
        return parts.joined(separator: " · ")
    }
}

/// A photo as something to share: exported as JPEG at full resolution on demand.
struct SharedPhoto: Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { photo in
            try await photo.jpegData()
        }
        .suggestedFileName("Indexator.jpg")
    }

    func jpegData() async throws -> Data {
        guard let asset = PhotoLibrary.asset(withId: id) else { throw CocoaError(.fileNoSuchFile) }
        let data: Data? = await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .current
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data, let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.92) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return jpeg
    }
}

enum PhotoActions {
    static func openPhotosApp() {
        if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url)
        }
    }

    static func openInMaps(latitude: Double, longitude: Double) {
        if let url = URL(string: "http://maps.apple.com/?ll=\(latitude),\(longitude)&q=%D0%A4%D0%BE%D1%82%D0%BE") {
            UIApplication.shared.open(url)
        }
    }

    static func copy(id: String) async {
        guard let data = try? await SharedPhoto(id: id).jpegData(), let image = UIImage(data: data) else { return }
        await MainActor.run { UIPasteboard.general.image = image }
    }

    /// Shows the system confirmation; true when the photo was deleted.
    static func delete(id: String) async -> Bool {
        guard let asset = PhotoLibrary.asset(withId: id) else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }
            AppLog.shared.add("Фото удалено из медиатеки")
            return true
        } catch {
            AppLog.shared.add("Фото не удалено: \(error.localizedDescription)")
            return false
        }
    }

    static func setFavorite(id: String, _ favorite: Bool) async {
        guard let asset = PhotoLibrary.asset(withId: id) else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).isFavorite = favorite
        }
    }

    static func albums() -> [PHAssetCollection] {
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var albums: [PHAssetCollection] = []
        result.enumerateObjects { collection, _, _ in
            if collection.canPerform(.addContent) { albums.append(collection) }
        }
        return albums.sorted {
            ($0.localizedTitle ?? "").localizedCaseInsensitiveCompare($1.localizedTitle ?? "") == .orderedAscending
        }
    }

    static func add(id: String, to album: PHAssetCollection) async throws {
        guard let asset = PhotoLibrary.asset(withId: id) else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets([asset] as NSArray)
        }
    }

    static func add(id: String, toNewAlbum title: String) async throws {
        guard let asset = PhotoLibrary.asset(withId: id) else { return }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            request.addAssets([asset] as NSArray)
        }
    }
}

/// Context menu for a photo in the results.
/// «Подходит» / «Не подходит» for a result of the current query: the search learns from it.
struct FeedbackMenuItems: View {
    let kind: ResultItem.Kind
    let id: String
    @ObservedObject private var learning = SearchLearning.shared

    var body: some View {
        let state = learning.state(kind: kind, id: id)
        if !learning.currentQuery.isEmpty {
            Button {
                learning.mark(kind: kind, id: id, good: state == 1 ? nil : true)
            } label: {
                Label(state == 1 ? "Подходит ✓" : "Подходит к запросу", systemImage: "hand.thumbsup")
            }
            Button {
                learning.mark(kind: kind, id: id, good: state == -1 ? nil : false)
            } label: {
                Label(state == -1 ? "Не подходит ✓" : "Не подходит к запросу", systemImage: "hand.thumbsdown")
            }
        }
    }
}

struct PhotoMenu: View {
    let id: String
    let onOpen: () -> Void
    let onAddToAlbum: () -> Void
    let onDeleted: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Label("Открыть", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        ShareLink(item: SharedPhoto(id: id), preview: SharePreview("Фото")) {
            Label("Поделиться", systemImage: "square.and.arrow.up")
        }
        Button {
            Task { await PhotoActions.copy(id: id) }
        } label: {
            Label("Скопировать", systemImage: "doc.on.doc")
        }
        Button(action: onAddToAlbum) {
            Label("Добавить в альбом", systemImage: "rectangle.stack.badge.plus")
        }
        Button {
            PhotoActions.openPhotosApp()
        } label: {
            Label("Открыть «Фото»", systemImage: "photo.on.rectangle")
        }
        Divider()
        FeedbackMenuItems(kind: .photo, id: id)
        Divider()
        Button(role: .destructive) {
            Task { if await PhotoActions.delete(id: id) { onDeleted() } }
        } label: {
            Label("Удалить", systemImage: "trash")
        }
    }
}

/// Pick an album (or create one) to put the photo into: the photo library's "move".
struct AlbumPicker: View {
    let photoId: String
    @Environment(\.dismiss) private var dismiss
    @State private var albums: [PHAssetCollection] = []
    @State private var newTitle = ""
    @State private var showNew = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showNew = true
                    } label: {
                        Label("Новый альбом…", systemImage: "plus")
                    }
                }
                Section("Альбомы") {
                    if albums.isEmpty {
                        Text("Нет альбомов, куда можно добавить фото")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(albums, id: \.localIdentifier) { album in
                        Button {
                            Task {
                                do {
                                    try await PhotoActions.add(id: photoId, to: album)
                                    dismiss()
                                } catch {
                                    message = error.localizedDescription
                                }
                            }
                        } label: {
                            HStack {
                                Label(album.localizedTitle ?? "Без названия", systemImage: "rectangle.stack")
                                Spacer()
                                Text("\(album.estimatedAssetCount == NSNotFound ? 0 : album.estimatedAssetCount)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
                if let message {
                    Text(message).foregroundStyle(.red)
                }
            }
            .navigationTitle("В альбом")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
            .alert("Новый альбом", isPresented: $showNew) {
                TextField("Название", text: $newTitle)
                Button("Создать") {
                    let title = newTitle.trimmingCharacters(in: .whitespaces)
                    guard !title.isEmpty else { return }
                    Task {
                        do {
                            try await PhotoActions.add(id: photoId, toNewAlbum: title)
                            dismiss()
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                }
                Button("Отмена", role: .cancel) {}
            }
            .task { albums = PhotoActions.albums() }
        }
        .presentationDetents([.medium, .large])
    }
}
