import Foundation
import UIKit
import CoreHaptics
import Combine
import os

// MARK: - Haptic feedback for safety warnings and navigation events

@MainActor
final class HapticService: ObservableObject {

    // MARK: - Private

    private var hapticEngine: CHHapticEngine?
    private var isEngineRunning = false

    // Throttle: avoid overwhelming the user with constant vibrations
    private var lastHapticTime: [HapticType: Date] = [:]
    private let minimumInterval: TimeInterval = 0.3

    // MARK: - Haptic types

    enum HapticType {
        case obstacleWarning
        case obstacleDanger
        case groundUnsafe
        case goalReached
        case arrived
        case tap
    }

    // MARK: - Setup

    func configure() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            BNLog.haptic.warning("Device does not support Core Haptics")
            return
        }

        do {
            let engine = try CHHapticEngine()
            engine.stoppedHandler = { [weak self] reason in
                BNLog.haptic.warning("Haptic engine stopped: \(reason.rawValue)")
                self?.isEngineRunning = false
            }
            engine.resetHandler = { [weak self] in
                BNLog.haptic.info("Haptic engine reset — restarting")
                do {
                    try self?.hapticEngine?.start()
                    self?.isEngineRunning = true
                } catch {
                    BNLog.haptic.error("Failed to restart haptic engine: \(error.localizedDescription)")
                }
            }
            try engine.start()
            self.hapticEngine = engine
            self.isEngineRunning = true
            BNLog.haptic.info("Haptic engine configured and started")
        } catch {
            BNLog.haptic.error("Failed to create haptic engine: \(error.localizedDescription)")
        }
    }

    // MARK: - Play haptics

    func play(_ type: HapticType) {
        // Throttle
        let now = Date()
        if let lastTime = lastHapticTime[type], now.timeIntervalSince(lastTime) < minimumInterval {
            return
        }
        lastHapticTime[type] = now

        switch type {
        case .obstacleWarning:
            playPattern(intensity: 0.5, sharpness: 0.3, duration: 0.2)
        case .obstacleDanger:
            playPattern(intensity: 1.0, sharpness: 0.8, duration: 0.4)
        case .groundUnsafe:
            playPattern(intensity: 0.7, sharpness: 0.6, duration: 0.3)
        case .goalReached:
            playSuccessPattern()
        case .arrived:
            playArrivalPattern()
        case .tap:
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
        }
    }

    // MARK: - Pattern builders

    private func playPattern(intensity: Float, sharpness: Float, duration: TimeInterval) {
        guard let engine = hapticEngine, isEngineRunning else {
            // Fallback to UIKit haptics
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(intensity > 0.7 ? .error : .warning)
            return
        }

        do {
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
                ],
                relativeTime: 0,
                duration: duration
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            BNLog.haptic.error("Haptic pattern playback failed: \(error.localizedDescription)")
        }
    }

    private func playSuccessPattern() {
        guard let engine = hapticEngine, isEngineRunning else {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return
        }

        do {
            let events = [
                CHHapticEvent(eventType: .hapticTransient,
                              parameters: [
                                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6),
                                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                              ], relativeTime: 0),
                CHHapticEvent(eventType: .hapticTransient,
                              parameters: [
                                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
                                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7)
                              ], relativeTime: 0.15),
            ]
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            BNLog.haptic.error("Success haptic failed: \(error.localizedDescription)")
        }
    }

    private func playArrivalPattern() {
        guard let engine = hapticEngine, isEngineRunning else {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return
        }

        do {
            let events = [
                CHHapticEvent(eventType: .hapticTransient,
                              parameters: [
                                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5),
                                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)
                              ], relativeTime: 0),
                CHHapticEvent(eventType: .hapticTransient,
                              parameters: [
                                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7),
                                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)
                              ], relativeTime: 0.2),
                CHHapticEvent(eventType: .hapticContinuous,
                              parameters: [
                                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8)
                              ], relativeTime: 0.4, duration: 0.5),
            ]
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            BNLog.haptic.error("Arrival haptic failed: \(error.localizedDescription)")
        }
    }
}
