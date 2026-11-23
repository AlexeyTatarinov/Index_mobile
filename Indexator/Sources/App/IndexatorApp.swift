// Indexator — локальный семантический поиск по фото и документам на iPhone.
// SPDX-License-Identifier: GPL-3.0-or-later

import BackgroundTasks
import SwiftUI

@main
struct IndexatorApp: App {
    @ObservedObject private var engine = SearchEngine.shared
    @Environment(\.scenePhase) private var scenePhase
    // Launch arguments like `-uiTab index` land in UserDefaults; used by CI screenshots.
    @State private var tab = UserDefaults.standard.string(forKey: "uiTab") ?? "search"

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
            TabView(selection: $tab) {
                SearchView()
                    .tabItem { Label("Поиск", systemImage: "magnifyingglass") }
                    .tag("search")
                IndexView()
                    .tabItem { Label("Индекс", systemImage: "square.stack.3d.up") }
                    .tag("index")
                LogView()
                    .tabItem { Label("Журнал", systemImage: "doc.text") }
                    .tag("log")
            }
            .environmentObject(engine)
            .task { await engine.prepare() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                SearchEngine.scheduleBackgroundIndexing()
            case .active:
                engine.indexNewPhotos()
            default:
                break
            }
        }
    }
}
