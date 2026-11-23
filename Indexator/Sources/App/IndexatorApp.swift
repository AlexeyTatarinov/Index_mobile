// Indexator — локальный семантический поиск по фото и документам на iPhone.
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

@main
struct IndexatorApp: App {
    @StateObject private var engine = SearchEngine()
    // Launch arguments like `-uiTab index` land in UserDefaults; used by CI screenshots.
    @State private var tab = UserDefaults.standard.string(forKey: "uiTab") ?? "search"

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
    }
}
