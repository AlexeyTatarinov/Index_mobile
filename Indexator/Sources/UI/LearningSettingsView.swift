// SPDX-License-Identifier: GPL-3.0-or-later
//
// Settings → Обучение поиска: what the app has learned from the user (marked
// results, voice fixes, own synonyms), the dictation language, and reset buttons.

import SwiftUI

struct LearningSettingsView: View {
    @ObservedObject private var learning = SearchLearning.shared
    @AppStorage("voice.language") private var voiceLanguage = "ru-RU"
    @AppStorage(VoiceFixes.enabledKey) private var voiceFixesOn = true
    @State private var synonymLines: [String] = UserDefaults.standard.stringArray(forKey: QuerySynonyms.userGroupsKey) ?? []
    @State private var newSynonyms = ""
    @State private var voiceFixes: [String: String] = VoiceFixes.learned
    @State private var newHeard = ""
    @State private var newMeant = ""

    var body: some View {
        List {
            Section {
                LabeledContent("Отмечено результатов", value: "\(learning.count)")
                Button("Забыть отметки", role: .destructive) { learning.reset() }
                    .disabled(learning.count == 0)
            } header: {
                Text("Подходит / не подходит")
            } footer: {
                Text("Удержите фото, видео, документ или письмо в результатах и выберите «Подходит» или «Не подходит». Для того же запроса (в любой форме слов) отмеченное «подходит» будет первым, «не подходит» — скрыто.")
            }

            Section {
                ForEach(synonymLines, id: \.self) { line in
                    Text(line)
                }
                .onDelete { offsets in
                    synonymLines.remove(atOffsets: offsets)
                    UserDefaults.standard.set(synonymLines, forKey: QuerySynonyms.userGroupsKey)
                }
                HStack {
                    TextField("например: тачка, машина, car", text: $newSynonyms)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Добавить") {
                        QuerySynonyms.addUserGroup(newSynonyms)
                        synonymLines = UserDefaults.standard.stringArray(forKey: QuerySynonyms.userGroupsKey) ?? []
                        newSynonyms = ""
                    }
                    .disabled(QuerySynonyms.parse(newSynonyms).count < 2)
                }
            } header: {
                Text("Мои синонимы")
            } footer: {
                Text("Слова через запятую означают одно и то же в документах, почте и тексте на фото. Уже встроены: резюме = CV = resume, договор = contract, счёт = invoice, билет = ticket и другие.")
            }

            Section {
                Picker("Язык диктовки", selection: $voiceLanguage) {
                    Text("Русский").tag("ru-RU")
                    Text("English").tag("en-US")
                }
                Toggle("Исправлять слова диктовки", isOn: $voiceFixesOn)
                ForEach(voiceFixes.keys.sorted(), id: \.self) { heard in
                    LabeledContent(heard, value: voiceFixes[heard] ?? "")
                }
                .onDelete { offsets in
                    let keys = voiceFixes.keys.sorted()
                    for i in offsets { voiceFixes[keys[i]] = nil }
                    VoiceFixes.setLearned(voiceFixes)
                }
                HStack {
                    TextField("слышит", text: $newHeard)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("надо", text: $newMeant)
                    Button("Добавить") {
                        voiceFixes[newHeard.lowercased().trimmingCharacters(in: .whitespaces)] = newMeant.trimmingCharacters(in: .whitespaces)
                        VoiceFixes.setLearned(voiceFixes)
                        newHeard = ""
                        newMeant = ""
                    }
                    .disabled(newHeard.trimmingCharacters(in: .whitespaces).isEmpty || newMeant.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            } header: {
                Text("Голосовой ввод")
            } footer: {
                Text("Встроено: «Сири», «си ви» → CV, «пдф» → PDF, «джимейл» → Gmail и другие. Если после диктовки вы исправите слово (например, «Сири» на «CV») и нажмёте поиск, приложение запомнит замену и покажет её здесь.")
            }
        }
        .navigationTitle("Обучение поиска")
        .onAppear { voiceFixes = VoiceFixes.learned }
    }
}
