// SPDX-License-Identifier: GPL-3.0-or-later
//
// One search result, whatever it came from (photo, document, email), so the
// search screen can show them all with the same cards and actions.
// Engines keep their own hit types; they are mapped here.

import Foundation

struct ResultItem: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Hashable {
        case photo, document, mail

        var title: String {
            switch self {
            case .photo: return "Фото"
            case .document: return "Документы"
            case .mail: return "Почта"
            }
        }

        var systemImage: String {
            switch self {
            case .photo: return "photo.on.rectangle"
            case .document: return "doc.text"
            case .mail: return "envelope"
            }
        }
    }

    /// Engine-specific id: PHAsset.localIdentifier, document chunk id, mail message id.
    let id: String
    let kind: Kind
    var title: String
    var snippet: String?
    var date: Date?
    var latitude: Double?
    var longitude: Double?
    var placeName: String?
    /// Similarity used for ranking, shown only in details.
    var score: Float
    /// Query words were found in the text (OCR on photos, document text, email body).
    var textMatch: Bool
    var fileURL: URL?
    /// UTType identifier, for documents.
    var contentType: String?
    /// Email sender.
    var sender: String?
    /// Page number inside a document, when known.
    var page: Int?

    init(
        id: String, kind: Kind, title: String, snippet: String? = nil, date: Date? = nil,
        latitude: Double? = nil, longitude: Double? = nil, placeName: String? = nil,
        score: Float = 0, textMatch: Bool = false, fileURL: URL? = nil,
        contentType: String? = nil, sender: String? = nil, page: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.snippet = snippet
        self.date = date
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
        self.score = score
        self.textMatch = textMatch
        self.fileURL = fileURL
        self.contentType = contentType
        self.sender = sender
        self.page = page
    }

    var hasLocation: Bool { latitude != nil && longitude != nil }
}

extension ResultItem {
    /// Photo hit from SearchEngine. Date and place are filled lazily from the asset by the card.
    init(photo hit: SearchHit) {
        self.init(id: hit.id, kind: .photo, title: "Фото", score: hit.score, textMatch: hit.textMatch)
    }
}
