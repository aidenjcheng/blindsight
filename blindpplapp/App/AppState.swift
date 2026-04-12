import Foundation
import Combine
import SwiftUI
import UIKit
import os

// MARK: - Global observable app state shared across views and services

@MainActor
final class AppState: ObservableObject {
    @Published var session = NavigationSession()
    @Published var isSettingsPresented = false

    // MARK: - Debug visualization

    /// Latest depth map for visualization (debug mode)
    @Published var debugDepthMap: (depthGrid: [[Float]], gridWidth: Int, gridHeight: Int, closestObstacle: (x: Int, y: Int, distance: Float)?)?

    /// Latest camera frame as UIImage for debug overlay
    @Published var debugCameraFrame: UIImage?

    /// Latest YOLOE detections for bounding box overlay
    @Published var debugDetections: [YOLOEService.Detection] = []

    // MARK: - Voice command state

    /// Whether the voice command listener is actively listening for the wake word
    @Published var isVoiceCommandListening = false
    /// Whether a voice command is being processed by Gemini
    @Published var isVoiceCommandProcessing = false
    /// The last recognized voice command (for UI feedback)
    @Published var lastVoiceCommand = ""

    // MARK: - Persisted settings

    @AppStorage(BNConstants.apiKeyUserDefaultsKey) var geminiAPIKey: String = BNConstants.hardcodedGeminiAPIKey
    @AppStorage(BNConstants.dangerDistanceKey) var dangerDistance: Double = Double(BNConstants.dangerDistanceMeters)
    @AppStorage(BNConstants.warningDistanceKey) var warningDistance: Double = Double(BNConstants.warningDistanceMeters)
    @AppStorage(BNConstants.voiceSpeedKey) var voiceSpeed: Double = 0.5
    @AppStorage(BNConstants.performanceModeKey) var performanceModeRaw: String = BNConstants.PerformanceMode.balanced.rawValue

    var performanceMode: BNConstants.PerformanceMode {
        get { BNConstants.PerformanceMode(rawValue: performanceModeRaw) ?? .balanced }
        set {
            performanceModeRaw = newValue.rawValue
            navigationEngine?.updatePerformanceMode(newValue)
        }
    }

    // MARK: - Service references (initialized lazily by NavigationEngine)

    var navigationEngine: NavigationEngine?

    // MARK: - Actions

    func startNavigation(destination: String) {
        BNLog.app.info("Starting navigation to: \(destination)")
        session.destination = destination
        session.phase = .planning
        session.completedSecondaryGoals = []
        session.currentSecondaryGoal = nil
        session.safetyAlert = .clear
        session.isFinalDestinationVisible = false
        session.isCircleDetected = false
        session.statusMessage = "Planning route to \(destination)..."
        navigationEngine?.start(destination: destination)
    }

    func stopNavigation() {
        BNLog.app.info("Navigation stopped by user")
        navigationEngine?.stop()
        session.phase = .idle
        session.statusMessage = "Navigation stopped"
    }

    func updatePhase(_ phase: NavigationPhase) {
        session.phase = phase
    }

    func updateStatus(_ message: String) {
        session.statusMessage = message
    }
}
