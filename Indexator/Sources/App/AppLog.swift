// SPDX-License-Identifier: GPL-3.0-or-later
//
// In-app log. Without a Mac there is no debugger, so everything interesting is
// written here and shown on the "Журнал" screen, where it can be copied.
// Lines are also written to a file right away, so after a crash the next launch
// still shows what happened just before it.

import Foundation

final class AppLog: ObservableObject {
    static let shared = AppLog()

    @Published private(set) var lines: [String] = []

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("applog.txt")
    private let fileLock = NSLock()

    private init() {
        if let previous = try? String(contentsOf: fileURL, encoding: .utf8) {
            let old = previous.split(separator: "\n").suffix(200).map(String.init)
            if !old.isEmpty {
                lines = old + ["—— новый запуск ——"]
            }
            try? (old.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    func add(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)"
        persist(line)
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

    private func persist(_ line: String) {
        fileLock.lock()
        defer { fileLock.unlock() }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }

    var text: String { lines.joined(separator: "\n") }
}
