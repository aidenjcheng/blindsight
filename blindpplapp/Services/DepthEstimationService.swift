import Foundation
import ARKit
import Combine
import Accelerate
import simd

// MARK: - LiDAR-based depth estimation using ARKit scene reconstruction

@MainActor
final class DepthEstimationService: NSObject, ObservableObject {

    // MARK: - Output

    let obstacleMapPublisher = PassthroughSubject<ObstacleMap, Never>()

    /// RGB camera frame extracted from each ARFrame (replaces AVCaptureSession which
    /// gets interrupted when ARKit takes exclusive camera ownership).
    let capturedFramePublisher = PassthroughSubject<CVPixelBuffer, Never>()

    /// Camera 6DOF transform every frame (world-tracking pose).
    let cameraTransformPublisher = PassthroughSubject<simd_float4x4, Never>()

    /// ARMeshAnchors from LiDAR scene reconstruction (available on Pro devices).
    let meshAnchorsPublisher = PassthroughSubject<[ARMeshAnchor], Never>()

    // MARK: - State

    @Published private(set) var isModelLoaded = false
    @Published private(set) var lastInferenceTimeMs: Double = 0
    @Published private(set) var isLiDARAvailable = false
    @Published private(set) var isMeshReconstructionAvailable = false

    // MARK: - Private

    private var arSession: ARSession?
    private let depthProcessingQueue = DispatchQueue(label: "com.blindnav.depth", qos: .userInitiated)
    private var cancellables = Set<AnyCancellable>()
    private var frameCounter = 0
    private var processEveryNFrames = 2  // LiDAR is fast - process every 2nd frame

    // Output grid size for depth data (portrait orientation after rotation)
    private let outputWidth = 192
    private let outputHeight = 256

    // MARK: - Init

    /// Configures with an externally provided ARSession (legacy SLAM mode).
    func configure(session: ARSession) {
        self.arSession = session

        // Check if LiDAR is available
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            isLiDARAvailable = true
            BNLog.depth.info("LiDAR depth estimation available")
        } else {
            BNLog.depth.warning("LiDAR not available on this device")
        }

        isModelLoaded = true  // No model to load
    }

    /// Configures with its own ARSession (standalone mode, no SLAM).
    func configureStandalone() {
        let session = ARSession()
        session.delegate = self
        self.arSession = session

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            isLiDARAvailable = true
            BNLog.depth.info("LiDAR depth estimation available (standalone)")
        } else {
            BNLog.depth.warning("LiDAR not available on this device")
        }

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            isMeshReconstructionAvailable = true
            BNLog.depth.info("LiDAR mesh reconstruction available")
        } else {
            BNLog.depth.info("Mesh reconstruction not available — falling back to depth-only")
        }

        isModelLoaded = true
    }

    /// Starts the standalone ARSession (call after configureStandalone).
    func start() {
        guard let arSession else {
            BNLog.depth.error("ARSession not configured. Call configureStandalone() first.")
            return
        }

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .none
        config.isAutoFocusEnabled = true

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics = .sceneDepth
        }

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            BNLog.depth.info("Scene mesh reconstruction enabled")
        }

        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        BNLog.depth.info("ARKit depth session started (standalone, mesh=\(self.isMeshReconstructionAvailable))")
    }

    /// Stops the standalone ARSession.
    func stop() {
        arSession?.pause()
        BNLog.depth.info("ARKit depth session paused")
    }

    // MARK: - Frame processing

    /// Called from ARSessionDelegate (standalone) with pre-extracted depth data.
    func processDepthFrame(depthBuffer: CVPixelBuffer, intrinsics: matrix_float3x3) {
        guard isLiDARAvailable else { return }

        frameCounter += 1
        guard frameCounter % processEveryNFrames == 0 else { return }

        let startTime = CFAbsoluteTimeGetCurrent()
        processDepthBuffer(depthBuffer, cameraIntrinsics: intrinsics, startTime: startTime)
    }

    /// Called externally when another service forwards ARFrames (legacy path).
    func sessionDidUpdateFrame(_ frame: ARFrame) {
        guard isLiDARAvailable else { return }

        var depthBuffer: CVPixelBuffer?
        if let sceneDepth = frame.sceneDepth {
            depthBuffer = sceneDepth.depthMap
        } else if let estimatedDepthData = frame.estimatedDepthData {
            depthBuffer = estimatedDepthData
        }

        guard let buffer = depthBuffer else { return }
        processDepthFrame(depthBuffer: buffer, intrinsics: frame.camera.intrinsics)
    }

    private func processDepthBuffer(_ depthBuffer: CVPixelBuffer, cameraIntrinsics: matrix_float3x3, startTime: Double) {
        depthProcessingQueue.async { [weak self] in
            guard let self else { return }

            let obstacleMap = self.convertDepthBufferToObstacleMap(
                depthBuffer,
                cameraIntrinsics: cameraIntrinsics
            )

            DispatchQueue.main.async {
                self.obstacleMapPublisher.send(obstacleMap)
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                self.lastInferenceTimeMs = elapsed
            }
        }
    }

    // MARK: - Convert depth buffer to ObstacleMap

    private func convertDepthBufferToObstacleMap(
        _ depthBuffer: CVPixelBuffer,
        cameraIntrinsics: matrix_float3x3
    ) -> ObstacleMap {
        CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly) }

        // LiDAR depth buffer is in landscape orientation (e.g., 256x192)
        let bufWidth = CVPixelBufferGetWidth(depthBuffer)
        let bufHeight = CVPixelBufferGetHeight(depthBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthBuffer) else {
            return ObstacleMap(depthGrid: [], gridWidth: 0, gridHeight: 0, timestamp: Date())
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthBuffer)
        let bufferPtr = baseAddress.assumingMemoryBound(to: Float32.self)

        // Rotate 90 degrees clockwise for portrait orientation:
        // output(outX, outY) maps to buffer(bufHeight - 1 - outY, outX) when rotated CW
        // After rotation: outputWidth = bufHeight, outputHeight = bufWidth
        var depthGrid: [[Float]] = []
        depthGrid.reserveCapacity(outputHeight)

        let xScale = Float(bufHeight) / Float(outputWidth)
        let yScale = Float(bufWidth) / Float(outputHeight)

        for outY in 0..<outputHeight {
            var row: [Float] = []
            row.reserveCapacity(outputWidth)

            for outX in 0..<outputWidth {
                // Map portrait output back to landscape buffer with 90-degree CW rotation
                let srcX = Int(Float(outY) * yScale)
                let srcY = bufHeight - 1 - Int(Float(outX) * xScale)

                guard srcY >= 0, srcY < bufHeight, srcX >= 0, srcX < bufWidth else {
                    row.append(0)
                    continue
                }

                let pixelIndex = srcY * bytesPerRow / MemoryLayout<Float32>.stride + srcX
                let depth = bufferPtr[pixelIndex]

                // Convert depth to inverse depth for consistency with ObstacleMap
                // Inverse depth: closer objects have higher values
                let inverseDepth: Float
                if depth > 0 && depth < 10 {  // Valid range: 0-10 meters
                    inverseDepth = 1.0 / max(depth, 0.1)  // Avoid division by zero
                } else {
                    inverseDepth = 0
                }

                row.append(inverseDepth)
            }

            depthGrid.append(row)
        }

        return ObstacleMap(
            depthGrid: depthGrid,
            gridWidth: outputWidth,
            gridHeight: outputHeight,
            timestamp: Date()
        )
    }

    // MARK: - Performance mode (no-op for LiDAR, already fast)

    func updatePerformanceMode(_ mode: BNConstants.PerformanceMode) {
        // LiDAR is fast - minimal throttling needed
        switch mode {
        case .balanced:
            self.processEveryNFrames = 2
        case .performance:
            self.processEveryNFrames = 1  // Every frame for maximum responsiveness
        case .battery:
            self.processEveryNFrames = 3
        }
        BNLog.depth.info("LiDAR depth frame skipping set to 1/\(self.processEveryNFrames) for \(mode.description)")
    }

    // MARK: - Calibration

    /// Scale factor for converting inverse depth to meters (for compatibility)
    var depthScaleFactor: Float = 1.0  // LiDAR provides actual metric depth
}

// MARK: - Frame gate (non-isolated, prevents ARFrame retention buildup)

private final class DepthFrameGate: Sendable {
    private let lock = NSLock()
    private let _busy = UnsafeMutablePointer<Bool>.allocate(capacity: 1)

    init() { _busy.initialize(to: false) }
    deinit { _busy.deallocate() }

    func tryEnter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _busy.pointee { return false }
        _busy.pointee = true
        return true
    }

    func leave() {
        lock.lock()
        _busy.pointee = false
        lock.unlock()
    }
}

// MARK: - ARSessionDelegate (standalone mode, no SLAM)

private let depthFrameGate = DepthFrameGate()
private let rgbFrameGate = DepthFrameGate()

extension DepthEstimationService: ARSessionDelegate {

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let capturedImage = frame.capturedImage
        let intrinsics = frame.camera.intrinsics
        let cameraTransform = frame.camera.transform

        // Publish camera transform for spatial audio listener positioning.
        Task { @MainActor in
            self.cameraTransformPublisher.send(cameraTransform)
        }

        // Publish RGB frame on a separate gate so it isn't blocked by slow depth processing.
        if rgbFrameGate.tryEnter() {
            if let copied = PixelBufferUtils.copyPixelBuffer(capturedImage) {
                Task { @MainActor in
                    self.capturedFramePublisher.send(copied)
                    rgbFrameGate.leave()
                }
            } else {
                rgbFrameGate.leave()
            }
        }

        // Depth processing with its own gate.
        guard depthFrameGate.tryEnter() else { return }

        guard let depthMap = frame.sceneDepth?.depthMap ?? frame.estimatedDepthData else {
            depthFrameGate.leave()
            return
        }

        Task { @MainActor in
            self.processDepthFrame(depthBuffer: depthMap, intrinsics: intrinsics)
            depthFrameGate.leave()
        }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        publishMeshAnchors(from: session)
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let hasMesh = anchors.contains { $0 is ARMeshAnchor }
        if hasMesh {
            publishMeshAnchors(from: session)
        }
    }

    private nonisolated func publishMeshAnchors(from session: ARSession) {
        let meshAnchors = session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        guard !meshAnchors.isEmpty else { return }
        Task { @MainActor in
            self.meshAnchorsPublisher.send(meshAnchors)
        }
    }
}
