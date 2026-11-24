// SPDX-License-Identifier: GPL-3.0-or-later
//
// Small building blocks shared by the screens: chips, flow layout, formatting.

import SwiftUI

/// Lays children out left to right and wraps to the next line, like tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Rounded pill used for suggestions, recent queries and filters.
struct Chip: View {
    let title: String
    var systemImage: String?
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.footnote.weight(.semibold))
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                Capsule().fill(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Grouped card background used on the home screen.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

enum Format {
    static func date(_ date: Date?) -> String? {
        guard let date else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Сегодня, " + date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "Вчера, " + date.formatted(date: .omitted, time: .shortened)
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        let style = Date.FormatStyle(locale: Locale(identifier: "ru_RU"))
            .day().month(.wide)
        let withYear = sameYear ? style : style.year()
        return date.formatted(withYear) + ", " + date.formatted(date: .omitted, time: .shortened)
    }

    static func relative(_ date: Date?) -> String? {
        guard let date else { return nil }
        if Date().timeIntervalSince(date) < 60 { return "только что" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func coordinates(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.4f, %.4f", latitude, longitude)
    }

    static func count(_ n: Int) -> String {
        n.formatted(.number.locale(Locale(identifier: "ru_RU")))
    }
}
