import Foundation
import Speech
import AVFoundation
import Combine
import os

// MARK: - Continuous wake-word listener that activates during navigation
//
// Listens for "phone" followed by a spoken command (e.g. "phone where to now").
// When the wake word is detected the command portion is published for NavigationEngine
// to route to Gemini. Recognition auto-restarts when it times out (~1 min iOS limit).

@MainActor
final class VoiceCommandService: NSObject, ObservableObject {

    // MARK: - Output

    /// Fires with the user's command text (everything after "phone")
    let commandPublisher = PassthroughSubject<String, Never>()

    @Published private(set) var isListening = false
    @Published private(set) var isProcessingCommand = false
    @Published private(set) var lastHeardCommand = ""

    // MARK: - Private

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    private var isActive = false
    private var restartTimer: Timer?

    /// Tracks whether the wake word was detected in the current recognition session
    private var wakeWordDetected = false
    /// Accumulates text after the wake word to allow the user to finish speaking
    private var commandText = ""
    /// Timer to finalize the command after a brief pause
    private var commandFinalizeTimer: Timer?

    // Prevent re-triggering on the same utterance
    private var lastProcessedTranscription = ""

    // MARK: - Lifecycle

    /// Start continuous wake-word listening (call when navigation begins)
    func startListening() {
        guard !isActive else { return }
        isActive = true
        BNLog.speech.info("VoiceCommand: activating continuous listener")
        beginRecognitionSession()
    }

    /// Stop all listening (call when navigation ends)
    func stopListening() {
        isActive = false
        tearDownSession()
        restartTimer?.invalidate()
        restartTimer = nil
        commandFinalizeTimer?.invalidate()
        commandFinalizeTimer = nil
        isListening = false
        wakeWordDetected = false
        commandText = ""
        lastProcessedTranscription = ""
        BNLog.speech.info("VoiceCommand: deactivated")
    }

    /// Temporarily pause listening (e.g. while TTS is speaking to avoid echo)
    func pause() {
        guard isActive, isListening else { return }
        tearDownSession()
        isListening = false
    }

    /// Resume listening after a pause
    func resume() {
        guard isActive, !isListening else { return }
        beginRecognitionSession()
    }

    // MARK: - Recognition session management

    private func beginRecognitionSession() {
        guard isActive else { return }
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            BNLog.speech.error("VoiceCommand: speech recognizer not available")
            scheduleRestart()
            return
        }

        // Reset per-session state
        wakeWordDetected = false
        commandText = ""
        lastProcessedTranscription = ""

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
            )
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            BNLog.speech.error("VoiceCommand: audio session setup failed: \(error.localizedDescription)")
            scheduleRestart()
            return
        }

        audioEngine.reset()

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            BNLog.speech.error("VoiceCommand: invalid audio format")
            scheduleRestart()
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard buffer.frameLength > 0 else { return }
            self?.recognitionRequest?.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            BNLog.speech.error("VoiceCommand: audio engine start failed: \(error.localizedDescription)")
            scheduleRestart()
            return
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString.lowercased()
                DispatchQueue.main.async {
                    self.handlePartialResult(text, isFinal: result.isFinal)
                }
            }

            if error != nil {
                DispatchQueue.main.async {
                    self.tearDownSession()
                    self.scheduleRestart()
                }
            }
        }

        isListening = true
        BNLog.speech.info("VoiceCommand: recognition session started")
    }

    private func tearDownSession() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.finish()
        recognitionTask = nil
    }

    /// Restart recognition after the iOS ~1 minute timeout or transient errors
    private func scheduleRestart() {
        guard isActive else { return }
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.beginRecognitionSession()
            }
        }
    }

    // MARK: - Wake word detection

    private func handlePartialResult(_ text: String, isFinal: Bool) {
        // Avoid re-processing the same partial
        guard text != lastProcessedTranscription else { return }
        lastProcessedTranscription = text

        let wakeWord = BNConstants.voiceCommandWakeWord.lowercased()

        if !wakeWordDetected {
            // Look for the wake word in the transcription
            guard let range = text.range(of: wakeWord) else { return }

            wakeWordDetected = true
            let afterWake = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            commandText = afterWake
            lastHeardCommand = afterWake
            isProcessingCommand = true
            BNLog.speech.info("VoiceCommand: wake word detected, partial command: '\(afterWake)'")
            resetCommandTimer()
        } else {
            // Wake word already found — update command text with latest partial
            if let range = text.range(of: wakeWord) {
                let afterWake = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                commandText = afterWake
                lastHeardCommand = afterWake
            }
            resetCommandTimer()
        }

        // If the recognition result is final, finalize immediately
        if isFinal, wakeWordDetected {
            finalizeCommand()
        }
    }

    /// Waits a short pause after the last partial result to let the user finish speaking
    private func resetCommandTimer() {
        commandFinalizeTimer?.invalidate()
        commandFinalizeTimer = Timer.scheduledTimer(
            withTimeInterval: BNConstants.voiceCommandTimeout,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.finalizeCommand()
            }
        }
    }

    private func finalizeCommand() {
        commandFinalizeTimer?.invalidate()
        commandFinalizeTimer = nil

        let command = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            BNLog.speech.info("VoiceCommand: wake word heard but no command — ignoring")
            resetForNextCommand()
            return
        }

        BNLog.speech.info("VoiceCommand: finalized command: '\(command)'")
        commandPublisher.send(command)

        resetForNextCommand()
    }

    private func resetForNextCommand() {
        wakeWordDetected = false
        commandText = ""
        isProcessingCommand = false

        // Restart recognition to listen for the next command
        tearDownSession()
        scheduleRestart()
    }
}
