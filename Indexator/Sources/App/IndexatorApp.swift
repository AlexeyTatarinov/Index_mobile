// Indexator — локальный семантический поиск по фото и документам на iPhone.
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

@main
struct IndexatorApp: App {
    @ObservedObject private var engine = SearchEngine.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var router = AppRouter.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _ = DocumentEngine.shared  // starts watching document folders
        BackgroundIndexer.registerTasks()
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
                BackgroundIndexer.shared.appDidEnterBackground()
            case .active:
                router.consumePendingLaunch()
                BackgroundIndexer.shared.appDidBecomeActive()
            default:
                break
            }
        }
    }
}
