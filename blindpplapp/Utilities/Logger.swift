import Foundation
import os

// MARK: - Centralized logging for all BlindNav subsystems

enum BNLog {
    static let camera      = Logger(subsystem: "com.blindnav.app", category: "Camera")
    static let depth       = Logger(subsystem: "com.blindnav.app", category: "Depth")
    static let groundSeg   = Logger(subsystem: "com.blindnav.app", category: "GroundSeg")
    static let yoloe       = Logger(subsystem: "com.blindnav.app", category: "YOLOE")
    static let gemini      = Logger(subsystem: "com.blindnav.app", category: "Gemini")
    // SLAM disabled
    // static let slam        = Logger(subsystem: "com.blindnav.app", category: "SLAM")
    static let spatialAudio = Logger(subsystem: "com.blindnav.app", category: "SpatialAudio")
    static let speech      = Logger(subsystem: "com.blindnav.app", category: "Speech")
    static let haptic      = Logger(subsystem: "com.blindnav.app", category: "Haptic")
    static let navigation  = Logger(subsystem: "com.blindnav.app", category: "Navigation")
    static let app         = Logger(subsystem: "com.blindnav.app", category: "App")
}
