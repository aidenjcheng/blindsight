// SLAM functionality disabled - entire file commented out
//
// import Foundation
// import ARKit
// import Combine
// import simd
// import os
//
// // MARK: - ARKit-based visual-inertial odometry providing 6DOF tracking and visited-area mapping
//
// @MainActor
// final class SLAMService: NSObject, ObservableObject {
//
//     // MARK: - Output
//
//     @Published private(set) var slamMap = SLAMMap()
//     @Published private(set) var currentPosition: SIMD3<Float> = .zero
//     @Published private(set) var currentTransform: simd_float4x4 = matrix_identity_float4x4
//     @Published private(set) var trackingState: ARCamera.TrackingState = .notAvailable
//     @Published private(set) var isCircling = false
//
//     /// Fires when a significant pose update happens (every ~0.5m of movement or 10 degrees of rotation)
//     let significantPosePublisher = PassthroughSubject<simd_float4x4, Never>()
//
//     // MARK: - Private
//
//     private var session: ARSession?
//     private let poseUpdateQueue = DispatchQueue(label: "com.blindnav.slam", qos: .userInitiated)
//     private var lastRecordedPosition: SIMD3<Float>?
//     private let minRecordDistance: Float = 0.3
//     private weak var depthService: DepthEstimationService?
//
//     // MARK: - Lifecycle
//
//     func configure(depthService: DepthEstimationService? = nil) {
//         BNLog.slam.info("Configuring ARKit SLAM session...")
//         let arSession = ARSession()
//         arSession.delegate = self
//         self.session = arSession
//         self.depthService = depthService
//
//         if let depthService = depthService {
//             depthService.configure(session: arSession)
//         }
//     }
//
//     func start() {
//         guard let session else {
//             BNLog.slam.error("ARSession not configured. Call configure() first.")
//             return
//         }
//
//         let config = ARWorldTrackingConfiguration()
//         config.planeDetection = [.horizontal, .vertical]
//         config.environmentTexturing = .none
//         config.isAutoFocusEnabled = true
//
//         if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
//             config.frameSemantics = .sceneDepth
//             BNLog.slam.info("LiDAR scene reconstruction enabled")
//         }
//
//         if ARWorldTrackingConfiguration.supportedVideoFormats.contains(where: { $0.framesPerSecond == 60 }) {
//             BNLog.slam.info("60Hz tracking available")
//         }
//
//         session.run(config, options: [.resetTracking, .removeExistingAnchors])
//         BNLog.slam.info("ARKit SLAM session started")
//     }
//
//     func stop() {
//         session?.pause()
//         BNLog.slam.info("ARKit SLAM session paused")
//     }
//
//     func reset() {
//         slamMap = SLAMMap()
//         lastRecordedPosition = nil
//         isCircling = false
//         if let session {
//             let config = ARWorldTrackingConfiguration()
//             config.planeDetection = [.horizontal, .vertical]
//             session.run(config, options: [.resetTracking, .removeExistingAnchors])
//         }
//         BNLog.slam.info("SLAM map reset")
//     }
//
//     // MARK: - World coordinate helpers
//
//     func projectToWorld(normalizedX: Float, normalizedY: Float, depthMeters: Float) -> SIMD3<Float>? {
//         let transform = currentTransform
//         let camX = (normalizedX - 0.5) * 2.0 * depthMeters * 0.6
//         let camY = (0.5 - normalizedY) * 2.0 * depthMeters * 0.45
//         let camZ = -depthMeters
//         let cameraPoint = SIMD4<Float>(camX, camY, camZ, 1.0)
//         let worldPoint = transform * cameraPoint
//         return SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z)
//     }
//
//     func cameraForwardDirection() -> SIMD3<Float> {
//         let forward = SIMD4<Float>(0, 0, -1, 0)
//         let worldForward = currentTransform * forward
//         return normalize(SIMD3<Float>(worldForward.x, worldForward.y, worldForward.z))
//     }
//
//     func mapSummaryForGemini() -> String {
//         return slamMap.textSummary()
//     }
// }
//
// // MARK: - ARSessionDelegate
//
// extension SLAMService: ARSessionDelegate {
//
//     func session(_ session: ARSession, didUpdate frame: ARFrame) {
//         let transform = frame.camera.transform
//         let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
//         depthService?.sessionDidUpdateFrame(frame)
//
//         poseUpdateQueue.async { [weak self] in
//             guard let self else { return }
//             DispatchQueue.main.async {
//                 self.currentTransform = transform
//                 self.currentPosition = position
//                 self.trackingState = frame.camera.trackingState
//                 self.slamMap.currentPose = transform
//             }
//
//             if let lastPos = self.lastRecordedPosition {
//                 let dist = length(position - lastPos)
//                 guard dist >= self.minRecordDistance else { return }
//             }
//
//             self.lastRecordedPosition = position
//             DispatchQueue.main.async {
//                 self.slamMap.recordPose(position: position, timestamp: Date())
//                 let circling = self.slamMap.isCircleDetected()
//                 if circling != self.isCircling {
//                     self.isCircling = circling
//                     if circling {
//                         BNLog.slam.warning("Circle detected — user may be going in circles")
//                     }
//                 }
//             }
//             self.significantPosePublisher.send(transform)
//         }
//     }
//
//     func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
//         DispatchQueue.main.async { [weak self] in
//             self?.trackingState = camera.trackingState
//         }
//         switch camera.trackingState {
//         case .notAvailable:
//             BNLog.slam.error("ARKit tracking not available")
//         case .limited(let reason):
//             let reasonStr: String
//             switch reason {
//             case .initializing: reasonStr = "initializing"
//             case .excessiveMotion: reasonStr = "excessive motion"
//             case .insufficientFeatures: reasonStr = "insufficient features"
//             case .relocalizing: reasonStr = "relocalizing"
//             @unknown default: reasonStr = "unknown"
//             }
//             BNLog.slam.warning("ARKit tracking limited: \(reasonStr)")
//         case .normal:
//             BNLog.slam.info("ARKit tracking normal")
//         }
//     }
//
//     func session(_ session: ARSession, didFailWithError error: Error) {
//         BNLog.slam.error("ARKit session failed: \(error.localizedDescription)")
//     }
// }
