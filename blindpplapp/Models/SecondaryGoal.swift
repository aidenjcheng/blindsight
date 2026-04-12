import Foundation
import simd

// MARK: - A secondary navigation waypoint produced by Gemini and tracked by YOLOE

struct SecondaryGoal: Identifiable, Equatable {
    let id: UUID
    /// Textual descriptor for YOLOE's text-prompt detection (e.g., "gray recycling bin next to the wall")
    let descriptor: String
    /// Direction hint from Gemini (e.g., "ahead and slightly left")
    let directionHint: String
    /// 3D world position from YOLOE + depth + ARKit; nil until first detection
    var worldPosition: SIMD3<Float>?
    /// Whether YOLOE is currently tracking this object in the frame
    var isCurrentlyTracked: Bool = false
    /// The last time YOLOE saw this object
    var lastSeenTime: Date?
    /// Last estimated distance to this goal (meters), used for "close then lost" heuristic
    var lastEstimatedDistance: Float?
    /// Phantom coordinate (SLAM disabled — not currently populated)
    var phantomWorldPosition: SIMD3<Float>?
    /// Timestamp when object left the frame (for phantom timeout)
    var leftFrameTime: Date?

    static func == (lhs: SecondaryGoal, rhs: SecondaryGoal) -> Bool {
        lhs.id == rhs.id
    }

    /// Best available world position: live tracking first, phantom fallback
    var effectiveWorldPosition: SIMD3<Float>? {
        if isCurrentlyTracked, let pos = worldPosition {
            return pos
        }
        return phantomWorldPosition
    }

    /// Whether the phantom has expired
    func isPhantomExpired(timeout: TimeInterval = BNConstants.phantomCoordinateTimeoutSeconds) -> Bool {
        guard let leftTime = leftFrameTime else { return false }
        return Date().timeIntervalSince(leftTime) > timeout
    }
}
