// SPDX-License-Identifier: GPL-3.0-or-later
//
// Where to search: everywhere, or only in one source. Chosen above the search
// bar and remembered between launches.

import SwiftUI

enum SearchScope: String, CaseIterable, Identifiable {
    case all, media, documents, mail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Везде"
        case .media: return "Фото и видео"
        case .documents: return "Документы"
        case .mail: return "Почта"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .media: return "photo.on.rectangle"
        case .documents: return "doc.text"
        case .mail: return "envelope"
        }
    }

    func includes(_ kind: ResultItem.Kind) -> Bool {
        switch self {
        case .all: return true
        case .media: return kind == .photo || kind == .video
        case .documents: return kind == .document
        case .mail: return kind == .mail
        }
    }
}

/// Row of source chips right above the search field.
struct ScopePicker: View {
    @Binding var scope: SearchScope

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(SearchScope.allCases) { item in
                    Chip(title: item.title, systemImage: item.systemImage, isSelected: scope == item) {
                        scope = item
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

/// The query the results belong to, with a way to edit it.
struct CurrentQueryBar: View {
    let query: String
    let scope: SearchScope
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 8) {
                Image(systemName: scope.systemImage)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(scope == .all ? "Ищу везде" : "Ищу: \(scope.title.lowercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("«\(query)»")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
            }
            .card()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .accessibilityLabel("Изменить запрос \(query)")
    }
}
