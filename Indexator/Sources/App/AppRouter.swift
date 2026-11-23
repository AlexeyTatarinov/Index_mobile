// SPDX-License-Identifier: GPL-3.0-or-later
//
// Where the app should go: tab selection plus one-shot requests coming from the
// widget, Control Center, the Action button or Siri (focus the search field,
// start voice input).

import AppIntents
import SwiftUI

@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    enum Tab: String { case search, settings }
    /// Settings screens that other screens can jump to.
    enum SettingsPage: Hashable { case documents, mail }

    @Published var tab: Tab
    /// Navigation stack of the Settings tab.
    @Published var settingsPath: [SettingsPage] = []
    /// Incremented to ask the search screen to focus the field.
    @Published private(set) var focusRequest = 0
    /// Incremented to ask the search screen to start listening.
    @Published private(set) var voiceRequest = 0

    private init() {
        // Launch arguments like `-uiTab settings` land in UserDefaults; used by CI screenshots.
        switch UserDefaults.standard.string(forKey: "uiTab") {
        case "settings", "index", "log": tab = .settings
        default: tab = .search
        }
    }

    func handle(_ action: LaunchAction) {
        tab = .search
        switch action {
        case .search: focusRequest += 1
        case .voice: voiceRequest += 1
        }
    }

    func openSettings(_ page: SettingsPage) {
        settingsPath = [page]
        tab = .settings
    }

    func handle(url: URL) {
        if let action = LaunchAction(url: url) { handle(action) }
    }

    /// An intent run while the app was opening leaves its action in UserDefaults.
    func consumePendingLaunch() {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: LaunchAction.defaultsKey) else { return }
        defaults.removeObject(forKey: LaunchAction.defaultsKey)
        if let action = LaunchAction(rawValue: raw) { handle(action) }
    }
}

/// Siri and Shortcuts phrases; also lets the user put "Голосовой поиск" on the Action button.
struct IndexatorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartVoiceSearchIntent(),
            phrases: ["Голосовой поиск в \(.applicationName)", "Найди в \(.applicationName)"],
            shortTitle: "Голосовой поиск",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StartSearchIntent(),
            phrases: ["Поиск в \(.applicationName)", "Открой \(.applicationName)"],
            shortTitle: "Поиск",
            systemImageName: "magnifyingglass"
        )
    }
}
