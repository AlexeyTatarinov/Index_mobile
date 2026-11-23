// Indexator — локальный семантический поиск по фото и документам на iPhone.
// SPDX-License-Identifier: GPL-3.0-or-later

import BackgroundTasks
import SwiftUI

@main
struct IndexatorApp: App {
    @ObservedObject private var engine = SearchEngine.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var router = AppRouter.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: SearchEngine.backgroundTaskId, using: nil) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            task.expirationHandler = {
                Task { @MainActor in SearchEngine.shared.stopIndexing() }
            }
            Task { @MainActor in
                AppLog.shared.add("Фоновая индексация запущена системой")
                await SearchEngine.shared.runBackgroundIndexing()
                SearchEngine.scheduleBackgroundIndexing()
                task.setTaskCompleted(success: true)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $router.tab) {
                SearchView()
                    .tabItem { Label("Поиск", systemImage: "magnifyingglass") }
                    .tag(AppRouter.Tab.search)
                SettingsView()
                    .tabItem { Label("Настройки", systemImage: "gearshape") }
                    .tag(AppRouter.Tab.settings)
            }
            .environmentObject(engine)
            .environmentObject(settings)
            .environmentObject(router)
            .task {
                await engine.prepare()
                settings.seedDefaultExclusionsIfNeeded()
            }
            .onOpenURL { router.handle(url: $0) }
            .onReceive(NotificationCenter.default.publisher(for: LaunchAction.notification)) { _ in
                router.consumePendingLaunch()
            }
            .onChange(of: engine.isIndexing) { wasIndexing, isIndexing in
                if wasIndexing && !isIndexing { settings.markIndexed() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                SearchEngine.scheduleBackgroundIndexing()
            case .active:
                router.consumePendingLaunch()
                engine.indexNewPhotos()
            default:
                break
            }
        }
    }
}
