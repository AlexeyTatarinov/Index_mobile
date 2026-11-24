// SPDX-License-Identifier: GPL-3.0-or-later
//
// Intents that open the app straight into search or voice search. Compiled into
// both the app and the widget extension: Control Center / Action button controls
// live in the extension, but since they open the app, `perform()` runs in the app.

import AppIntents
import Foundation

enum LaunchAction: String {
    case search
    case voice

    static let defaultsKey = "ui.pendingLaunch"
    static let urlScheme = "indexator"

    static let notification = Notification.Name("indexator.launchAction")

    var url: URL { URL(string: "\(Self.urlScheme)://\(rawValue)")! }

    /// Leaves the action for the app: in UserDefaults for a cold start, and as a
    /// notification when the app is already running.
    @MainActor
    func post() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: Self.notification, object: nil)
    }

    init?(url: URL) {
        guard url.scheme == Self.urlScheme, let action = LaunchAction(rawValue: url.host ?? "") else { return nil }
        self = action
    }
}

struct StartSearchIntent: AppIntent {
    static let title: LocalizedStringResource = "Поиск в Indexator"
    static let description = IntentDescription("Открывает Indexator со строкой поиска.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchAction.search.post()
        return .result()
    }
}

struct StartVoiceSearchIntent: AppIntent {
    static let title: LocalizedStringResource = "Голосовой поиск в Indexator"
    static let description = IntentDescription("Открывает Indexator и сразу слушает запрос.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchAction.voice.post()
        return .result()
    }
}
