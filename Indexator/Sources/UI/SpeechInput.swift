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
                    guard let self else { return }
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
    func stop() {
        guard isRecording else { return }
        request?.endAudio()
        finish()
    }

    private func finish() {
        guard isRecording else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanup()
        if !text.isEmpty {
            AppLog.shared.add("Голос: «\(text)»")
            onFinish?(text)
        }
        onFinish = nil
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
