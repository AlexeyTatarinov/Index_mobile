// SPDX-License-Identifier: GPL-3.0-or-later
//
// User choices from the Settings screen: what to search, what to skip, and
// small UI state (recent queries, when the index was last brought up to date).
// Stored in UserDefaults so indexers can read the same keys.

import Foundation
import Photos

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum Keys {
        static let includeScreenshots = "photos.includeScreenshots"
        static let excludedAlbums = "photos.excludedAlbumIds"
        static let didSeedExclusions = "photos.didSeedExclusions"
        static let docsExcludedExtensions = "docs.excludedExtensions"   // read by the documents indexer
        static let docsExcludedFolders = "docs.excludedFolderNames"
        static let recentQueries = "ui.recentQueries"
        static let lastIndexed = "ui.lastIndexedAt"
    }

    /// Albums whose names look like messenger dumps; excluded by default (spec: skip messenger caches).
    static let messengerAlbumNames = ["whatsapp", "telegram", "viber", "signal", "vk", "вконтакте", "messenger", "wechat", "line", "imo"]
    /// Folder names skipped in document folders by default.
    static let defaultExcludedFolders = ["Caches", "Cache", "tmp", ".Trash", "node_modules"]

    /// Document formats the user can switch off. Extensions in lowercase.
    struct DocumentFormat: Identifiable {
        let title: String
        let extensions: [String]
        var id: String { title }
    }

    static let documentFormats: [DocumentFormat] = [
        DocumentFormat(title: "PDF", extensions: ["pdf"]),
        DocumentFormat(title: "Word", extensions: ["doc", "docx", "rtf"]),
        DocumentFormat(title: "Текст и Markdown", extensions: ["txt", "md", "markdown"]),
        DocumentFormat(title: "Таблицы", extensions: ["xls", "xlsx", "csv", "numbers"]),
        DocumentFormat(title: "Презентации", extensions: ["ppt", "pptx", "key"]),
        DocumentFormat(title: "Pages", extensions: ["pages"]),
    ]

    private let defaults = UserDefaults.standard

    @Published var includeScreenshots: Bool {
        didSet { defaults.set(includeScreenshots, forKey: Keys.includeScreenshots); refreshExcludedPhotos() }
    }
    @Published var excludedAlbumIds: Set<String> {
        didSet { defaults.set(Array(excludedAlbumIds), forKey: Keys.excludedAlbums); refreshExcludedPhotos() }
    }
    @Published var excludedExtensions: Set<String> {
        didSet { defaults.set(Array(excludedExtensions).sorted(), forKey: Keys.docsExcludedExtensions) }
    }
    @Published var excludedFolderNames: [String] {
        didSet { defaults.set(excludedFolderNames, forKey: Keys.docsExcludedFolders) }
    }
    @Published private(set) var recentQueries: [String]
    @Published private(set) var lastIndexed: Date?

    /// Photo ids hidden from results because of the exclusions above.
    @Published private(set) var excludedPhotoIds: Set<String> = []

    private init() {
        includeScreenshots = defaults.object(forKey: Keys.includeScreenshots) as? Bool ?? true
        excludedAlbumIds = Set(defaults.stringArray(forKey: Keys.excludedAlbums) ?? [])
        excludedExtensions = Set(defaults.stringArray(forKey: Keys.docsExcludedExtensions) ?? [])
        excludedFolderNames = defaults.stringArray(forKey: Keys.docsExcludedFolders) ?? Self.defaultExcludedFolders
        recentQueries = defaults.stringArray(forKey: Keys.recentQueries) ?? []
        lastIndexed = defaults.object(forKey: Keys.lastIndexed) as? Date
    }

    // MARK: Recent queries

    func remember(query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var list = recentQueries.filter { $0.caseInsensitiveCompare(text) != .orderedSame }
        list.insert(text, at: 0)
        recentQueries = Array(list.prefix(12))
        defaults.set(recentQueries, forKey: Keys.recentQueries)
    }

    func clearRecent() {
        recentQueries = []
        defaults.removeObject(forKey: Keys.recentQueries)
    }

    func markIndexed(_ date: Date = Date()) {
        lastIndexed = date
        defaults.set(date, forKey: Keys.lastIndexed)
    }

    // MARK: Document formats

    func isFormatEnabled(_ extensions: [String]) -> Bool {
        excludedExtensions.isDisjoint(with: extensions)
    }

    func setFormat(_ extensions: [String], enabled: Bool) {
        if enabled {
            excludedExtensions.subtract(extensions)
        } else {
            excludedExtensions.formUnion(extensions)
        }
    }

    // MARK: Photo exclusions

    /// User albums, for the exclusion list.
    func userAlbums() -> [PHAssetCollection] {
        guard PhotoLibrary.status == .authorized || PhotoLibrary.status == .limited else { return [] }
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var albums: [PHAssetCollection] = []
        result.enumerateObjects { collection, _, _ in albums.append(collection) }
        return albums.sorted {
            ($0.localizedTitle ?? "").localizedCaseInsensitiveCompare($1.localizedTitle ?? "") == .orderedAscending
        }
    }

    static func looksLikeMessenger(_ title: String?) -> Bool {
        guard let title = title?.lowercased() else { return false }
        return messengerAlbumNames.contains { title.contains($0) }
    }

    /// First run with photo access: exclude messenger albums by default.
    func seedDefaultExclusionsIfNeeded() {
        guard !defaults.bool(forKey: Keys.didSeedExclusions),
              PhotoLibrary.status == .authorized || PhotoLibrary.status == .limited else {
            refreshExcludedPhotos()
            return
        }
        defaults.set(true, forKey: Keys.didSeedExclusions)
        let messenger = userAlbums().filter { Self.looksLikeMessenger($0.localizedTitle) }.map(\.localIdentifier)
        if !messenger.isEmpty {
            excludedAlbumIds.formUnion(messenger)
            AppLog.shared.add("Исключены альбомы мессенджеров: \(messenger.count)")
        } else {
            refreshExcludedPhotos()
        }
    }

    /// Rebuilds the set of photo ids in excluded albums. Screenshots are checked per asset.
    func refreshExcludedPhotos() {
        let albumIds = Array(excludedAlbumIds)
        let screenshots = !includeScreenshots
        Task.detached(priority: .utility) {
            var ids = Set<String>()
            if !albumIds.isEmpty {
                let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: albumIds, options: nil)
                collections.enumerateObjects { collection, _, _ in
                    PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                        ids.insert(asset.localIdentifier)
                    }
                }
            }
            if screenshots {
                let options = PHFetchOptions()
                options.predicate = NSPredicate(
                    format: "(mediaSubtypes & %d) != 0",
                    PHAssetMediaSubtype.photoScreenshot.rawValue
                )
                PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in
                    ids.insert(asset.localIdentifier)
                }
            }
            let result = ids
            await MainActor.run { AppSettings.shared.excludedPhotoIds = result }
        }
    }

    /// For indexers: should this photo be skipped?
    func isExcluded(photoId: String) -> Bool {
        excludedPhotoIds.contains(photoId)
    }
}
