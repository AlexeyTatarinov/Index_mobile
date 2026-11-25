// SPDX-License-Identifier: GPL-3.0-or-later
//
// Video results: grid cell and card showing the matching moment, the player
// that opens at that second with chips for other good moments and the speech
// transcript, and the video section of Settings.

import AVKit
import CoreTransferable
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// One frame of a video at the given time, square-cropped like photo thumbnails.
struct VideoThumbnail: View {
    let id: String
    let time: Double
    let side: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fill)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: "\(id)@\(time)") {
                let loaded = await VideoLibrary.frame(id: id, at: time, side: side * 2)
                withAnimation(.easeOut(duration: 0.15)) { image = loaded }
            }
    }
}

/// "▶ 0:07" badge: where in the video the match is.
struct VideoMomentBadge: View {
    let time: Double

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
                .font(.system(size: 8, weight: .bold))
            Text(VideoFormat.time(time))
                .font(.caption2.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
        .accessibilityLabel("Видео, момент \(VideoFormat.time(time))")
    }
}

struct VideoGridCell: View {
    let item: ResultItem

    var body: some View {
        VideoThumbnail(id: item.id, time: item.time ?? 0, side: 130)
            .overlay(alignment: .bottomTrailing) {
                VideoMomentBadge(time: item.time ?? 0).padding(4)
            }
            .overlay(alignment: .bottomLeading) {
                if item.textMatch {
                    Image(systemName: "waveform")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                        .padding(4)
                        .accessibilityLabel("Найдено в речи")
                }
            }
    }
}

struct VideoCard: View {
    let item: ResultItem
    let onOpen: () -> Void
    let onAddToAlbum: () -> Void
    let onDeleted: () -> Void
    @State private var date: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onOpen) {
                VideoThumbnail(id: item.id, time: item.time ?? 0, side: 92)
                    .frame(width: 92, height: 92)
                    .overlay(alignment: .bottomTrailing) { VideoMomentBadge(time: item.time ?? 0).padding(4) }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(Format.date(date) ?? "Без даты")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let speech = item.snippet, !speech.isEmpty {
                    Label("«\(speech)»", systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)

            Menu {
                VideoMenu(id: item.id, onOpen: onOpen, onAddToAlbum: onAddToAlbum, onDeleted: onDeleted)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task(id: item.id) {
            date = PhotoLibrary.asset(withId: item.id)?.creationDate
        }
    }

    private var details: String {
        var parts = ["Видео"]
        if let duration = item.duration, duration > 0 { parts.append(VideoFormat.time(duration)) }
        if let time = item.time { parts.append("момент \(VideoFormat.time(time))") }
        return parts.joined(separator: " · ")
    }
}

struct VideoMenu: View {
    let id: String
    let onOpen: () -> Void
    let onAddToAlbum: () -> Void
    let onDeleted: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Label("Смотреть с этого места", systemImage: "play")
        }
        ShareLink(item: SharedVideo(id: id), preview: SharePreview("Видео")) {
            Label("Поделиться", systemImage: "square.and.arrow.up")
        }
        Button(action: onAddToAlbum) {
            Label("Добавить в альбом", systemImage: "rectangle.stack.badge.plus")
        }
        Button {
            PhotoActions.openPhotosApp()
        } label: {
            Label("Открыть «Фото»", systemImage: "photo.on.rectangle")
        }
        Divider()
        FeedbackMenuItems(kind: .video, id: id)
        Divider()
        Button(role: .destructive) {
            Task { if await PhotoActions.delete(id: id) { onDeleted() } }
        } label: {
            Label("Удалить", systemImage: "trash")
        }
    }
}

/// A video as something to share: the original file, copied to a temporary folder.
struct SharedVideo: Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .movie) { video in
            SentTransferredFile(try await video.exportFile())
        }
    }

    func exportFile() async throws -> URL {
        guard let asset = PhotoLibrary.asset(withId: id),
              let urlAsset = await VideoLibrary.avAsset(for: asset, allowNetwork: true) as? AVURLAsset
        else { throw CocoaError(.fileNoSuchFile) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(urlAsset.url.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: urlAsset.url, to: target)
        return target
    }
}

/// Plays a found video from the matching moment.
struct VideoPlayerView: View {
    let item: ResultItem
    let onDeleted: (ResultItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var loaded = false
    @State private var failed = false
    @State private var date: Date?
    @State private var transcript: [SpeechChunk] = []
    @State private var albumFor: ResultItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ZStack {
                        VideoPlayer(player: player)
                        if !loaded {
                            VideoThumbnail(id: item.id, time: item.time ?? 0, side: 300)
                                .aspectRatio(contentMode: .fit)
                                .overlay {
                                    if failed {
                                        Label("Видео недоступно", systemImage: "icloud.slash")
                                            .padding(8)
                                            .background(.thinMaterial, in: Capsule())
                                    } else {
                                        ProgressView()
                                    }
                                }
                        }
                    }
                    .aspectRatio(9 / 12, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)

                    VStack(alignment: .leading, spacing: 12) {
                        if item.moments.count > 0 {
                            Text("Подходящие моменты")
                                .font(.subheadline.weight(.semibold))
                            FlowLayout {
                                ForEach(item.moments, id: \.self) { time in
                                    Chip(title: VideoFormat.time(time), systemImage: "play.fill") { seek(to: time) }
                                }
                            }
                        }
                        Label(Format.date(date) ?? "Дата неизвестна", systemImage: "calendar")
                            .font(.subheadline)
                        if let duration = item.duration, duration > 0 {
                            Label("Длительность \(VideoFormat.time(duration))", systemImage: "timer")
                                .font(.subheadline)
                        }
                        if item.score > 0 {
                            Label(String(format: "Сходство с запросом %.2f", item.score), systemImage: "sparkle.magnifyingglass")
                                .font(.subheadline)
                        }
                        if !transcript.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Что говорят", systemImage: "waveform")
                                    .font(.subheadline.weight(.semibold))
                                ForEach(Array(transcript.enumerated()), id: \.offset) { _, chunk in
                                    Button { seek(to: chunk.time) } label: {
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text(VideoFormat.time(chunk.time))
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(Color.accentColor)
                                            Text(chunk.text)
                                                .font(.callout)
                                                .foregroundStyle(.primary)
                                                .multilineTextAlignment(.leading)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .card()
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 24)
            }
            .navigationTitle("Видео с \(VideoFormat.time(item.time ?? 0))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    ShareLink(item: SharedVideo(id: item.id), preview: SharePreview("Видео")) {
                        Label("Поделиться", systemImage: "square.and.arrow.up")
                    }
                    Spacer()
                    Button { albumFor = item } label: {
                        Label("В альбом", systemImage: "rectangle.stack.badge.plus")
                    }
                    Spacer()
                    Button { PhotoActions.openPhotosApp() } label: {
                        Label("Открыть «Фото»", systemImage: "photo.on.rectangle")
                    }
                    Spacer()
                    Button(role: .destructive) {
                        Task {
                            if await PhotoActions.delete(id: item.id) {
                                onDeleted(item)
                                dismiss()
                            }
                        }
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
            }
            .sheet(item: $albumFor) { item in
                AlbumPicker(photoId: item.id)
            }
        }
        .task { await load() }
        .onDisappear { player.pause() }
    }

    private func load() async {
        guard let asset = PhotoLibrary.asset(withId: item.id) else { failed = true; return }
        date = asset.creationDate
        transcript = VideoEngine.shared.transcript(for: item.id)
        guard let playerItem = await VideoLibrary.playerItem(for: asset) else { failed = true; return }
        player.replaceCurrentItem(with: playerItem)
        _ = await player.seek(to: CMTime(seconds: item.time ?? 0, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
        loaded = true
        // CI screenshots show the matching frame, not a moving picture.
        if !UserDefaults.standard.bool(forKey: "autoOpenFirst") { player.play() }
    }

    private func seek(to time: Double) {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }
}

/// Settings → Видео.
struct VideoSettingsView: View {
    @ObservedObject private var video = VideoEngine.shared
    @EnvironmentObject private var engine: SearchEngine
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                Toggle("Искать по видео", isOn: $video.enabled)
                LabeledContent("Видео в медиатеке", value: Format.count(video.libraryCount))
                LabeledContent("В индексе", value: Format.count(video.indexedCount))
                LabeledContent("Ключевых кадров", value: Format.count(video.frameCount))
                if video.isIndexing {
                    ProgressView(value: Double(video.progressDone), total: Double(max(video.progressTotal, 1))) {
                        Text("Индексирую \(video.progressDone) из \(video.progressTotal)")
                            .font(.footnote)
                    }
                    if let seconds = video.secondsPerVideo {
                        Text(String(format: "%.1f с на видео", seconds))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Остановить", role: .destructive) { video.stopIndexing() }
                } else {
                    Button(video.indexedCount == 0 ? "Проиндексировать видео" : "Добавить новые видео") {
                        video.startIndexing(reason: "вручную")
                    }
                    .disabled(!video.enabled || engine.modelState != .ready || !engine.hasPhotoAccess)
                }
                if video.skippedCloud > 0 {
                    Text("Пропущено \(video.skippedCloud) видео: они только в iCloud.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Из каждого видео берётся до \(VideoSampler.maxFrames) кадров, похожие подряд отбрасываются. В выдаче видно, на какой секунде нашлось, и видео открывается с этого места.")
            }

            Section {
                Toggle(isOn: $video.speechEnabled) {
                    Label("Речь в видео", systemImage: "waveform")
                }
                .disabled(video.isIndexing || !VideoSpeech.isAvailableOffline)
                Toggle(isOn: $video.allowCloud) {
                    Label("Загружать из iCloud", systemImage: "icloud.and.arrow.down")
                }
                .disabled(video.isIndexing)
            } footer: {
                if VideoSpeech.isAvailableOffline {
                    Text("Речь распознаётся прямо на телефоне, только в видео до \(Int(VideoSpeech.maxDuration / 60)) минут. Это медленнее, действует на новые видео. Загрузка из iCloud тратит трафик и место.")
                } else {
                    Text("Офлайн-распознавание русской речи на этом устройстве недоступно. Загрузка из iCloud тратит трафик и место.")
                }
            }

            Section {
                Button("Удалить индекс видео", role: .destructive) { confirmReset = true }
                    .disabled(video.isIndexing)
            }
        }
        .navigationTitle("Видео")
        .onAppear { video.refreshLibraryCount() }
        .confirmationDialog("Удалить индекс видео?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { video.resetIndex() }
        } message: {
            Text("Сами видео не удаляются.")
        }
    }
}
