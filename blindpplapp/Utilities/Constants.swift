import Foundation

enum BNConstants {

  // MARK: - Safety thresholds (meters)

  /// Objects closer than this trigger an urgent stop warning
  static let dangerDistanceMeters: Float = 0.7
  /// Objects closer than this trigger a caution warning
  static let warningDistanceMeters: Float = 1.5
  /// Distance at which a secondary goal is considered "reached"
  static let goalReachedDistanceMeters: Float = 1.0

  // MARK: - Obstacle proximity sonification (meters)

  /// Max distance at which obstacles produce proximity clicks
  static let obstacleAwarenessRange: Float = 3.5
  /// Distance at which avoidance steering begins adjusting the goal beep
  static let obstacleAvoidanceRange: Float = 2.5
  /// Number of obstacle proximity zones across the field of view
  static let obstacleZoneCount: Int = 3
  /// Bounding box area fraction (0-1) above which the goal is considered reached
  static let goalReachedBoxAreaThreshold: Float = 0.35
  /// If the goal was this close (estimated meters) and then lost, treat as reached
  static let goalCloseEnoughToAssumeReached: Float = 1.5

  // MARK: - SLAM (disabled)

  // /// Grid cell size for the visited-area map
  // static let slamGridCellSize: Float = 0.5
  // /// Number of revisits to the same cell cluster before declaring a circle
  // static let circleDetectionThreshold: Int = 3

  // MARK: - YOLOE

  /// Seconds to keep a phantom coordinate alive after the object leaves the frame
  static let phantomCoordinateTimeoutSeconds: TimeInterval = 8.0
  /// Minimum detection confidence to accept a YOLOE result
  static let yoloeConfidenceThreshold: Float = 0.15

  // MARK: - Gemini

  /// Heartbeat interval: maximum seconds between Gemini calls during navigation
  static let geminiHeartbeatInterval: TimeInterval = 30.0
  /// Seconds after losing the secondary goal before re-calling Gemini
  static let goalLostRecallDelay: TimeInterval = 5.0

  // MARK: - Voice commands

  /// Wake word that activates voice command listening during navigation
  static let voiceCommandWakeWord = "phone"
  /// Maximum seconds to wait for a command after wake word detection
  static let voiceCommandTimeout: TimeInterval = 5.0

  // MARK: - Camera

  // Reduced resolution to decrease ML processing load
  // 1280x720 is sufficient for object detection and much faster than 1920x1080
  static let cameraFrameWidth: Int = 1280
  static let cameraFrameHeight: Int = 720
  static let cameraFPS: Int = 15  // Further reduced to minimize ML pipeline load

  // MARK: - Depth model

  /// MiDaS v2.1 Small input resolution
  static let depthModelInputSize: Int = 256

  // MARK: - Ground segmentation model

  static let groundSegInputSize: Int = 256

  // MARK: - Spatial audio

  /// How far away (in virtual meters) to place the goal audio source
  static let goalAudioSourceDistance: Float = 5.0
  /// How far away to place obstacle warning audio sources
  static let obstacleAudioSourceDistance: Float = 2.0

  // MARK: - Hardcoded API Keys

  /// Hardcoded Gemini API key - replace this with your actual API key
  /// Get your key at: https://aistudio.google.com/app/apikey
  ///
  /// kevin key
  // static let hardcodedGeminiAPIKey = "AIzaSyCDbPhrE7GxOrMrKkIqf_p5OPCxuqPQcBU"
  /// roy key
  ///
  /// AIzaSyDvGLiequiEp9mzGmvOvJOWxw7JjIBFTvw
  //  static let hardcodedGeminiAPIKey = "AIzaSyBGiJwodrYdIYcn_V9W9AsoqLPtx-ETXlk"
  static let hardcodedGeminiAPIKey = ProcessInfo.processInfo.environment["API_URL"] ?? ""

  // MARK: - User defaults keys

  static let apiKeyUserDefaultsKey = ProcessInfo.processInfo.environment["API_URL"] ?? "gemini_api_key"
  static let dangerDistanceKey = "danger_distance"
  static let warningDistanceKey = "warning_distance"
  static let voiceSpeedKey = "voice_speed"
  static let performanceModeKey = "performance_mode"

  // MARK: - Performance modes

  enum PerformanceMode: String, CaseIterable {
    case balanced = "balanced"  // All ML models at moderate frame rate
    case performance = "performance"  // Reduced frame rate, all models
    case battery = "battery"  // Minimal ML processing, max battery life

    var description: String {
      switch self {
      case .balanced: return "Balanced performance"
      case .performance: return "Max performance"
      case .battery: return "Battery saver"
      }
    }
  }
}
