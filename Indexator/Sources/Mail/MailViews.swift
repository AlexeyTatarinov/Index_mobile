// SPDX-License-Identifier: GPL-3.0-or-later
//
// Mail screens: consent + Gmail connection + sync (MailSettingsView),
// a single email (MailDetailView) and a stand-alone mail search (MailView).

import SwiftUI

struct MailSettingsView: View {
    @ObservedObject private var engine = MailEngine.shared
    @State private var confirmDelete = false
    @State private var confirmDisconnect = false

    var body: some View {
        Form {
            consentSection
            if engine.consentGiven {
                googleSection
                if engine.isConnected { syncSection }
                dataSection
            }
            if let error = engine.lastError {
                Section {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Почта")
        .confirmationDialog("Отключить Gmail?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Отключить и удалить письма", role: .destructive) { Task { await engine.disconnect(deleteMail: true) } }
            Button("Отключить, письма оставить") { Task { await engine.disconnect(deleteMail: false) } }
        } message: {
            Text("Доступ приложения к почте будет отозван в Google.")
        }
        .confirmationDialog("Удалить скачанные письма с телефона?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { Task { await engine.deleteLocalMail() } }
        }
    }

    private var consentSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Поиск по почте").font(.headline)
                Text("""
                • Приложение получает доступ к Gmail только на чтение. Пароль вводится только на странице Google.
                • Интернет используется только при синхронизации, которую ты запускаешь сам.
                • Письма сохраняются только на этом телефоне, ни на какие серверы, кроме Google, ничего не отправляется.
                • Вложения не скачиваются, сохраняются только их имена.
                • Отключить доступ и удалить письма можно в любой момент здесь же.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Toggle("Я согласен проиндексировать мою почту", isOn: $engine.consentGiven)
                .disabled(engine.isConnected)
        } footer: {
            if engine.isConnected { Text("Чтобы отозвать согласие, сначала отключи Gmail.") }
        }
    }

    private var googleSection: some View {
        Section {
            if let account = engine.account {
                LabeledContent("Аккаунт", value: account)
                Button("Отключить Gmail", role: .destructive) { confirmDisconnect = true }
                    .disabled(engine.isSyncing)
            } else {
                TextField("Client ID (…apps.googleusercontent.com)", text: $engine.clientId, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                if !engine.clientId.isEmpty && engine.config == nil {
                    Text("Это не похоже на Client ID типа iOS.").font(.footnote).foregroundStyle(.red)
                }
                Button {
                    Task { await engine.connect() }
                } label: {
                    if engine.isConnecting { ProgressView() } else { Text("Войти в Google") }
                }
                .disabled(engine.config == nil || engine.isConnecting)
            }
        } header: {
            Text("Gmail")
        } footer: {
            if !engine.isConnected {
                Text("Client ID берётся из своего проекта в Google Cloud Console (клиент OAuth типа iOS, Bundle ID io.github.alexeytatarinov.indexator). Это не секрет, но храним его только на телефоне.")
            }
        }
    }

    private var syncSection: some View {
        Section("Синхронизация") {
            Picker("Период", selection: $engine.period) {
                ForEach(MailEngine.SyncPeriod.allCases) { Text($0.title).tag($0) }
            }
            .disabled(engine.isSyncing)
            if engine.period == .custom {
                DatePicker("Начиная с", selection: $engine.customStart, in: ...Date(), displayedComponents: .date)
                    .disabled(engine.isSyncing)
            }
            Toggle("Пропускать «Промоакции» и «Соцсети»", isOn: $engine.skipPromotions)
                .disabled(engine.isSyncing)
            if engine.isSyncing {
                VStack(alignment: .leading) {
                    Text(engine.syncStage).font(.footnote)
                    if engine.progressTotal > 0 {
                        ProgressView(value: Double(engine.progressDone), total: Double(engine.progressTotal)) {
                            Text("\(engine.progressDone) из \(engine.progressTotal)").font(.caption)
                        }
                    } else {
                        ProgressView()
                    }
                }
                Button("Остановить", role: .destructive) { engine.stopSync() }
            } else {
                Button("Синхронизировать сейчас") { engine.startSync() }
            }
            if let last = engine.lastSync {
                LabeledContent("Последняя", value: last.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private var dataSection: some View {
        Section("На телефоне") {
            LabeledContent("Писем скачано", value: "\(engine.storedCount)")
            LabeledContent("Модель смысла", value: engine.embedderStatus)
            if engine.pendingVectors > 0 {
                LabeledContent("Ждут индексации", value: "\(engine.pendingVectors)")
                if !engine.isSyncing {
                    Button("Проиндексировать") { Task { await engine.indexPending() } }
                }
            }
            Button("Удалить скачанные письма", role: .destructive) { confirmDelete = true }
                .disabled(engine.storedCount == 0 || engine.isSyncing)
        }
    }
}

struct MailDetailView: View {
    let messageId: String
    @State private var message: MailMessage?
    @State private var loaded = false
    @State private var links: [MailLink] = []
    @State private var linksExpanded = true
    @Environment(\.openURL) private var openURL

    /// Body text with web addresses turned into tappable links.
    static func linkified(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
        }
        return result
    }

    var body: some View {
        ScrollView {
            if let m = message {
                VStack(alignment: .leading, spacing: 10) {
                    Text(m.subject.isEmpty ? "(без темы)" : m.subject).font(.title3.bold())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("От: \(m.sender)")
                        if !m.recipients.isEmpty { Text("Кому: \(m.recipients)") }
                        if let date = m.date { Text(date.formatted(date: .long, time: .shortened)) }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    if !m.attachments.isEmpty {
                        Label(m.attachments.joined(separator: ", "), systemImage: "paperclip")
                            .font(.footnote)
                    }
                    if !links.isEmpty {
                        DisclosureGroup("Ссылки (\(links.count))", isExpanded: $linksExpanded) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(links, id: \.self) { link in
                                    Link(destination: link.url) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(link.label).font(.callout).lineLimit(2)
                                            Text(link.url.host ?? "").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                        .font(.footnote)
                    }
                    Divider()
                    Text(Self.linkified(m.body.isEmpty ? m.snippet : m.body))
                        .font(.callout)
                        .textSelection(.enabled)
                }
                .padding()
            } else if loaded {
                Text("Письмо не найдено на телефоне.").foregroundStyle(.secondary).padding()
            } else {
                ProgressView().padding()
            }
        }
        .navigationTitle("Письмо")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let m = message {
                    ShareLink(item: "\(m.subject)\n\(m.sender)\n\n\(m.body)")
                    Button {
                        if let url = URL(string: "https://mail.google.com/mail/u/0/#all/\(m.id)") { openURL(url) }
                    } label: {
                        Image(systemName: "envelope.arrow.triangle.branch")
                    }
                    .accessibilityLabel("Открыть в Gmail")
                }
            }
        }
        .task(id: messageId) {
            message = await MailEngine.shared.message(id: messageId)
            loaded = true
            links = message?.links ?? []
            if links.isEmpty, message != nil {
                links = await MailEngine.shared.fetchMissingLinks(id: messageId)
            }
        }
    }
}

/// Stand-alone mail search screen. The main search screen shows mail results too
/// (via MailEngine.search); this one is for testing and for mail-only search.
struct MailView: View {
    @ObservedObject private var engine = MailEngine.shared
    @State private var query = UserDefaults.standard.string(forKey: "autoMailQuery") ?? ""

    var body: some View {
        NavigationStack {
            List {
                if !engine.consentGiven || (!engine.isConnected && engine.storedCount == 0) {
                    Section {
                        NavigationLink("Подключить Gmail") { MailSettingsView() }
                    } footer: {
                        Text("Письма скачиваются на телефон один раз, дальше поиск работает без интернета.")
                    }
                }
                if let info = engine.lastQueryInfo {
                    Text(info).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(engine.results) { hit in
                    NavigationLink {
                        MailDetailView(messageId: hit.id)
                    } label: {
                        MailHitRow(hit: hit)
                    }
                }
            }
            .navigationTitle("Почта")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Например: билет на поезд летом")
            .onSubmit(of: .search) { Task { await engine.search(query) } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { MailSettingsView() } label: { Image(systemName: "gearshape") }
                }
            }
            .task {
                await engine.runAutomation()
                if engine.results.isEmpty && query.isEmpty { await engine.search("") }
            }
        }
    }
}

struct MailHitRow: View {
    let hit: MailHit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(hit.sender).font(.subheadline.bold()).lineLimit(1)
                Spacer()
                if let date = hit.date {
                    Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(hit.subject).font(.subheadline).lineLimit(1)
            Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 8) {
                if hit.textMatch { Label("слова", systemImage: "text.magnifyingglass") }
                if hit.score > 0 { Text(String(format: "смысл %.2f", hit.score)) }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}
