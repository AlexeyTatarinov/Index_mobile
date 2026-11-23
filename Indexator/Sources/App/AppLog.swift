// SPDX-License-Identifier: GPL-3.0-or-later
//
// In-app log. Without a Mac there is no debugger, so everything interesting is
// written here and shown on the "Журнал" screen, where it can be copied.

import Foundation

final class AppLog: ObservableObject {
    static let shared = AppLog()

    @Published private(set) var lines: [String] = []

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func add(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)"
        if Thread.isMainThread {
            append(line)
        } else {
            DispatchQueue.main.async { self.append(line) }
        }
    }

    private func append(_ line: String) {
        lines.append(line)
        if lines.count > 500 {
            lines.removeFirst(lines.count - 500)
        }
    }

    var text: String { lines.joined(separator: "\n") }
}
