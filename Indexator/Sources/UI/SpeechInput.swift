// SPDX-License-Identifier: GPL-3.0-or-later
//
// Push-to-talk voice input for the search field. Russian by default (English in
// Settings → Обучение поиска), recognized on the device when the phone supports it
// (no audio leaves the phone then). Misheard words are fixed by VoiceFixes.

import AVFoundation
import Foundation
import Speech

@MainActor
final class SpeechInput: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var error: String?

    static let languageKey = "voice.language"
    /// A fresh engine per recording: a reused one sometimes delivered no audio after
    /// another app or a call changed the audio route («говорил, но ничего не записалось»).
    private var audioEngine = AVAudioEngine()
    private var isStarting = false
    private var recognizer: SFSpeechRecognizer?
    private var buffers = 0
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
        "resume", "contract", "receipt", "ticket", "Siri", "iPhone", "QR",
    ]

    static var localeIdentifier: String {
        UserDefaults.standard.string(forKey: languageKey) ?? "ru-RU"
    }

    func toggle(onFinish: @escaping (String) -> Void) {
        if isRecording {
            stop()
        } else if isStarting {
            // Second tap while the microphone was still being prepared: cancel.
            session += 1
            isStarting = false
        } else {
            isStarting = true
            Task {
                await start(onFinish: onFinish)
                isStarting = false
            }
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
        // Kept in a property: the recognition task needs its recognizer alive.
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: Self.localeIdentifier))
        guard let recognizer, recognizer.isAvailable else {
            error = "Распознавание речи сейчас недоступно."
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

            audioEngine = AVAudioEngine()
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                error = "Микрофон сейчас занят другим приложением. Попробуйте ещё раз."
                AppLog.shared.add("Голос: у микрофона нет формата (\(format))")
                cleanup()
                return
            }
            buffers = 0
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                Task { @MainActor in self?.buffers += 1 }
            }
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            AppLog.shared.add("Голос: запись (\(Self.localeIdentifier)), на устройстве: \(recognizer.supportsOnDeviceRecognition)")
            watchMicrophone(session: current)

            task = recognizer.recognitionTask(with: request) { [weak self] result, err in
                Task { @MainActor in
                    guard let self, self.session == current, self.isRecording else { return }
                    if let result {
                        self.transcript = VoiceFixes.apply(result.bestTranscription.formattedString)
                        if result.isFinal {
                            self.finish()
                        }
                    } else if let err {
                        // Used to end silently, so it looked like the button did nothing.
                        AppLog.shared.add("Голос: ошибка распознавания: \(err.localizedDescription)")
                        if self.transcript.isEmpty {
                            self.error = "Не расслышал. Нажмите на микрофон и скажите ещё раз."
                        }
                        self.finish()
                    }
                }
            }
        } catch {
            self.error = "Не удалось включить микрофон: \(error.localizedDescription)"
            cleanup()
        }
    }

    /// If no audio arrives in the first two seconds, the microphone did not really start:
    /// say so instead of listening to silence.
    private func watchMicrophone(session current: Int) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard self.session == current, self.isRecording, self.buffers == 0 else { return }
            AppLog.shared.add("Голос: за 2 с не пришло ни одного звукового буфера")
            self.error = "Микрофон не включился. Нажмите на микрофон ещё раз."
            self.onFinish = nil
            self.session += 1
            self.cleanup()
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
        let text = VoiceFixes.apply(Self.clean(transcript))
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
