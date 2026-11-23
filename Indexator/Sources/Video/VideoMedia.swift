// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reading videos from the Photos library: the list of videos, the AVAsset of
// one video, keyframes at chosen times, and (optionally) what is said in it,
// recognized on the device.

import AVFoundation
import CoreGraphics
import Photos
import Speech
import UIKit

enum VideoLibrary {
    static func count() -> Int {
        PHAsset.fetchAssets(with: .video, options: nil).count
    }

    /// Newest first.
    static func fetchAssets() -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .video, options: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// The video file, or nil when it is only in iCloud and downloading is not allowed.
    static func avAsset(for asset: PHAsset, allowNetwork: Bool) async -> AVAsset? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = allowNetwork
            options.deliveryMode = allowNetwork ? .mediumQualityFormat : .automatic
            options.version = .current
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }
    }

    static func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    static func generator(for asset: AVAsset, maxSide: CGFloat) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        // Nearby keyframes are fine and much faster to decode than exact frames.
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        return generator
    }

    /// Thumbnail of one moment of a video, cached.
    static func frame(id: String, at time: Double, side: CGFloat) async -> UIImage? {
        let key = "\(id)@\(Int(time * 10))@\(Int(side))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let asset = PhotoLibrary.asset(withId: id) else { return nil }
        var image: UIImage?
        if let avAsset = await avAsset(for: asset, allowNetwork: false) {
            let generator = generator(for: avAsset, maxSide: side)
            if let cg = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
                image = UIImage(cgImage: cg)
            }
        }
        if image == nil {
            // In iCloud only: fall back to the poster frame Photos keeps on the device.
            image = await PhotoLibrary.image(for: asset, side: side)
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        return cache
    }()
}

enum VideoSampler {
    /// At most this many frames per video are looked at, so long videos stay cheap.
    static let maxFrames = 24
    /// Frames closer than this in meaning to the previous kept frame are dropped
    /// (the same scene), so a static shot costs one vector, not twenty.
    static let sameSceneSimilarity: Float = 0.94

    /// Every 2 seconds for short videos, evenly spread over long ones.
    static func times(duration: Double) -> [Double] {
        guard duration > 0.5 else { return [0] }
        let step = max(2.0, duration / Double(maxFrames))
        var times: [Double] = []
        var t = min(0.5, duration / 2)
        while t < duration && times.count < maxFrames {
            times.append(t)
            t += step
        }
        return times
    }

    /// Keeps a frame only when it differs from the previous kept one.
    static func keepSceneChanges(_ frames: [VideoFrame]) -> [VideoFrame] {
        var kept: [VideoFrame] = []
        for frame in frames {
            if let last = kept.last, VectorMath.dot(last.vector, frame.vector) >= sameSceneSimilarity {
                continue
            }
            kept.append(frame)
        }
        return kept
    }
}

/// Speech in a video, recognized only on the device (nothing is sent anywhere).
enum VideoSpeech {
    static let maxDuration: Double = 600
    static let chunkSeconds: Double = 8

    static var recognizer: SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    }

    /// True when the phone can recognize Russian offline.
    static var isAvailableOffline: Bool {
        recognizer?.supportsOnDeviceRecognition ?? false
    }

    static func requestAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return status == .authorized
    }

    static func transcribe(_ asset: AVAsset, duration: Double) async -> [SpeechChunk] {
        guard duration > 1, duration <= maxDuration,
              SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer, recognizer.supportsOnDeviceRecognition,
              let url = (asset as? AVURLAsset)?.url,
              let audio = try? await asset.loadTracks(withMediaType: .audio), !audio.isEmpty
        else { return [] }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        let once = Once()
        let segments: [SFTranscriptionSegment] = await withCheckedContinuation { continuation in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    once.run { continuation.resume(returning: result.bestTranscription.segments) }
                } else if error != nil {
                    once.run { continuation.resume(returning: []) }
                }
            }
            // Never wait forever on a stuck recognizer.
            DispatchQueue.global().asyncAfter(deadline: .now() + duration * 1.5 + 30) {
                once.run {
                    task.cancel()
                    continuation.resume(returning: [])
                }
            }
        }
        return chunks(from: segments.map { ($0.timestamp, $0.substring) })
    }

    /// Groups words into pieces of about `chunkSeconds`, each with its start time.
    static func chunks(from words: [(time: Double, text: String)]) -> [SpeechChunk] {
        var chunks: [SpeechChunk] = []
        var start = 0.0
        var current: [String] = []
        for word in words {
            if current.isEmpty {
                start = word.time
            } else if word.time - start >= chunkSeconds {
                chunks.append(SpeechChunk(time: start, text: current.joined(separator: " ")))
                current = []
                start = word.time
            }
            current.append(word.text)
        }
        if !current.isEmpty {
            chunks.append(SpeechChunk(time: start, text: current.joined(separator: " ")))
        }
        return chunks
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            body()
        }
    }
}

enum VideoFormat {
    /// 75 → "1:15", 3725 → "1:02:05".
    static func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
