// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

/// Фаза 0: проверочный экран. Показывает, что сборка из GitHub Actions
/// установилась и запустилась, и выводит данные устройства.
struct ContentView: View {
    private let device = UIDevice.current
    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    private let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Сборка установилась и работает", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                Section("Устройство") {
                    row("Система", "\(device.systemName) \(device.systemVersion)")
                    row("Модель", device.model)
                }
                Section("Приложение") {
                    row("Версия", "\(appVersion) (\(buildNumber))")
                }
            }
            .navigationTitle("Indexator")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

#Preview {
    ContentView()
}
