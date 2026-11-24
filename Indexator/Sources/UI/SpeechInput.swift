// SPDX-License-Identifier: GPL-3.0-or-later
//
// Push-to-talk voice input for the search field. Russian, recognized on the
// device when the phone supports it (no audio leaves the phone then).

import AVFoundation
import Foundation
import Speech

@MainActor
final class SpeechInput: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var error: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onFinish: ((String) -> Void)?
    /// Bumped on every start and stop, so late callbacks from an old session
    /// can't change the text after the user has stopped and started editing.
    private var session = 0

    /// Words the recognizer should prefer when it hears them, so "CV" is not
    /// heard as "Siri". Mostly Latin terms said inside Russian speech.
    static let contextualStrings = [
        "CV", "резюме", "PDF", "Word", "Excel", "Gmail", "email", "iCloud", "Indexator",
        "скриншот", "скриншоты", "договор", "счёт", "invoice", "booking", "Booking",
        "Valencia", "Валенсия", "Telegram", "WhatsApp", "селфи", "видео", "фото",
    ]

    func toggle(onFinish: @escaping (String) -> Void) {
        if isRecording {
            stop()
        } else {
            Task { await start(onFinish: onFinish) }
        }
    }

    private func start(onFinish: @escaping (String) -> Void) async {
        error = nil
        transcript = ""
        self.onFinish = onFinish
        session += 1
        let current = session

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechStatus == .authorized else {
            error = "Нет доступа к распознаванию речи. Разреши в Настройках."
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "Нет доступа к микрофону. Разреши в Настройках."
            return
        }
        // Permission prompts are async: the user may have stopped meanwhile.
        guard current == session else { return }
        guard let recognizer, recognizer.isAvailable else {
            error = "Распознавание русской речи сейчас недоступно."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .search
            request.contextualStrings = Self.contextualStrings
            request.addsPunctuation = false
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            self.request = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            AppLog.shared.add("Голос: запись, на устройстве: \(recognizer.supportsOnDeviceRecognition)")

            task = recognizer.recognitionTask(with: request) { [weak self] result, err in
                Task { @MainActor in
                    guard let self, self.session == current, self.isRecording else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        if result.isFinal {
                            self.finish()
                        }
                    } else if err != nil {
                        self.finish()
                    }
                }
            }
        } catch {
            self.error = "Не удалось включить микрофон: \(error.localizedDescription)"
            cleanup()
        }
    }

    /// User tapped the button again: stop listening and use what was heard.
    /// Returns the heard text, so a caller can use it right away.
    @discardableResult
    func stop() -> String {
        guard isRecording else { return "" }
        request?.endAudio()
        return finish()
    }

    @discardableResult
    private func finish() -> String {
        guard isRecording else { return "" }
        session += 1
        let text = Self.clean(transcript)
        let callback = onFinish
        onFinish = nil
        cleanup()
        if !text.isEmpty {
            AppLog.shared.add("Голос: «\(text)»")
            callback?(text)
        }
        return text
    }

    /// Drops the trailing full stop and stray spaces the recognizer may add.
    static func clean(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, ".!?,".contains(last) { text.removeLast() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanup() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
