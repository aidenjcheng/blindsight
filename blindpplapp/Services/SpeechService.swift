import AVFoundation
import Combine
import Foundation
import Speech
import os

// MARK: - Speech recognition for destination input and text-to-speech for status updates

@MainActor
final class SpeechService: NSObject, ObservableObject {

 // MARK: - Output

 @Published private(set) var isListening = false
 @Published private(set) var isSpeaking = false
 @Published private(set) var recognizedText = ""

 /// Fires when a final transcription result is received
 let transcriptionPublisher = PassthroughSubject<String, Never>()

 // MARK: - Private

 private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
 private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
 private var recognitionTask: SFSpeechRecognitionTask?
 private let audioEngine = AVAudioEngine()
 private let synthesizer = AVSpeechSynthesizer()
 private var speechRate: Float = 0.5

 /// Track whether stop was initiated manually vs automatically
 private var isManualStop = false
 /// Track if we've received at least one partial result
 private var hasReceivedPartialResult = false
 private var silenceTimer: Timer?

 // Debounce: avoid spamming TTS when multiple warnings fire in rapid succession
 private var lastSpokenMessage = ""
 private var lastSpeechTime: Date = .distantPast
 private let minimumSpeechInterval: TimeInterval = 2.0

 override init() {
  super.init()
  synthesizer.delegate = self
 }

 // MARK: - Permissions

 static func requestPermissions() async -> Bool {
  let speechStatus = await withCheckedContinuation { continuation in
   SFSpeechRecognizer.requestAuthorization { status in
    continuation.resume(returning: status == .authorized)
   }
  }

  guard speechStatus else {
   BNLog.speech.error("Speech recognition permission denied")
   return false
  }

  let micStatus = await withCheckedContinuation { continuation in
   AVAudioSession.sharedInstance().requestRecordPermission { granted in
    continuation.resume(returning: granted)
   }
  }
  guard micStatus else {
   BNLog.speech.error("Microphone permission denied")
   return false
  }

  BNLog.speech.info("Speech and microphone permissions granted")
  return true
 }

 // MARK: - Configuration

 func configure(speechRate: Float) {
  self.speechRate = speechRate
 }

 // MARK: - Speech recognition (for destination input)

 func startListening() {
  guard !isListening else {
   BNLog.speech.warning("Already listening")
   return
  }

  guard let recognizer = speechRecognizer, recognizer.isAvailable else {
   BNLog.speech.error("Speech recognizer not available")
   return
  }

  // Reset state
  isManualStop = false
  hasReceivedPartialResult = false
  recognizedText = ""
  resetSilenceTimer()

  // Stop any ongoing TTS so the mic can hear the user
  synthesizer.stopSpeaking(at: .immediate)

  recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
  guard let request = recognitionRequest else {
   BNLog.speech.error("Failed to create recognition request")
   return
  }
  request.shouldReportPartialResults = true

  do {
   let audioSession = AVAudioSession.sharedInstance()
   try audioSession.setCategory(
    .playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
   try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
   BNLog.speech.info("Audio session configured successfully")
  } catch {
   BNLog.speech.error("Audio session setup for listening failed: \(error.localizedDescription)")
   return
  }

  audioEngine.reset()

  let inputNode = audioEngine.inputNode
  let recordingFormat = inputNode.outputFormat(forBus: 0)

  guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
   BNLog.speech.error(
    "Invalid audio format: sampleRate=\(recordingFormat.sampleRate), channelCount=\(recordingFormat.channelCount)"
   )
   return
  }

  let bufferSize: AVAudioFrameCount = 4096

  inputNode.removeTap(onBus: 0)
  inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { [weak self] buffer, _ in
   guard buffer.frameLength > 0 else { return }
   self?.recognitionRequest?.append(buffer)
   AudioWaveformMonitor.shared.processBuffer(buffer)
  }

  do {
   audioEngine.prepare()
   try audioEngine.start()
   BNLog.speech.info("Audio engine started")
  } catch {
   BNLog.speech.error("Audio engine failed to start: \(error.localizedDescription)")
   return
  }

  recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
   guard let self else { return }

   if let result {
    let text = result.bestTranscription.formattedString
    DispatchQueue.main.async {
     self.recognizedText = text
    }

    // Track if we've received any partial result
    if !text.isEmpty {
     self.hasReceivedPartialResult = true
     self.resetSilenceTimer()
    }

    if result.isFinal {
     let cleanedText = self.cleanTranscription(text)
     BNLog.speech.info("Final transcription: '\(text)' -> '\(cleanedText)'")

     // Only send and stop if we have meaningful text after cleaning
     if !cleanedText.trimmingCharacters(in: .whitespaces).isEmpty {
      self.transcriptionPublisher.send(cleanedText)
     } else {
      BNLog.speech.warning("Received empty final transcription after cleaning, ignoring")
     }
     self.stopListening()
    }
   }

   if let error {
    let errorDesc = error.localizedDescription

    // Don't log/spam on manual stop or timeout
    if self.isManualStop {
     BNLog.speech.info("Recognition stopped manually")
    } else if !errorDesc.contains("cancelled") && !errorDesc.contains("(null)") {
     // Only log real errors
     BNLog.speech.error("Recognition error: \(errorDesc)")
    }
    self.stopListening()
   }
  }

  isListening = true
  BNLog.speech.info("Listening started for destination input")
 }

 func stopListening(isManual: Bool = true) {
  // Only proceed if actually listening
  guard isListening else {
   return
  }

  isManualStop = isManual

  // Stop audio engine first
  audioEngine.stop()
  audioEngine.inputNode.removeTap(onBus: 0)

  // End recognition
  recognitionRequest?.endAudio()
  recognitionRequest = nil

  // Cancel task (use finish instead of cancel to avoid crashes)
  recognitionTask?.finish()
  recognitionTask = nil

  DispatchQueue.main.async { [weak self] in
   self?.isListening = false
  }

  silenceTimer?.invalidate()
  silenceTimer = nil

  if isManual {
   BNLog.speech.info("Listening stopped (manual)")
  } else {
   BNLog.speech.info("Listening stopped (automatic)")
  }
 }

 private func resetSilenceTimer() {
  silenceTimer?.invalidate()
  silenceTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
   guard let self = self, self.isListening else { return }
   BNLog.speech.info("Transcription auto-stopped due to silence")
   if self.hasReceivedPartialResult {
    self.submitCurrentTranscription()
   } else {
    self.stopListening(isManual: false)
   }
  }
 }

 /// Manually stop listening and submit current partial result as final
 func submitCurrentTranscription() {
  guard isListening else { return }

  // If we have a partial result, treat it as final
  let currentText = recognizedText
  let cleanedText = cleanTranscription(currentText)

  if !cleanedText.trimmingCharacters(in: .whitespaces).isEmpty {
   BNLog.speech.info("Submitting manual transcription: '\(currentText)' -> '\(cleanedText)'")
   transcriptionPublisher.send(cleanedText)
  } else {
   BNLog.speech.warning("No transcription to submit")
  }

  stopListening(isManual: true)
 }

 // MARK: - Text-to-Speech

 /// Cleans up speech transcription by removing common filler words and artifacts
 private func cleanTranscription(_ text: String) -> String {
  var cleaned = text

  // Common filler words and phrases to remove
  let fillerPatterns = [
   // At start of sentence
   "^you want to\\s+",
   "^i want to\\s+",
   "^can you\\s+",
   "^i need to\\s+",
   "^i would like to\\s+",
   "^please\\s+",
   "^hey\\s+",
   // In middle of sentence
   "\\s+uh\\s+",
   "\\s+um\\s+",
   "\\s+like\\s+",
   "\\s+you know\\s+",
   "\\s+actually\\s+",
   "\\s+basically\\s+",
  ]

  for pattern in fillerPatterns {
   cleaned = cleaned.replacingOccurrences(
    of: pattern,
    with: " ",
    options: .regularExpression,
    range: cleaned.range(of: cleaned)
   )
  }

  // Clean up extra whitespace
  cleaned = cleaned.trimmingCharacters(in: .whitespaces)
  cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

  return cleaned
 }

 /// Speaks a navigation status message. Debounced to avoid rapid-fire announcements.
 func speak(_ message: String, priority: SpeechPriority = .normal) {
  let now = Date()

  switch priority {
  case .normal:
   // Skip if same message was just spoken or if too soon
   guard
    message != lastSpokenMessage || now.timeIntervalSince(lastSpeechTime) > minimumSpeechInterval
   else {
    return
   }
  case .urgent:
   // Interrupt current speech for urgent messages, but still debounce
   // to avoid repeating the same urgent message too rapidly
   let urgentInterval: TimeInterval = 1.0  // Shorter interval for urgent
   guard message != lastSpokenMessage || now.timeIntervalSince(lastSpeechTime) > urgentInterval
   else {
    return
   }
   synthesizer.stopSpeaking(at: .immediate)
  case .low:
   // Skip if currently speaking
   guard !synthesizer.isSpeaking else { return }
  }

  lastSpokenMessage = message
  lastSpeechTime = now

  do {
   let audioSession = AVAudioSession.sharedInstance()
   try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
   try audioSession.setActive(true, options: [])
  } catch {
   BNLog.speech.error("TTS audio session setup failed: \(error.localizedDescription)")
  }

  let utterance = AVSpeechUtterance(string: message)
  utterance.rate = speechRate
  utterance.pitchMultiplier = 1.0
  utterance.volume = 0.9

  if let voice = AVSpeechSynthesisVoice(language: "en-US") {
   utterance.voice = voice
  }

  synthesizer.speak(utterance)
  BNLog.speech.info("TTS [\(priority)]: '\(message)'")
 }

 enum SpeechPriority: CustomStringConvertible {
  case low, normal, urgent
  var description: String {
   switch self {
   case .low: return "low"
   case .normal: return "normal"
   case .urgent: return "urgent"
   }
  }
 }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechService: AVSpeechSynthesizerDelegate {
 func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
  DispatchQueue.main.async { [weak self] in
   self?.isSpeaking = true
  }
 }

 func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance)
 {
  DispatchQueue.main.async { [weak self] in
   self?.isSpeaking = false
  }
 }
}
