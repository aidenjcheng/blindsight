import Foundation
import simd

// MARK: - Top-level navigation state machine

enum NavigationPhase: String, Equatable {
    case idle
    case listening
    case planning
    case navigating
    case arrived
}

// MARK: - Safety alert levels

enum SafetyAlert: Equatable {
    case clear
    case caution(direction: SIMD3<Float>, distanceMeters: Float)
    case danger(direction: SIMD3<Float>, distanceMeters: Float)
    case groundUnsafe(direction: SIMD3<Float>)
}

// MARK: - Gemini response model

struct GeminiNavigationResponse: Codable {
    let secondaryGoalDescriptor: String
    let directionHint: String
    let reasoning: String
    let confidence: Double
    let destinationInSight: Bool

    enum CodingKeys: String, CodingKey {
        case secondaryGoalDescriptor = "secondary_goal_descriptor"
        case directionHint = "direction_hint"
        case reasoning
        case confidence
        case destinationInSight = "destination_in_sight"
    }
}

// MARK: - Represents the full navigation session state

struct NavigationSession {
    var destination: String = ""
    var phase: NavigationPhase = .idle
    var currentSecondaryGoal: SecondaryGoal?
    var completedSecondaryGoals: [String] = []
    var safetyAlert: SafetyAlert = .clear
    var isFinalDestinationVisible: Bool = false
    var statusMessage: String = "Ready"
    var estimatedDistanceToGoal: Float?
    var isCircleDetected: Bool = false
    var lastGeminiCallTime: Date?
    var secondaryGoalLostSince: Date?
}
