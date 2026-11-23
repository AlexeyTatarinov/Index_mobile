// Indexator — локальный семантический поиск по фото и документам на iPhone.
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

@main
struct IndexatorApp: App {
    @StateObject private var engine = SearchEngine()

    var body: some Scene {
        WindowGroup {
            TabView {
                SearchView()
                    .tabItem { Label("Поиск", systemImage: "magnifyingglass") }
                IndexView()
                    .tabItem { Label("Индекс", systemImage: "square.stack.3d.up") }
                LogView()
                    .tabItem { Label("Журнал", systemImage: "doc.text") }
            }
            .environmentObject(engine)
            .task { await engine.prepare() }
        }
    }
}
