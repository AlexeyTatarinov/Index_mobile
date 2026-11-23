// SPDX-License-Identifier: GPL-3.0-or-later
//
// Settings section that shows how fresh the index is and whether iOS runs the
// background checks, with the history of background runs.

import SwiftUI
import UIKit

struct AutoUpdateSection: View {
    @ObservedObject private var background = BackgroundIndexer.shared
    @ObservedObject private var docs = DocumentEngine.shared

    var body: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                VStack(alignment: .leading, spacing: 0) {
                    row("Фото проверены", background.lastPhotoCheck, icon: "photo.on.rectangle")
                    if !docs.folders.isEmpty {
                        Divider().padding(.vertical, 8)
                        row("Документы проверены", background.lastDocsCheck, icon: "doc.text.magnifyingglass")
                    }
                    Divider().padding(.vertical, 8)
                    LabeledContent {
                        Text(lastBackgroundText)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Label("Последний запуск в фоне", systemImage: "moon.zzz")
                    }
                }
            }

            if background.refreshStatus != .available {
                warning("Фоновое обновление выключено",
                        detail: "Без него новые фото попадут в индекс только при открытии приложения. Включи: Настройки iPhone → Основные → Обновление контента.",
                        button: "Открыть настройки iPhone")
            } else if background.lowPowerMode {
                warning("Режим энергосбережения",
                        detail: "Пока он включён, iOS не запускает фоновые проверки.",
                        button: nil)
            } else if let error = background.scheduleError {
                warning("Фоновые задачи не запланированы", detail: error, button: nil)
            }

            NavigationLink {
                BackgroundHistoryView()
            } label: {
                Label("История фоновых запусков", systemImage: "clock.arrow.circlepath")
            }

            Button {
                Task { await background.run(trigger: .manual) }
            } label: {
                HStack {
                    Label("Проверить сейчас", systemImage: "arrow.clockwise")
                    if background.isRunning {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(background.isRunning)
        } header: {
            Text("Автообновление")
        } footer: {
            Text("Новые и удалённые фото подхватываются сами через несколько секунд, пока приложение открыто. В фоне iOS сама решает, когда запускать: короткие проверки несколько раз в день, большая доиндексация ночью на зарядке. Если смахнуть приложение из списка открытых, фоновые запуски прекращаются до следующего открытия.")
        }
    }

    private var lastBackgroundText: String {
        guard let run = background.lastBackgroundRun else { return "ещё не было" }
        return Format.relative(run.started) ?? ""
    }

    private func row(_ title: String, _ date: Date?, icon: String) -> some View {
        LabeledContent {
            Text(Format.relative(date) ?? "ещё не было")
        } label: {
            Label(title, systemImage: icon)
        }
    }

    private func warning(_ title: String, detail: String, button: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let button {
                Button(button) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.footnote)
            }
        }
        .padding(.vertical, 2)
    }
}

struct BackgroundHistoryView: View {
    @ObservedObject private var background = BackgroundIndexer.shared

    var body: some View {
        List {
            if background.history.isEmpty {
                Text("Пока пусто. iOS запускает фоновые задачи не сразу: обычно в первые сутки, ночью на зарядке.")
                    .foregroundStyle(.secondary)
            }
            ForEach(background.history) { run in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(run.trigger.title.prefix(1).uppercased() + run.trigger.title.dropFirst())
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(Format.date(run.started) ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(run.summary)
                        .font(.footnote)
                    if let duration = duration(run) {
                        Text(duration)
                            .font(.caption)
                            .foregroundStyle(run.expired ? .orange : .secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            Section {
                if let scheduled = background.lastScheduled {
                    LabeledContent("Запрошено у iOS", value: Format.date(scheduled) ?? "")
                }
                LabeledContent("Фоновое обновление", value: refreshText)
                LabeledContent("Энергосбережение", value: background.lowPowerMode ? "включено" : "выключено")
            } footer: {
                Text("Короткая проверка просится не чаще раза в 30 минут, ночная — только на зарядке. Когда именно запускать, решает iOS по тому, как часто ты открываешь приложение.")
            }
        }
        .navigationTitle("Фоновые запуски")
    }

    private var refreshText: String {
        switch background.refreshStatus {
        case .available: return "включено"
        case .denied: return "выключено"
        case .restricted: return "ограничено"
        @unknown default: return "неизвестно"
        }
    }

    private func duration(_ run: BackgroundIndexer.Run) -> String? {
        if run.expired { return "прервано iOS, продолжится в следующий раз" }
        guard let finished = run.finished else { return "не завершён" }
        return String(format: "%.0f с", finished.timeIntervalSince(run.started))
    }
}
