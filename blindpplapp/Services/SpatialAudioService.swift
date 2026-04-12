import Foundation
import AVFoundation
import CoreMotion
import simd
import os
import Combine

// MARK: - 3D spatial audio engine with world-coordinate tracking and AirPods head tracking

@MainActor
final class SpatialAudioService: ObservableObject {

    // MARK: - State

    @Published private(set) var isRunning = false
    @Published private(set) var isHeadTrackingActive = false
    @Published private(set) var headTrackingSource: HeadTrackingSource = .phoneOrientation

    enum HeadTrackingSource: String {
        case airpodsHeadTracking = "AirPods Head Tracking"
        case phoneOrientation = "Phone Orientation"
    }

    // MARK: - Private

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()

    private var goalPlayerNode: AVAudioPlayerNode?
    private var obstaclePlayerNode: AVAudioPlayerNode?
    private var groundWarningPlayerNode: AVAudioPlayerNode?
    private var arrivalPlayerNode: AVAudioPlayerNode?

    /// World-positioned obstacle sources for mesh-based spatial audio.
    /// These get placed at actual 3D world coordinates of detected obstacles.
    private var worldObstacleNodes: [AVAudioPlayerNode] = []
    private let maxWorldObstacleNodes = 8

    private var goalToneBuffer: AVAudioPCMBuffer?
    private var obstacleToneBuffer: AVAudioPCMBuffer?
    private var groundWarningBuffer: AVAudioPCMBuffer?
    private var arrivalBuffer: AVAudioPCMBuffer?
    private var worldObstacleClickBuffer: AVAudioPCMBuffer?

    private var goalLoopTimer: Timer?
    private var currentGoalInterval: TimeInterval = 1.2
    private var goalLoopStarted = false

    private var isConfigured = false
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    /// Virtual radius for positioning audio sources on a sphere around the listener.
    private let sourceRadius: Float = 3.0

    // MARK: - World-coordinate listener tracking

    /// Latest camera transform from ARKit, used to position the listener in world space.
    private var currentCameraTransform: simd_float4x4 = matrix_identity_float4x4

    /// AirPods head pose relative to phone, used to decouple listener orientation from phone.
    private var headphoneAttitudeOffset: simd_quatf?

    // MARK: - CMHeadphoneMotionManager for AirPods Pro/Max head tracking

    private let headphoneMotionManager = CMHeadphoneMotionManager()

    // MARK: - Obstacle proximity zone sonification

    /// Each zone represents a spatial region (left, center, right) with its own click source.
    private struct ProximityZone {
        let playerNode: AVAudioPlayerNode
        var timer: Timer?
        var currentInterval: TimeInterval = 0
        var lastDistance: Float = 100
        var lateralOffset: Float = 0
    }

    private var proximityZones: [ProximityZone] = []
    private var proximityClickBuffers: [AVAudioPCMBuffer] = []

    /// Whether proximity sonification is actively running.
    private var isProximitySonificationActive = false

    // MARK: - Setup

    func configure() {
        BNLog.spatialAudio.info("Configuring spatial audio engine...")

        activateAudioSession()

        engine.attach(environment)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)

        if #available(iOS 18.0, *) {
            environment.isListenerHeadTrackingEnabled = false
        }
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.distanceAttenuationParameters.distanceAttenuationModel = .linear
        environment.distanceAttenuationParameters.referenceDistance = 0.5
        environment.distanceAttenuationParameters.maximumDistance = 10.0
        environment.distanceAttenuationParameters.rolloffFactor = 1.0

        goalPlayerNode = createPlayerNode()
        obstaclePlayerNode = createPlayerNode()
        groundWarningPlayerNode = createPlayerNode()
        arrivalPlayerNode = createPlayerNode()

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        goalToneBuffer = generateTone(frequency: 660, duration: 0.15, format: format)
        obstacleToneBuffer = generateTone(frequency: 220, duration: 0.3, format: format)
        groundWarningBuffer = generateTone(frequency: 440, duration: 0.25, format: format)
        arrivalBuffer = generateTone(frequency: 880, duration: 0.5, format: format)
        worldObstacleClickBuffer = generateClick(frequency: 200, duration: 0.06, format: format)

        configureProximityZones(format: format)
        configureWorldObstacleNodes()
        configureHeadphoneMotionTracking()

        isConfigured = true
        observeAudioSessionEvents()

        BNLog.spatialAudio.info("Spatial audio engine configured with HRTF, \(BNConstants.obstacleZoneCount)-zone proximity, \(self.maxWorldObstacleNodes) world obstacle nodes, head tracking=\(self.headphoneMotionManager.isDeviceMotionAvailable)")
    }

    func start() {
        guard !engine.isRunning else { return }
        activateAudioSession()
        do {
            engine.prepare()
            try engine.start()
            isRunning = true
            goalLoopStarted = false
            isProximitySonificationActive = true
            startHeadTracking()
            BNLog.spatialAudio.info("Spatial audio engine started")
        } catch {
            BNLog.spatialAudio.error("Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    func stop() {
        goalLoopTimer?.invalidate()
        goalLoopTimer = nil
        goalLoopStarted = false

        goalPlayerNode?.stop()
        obstaclePlayerNode?.stop()
        groundWarningPlayerNode?.stop()
        arrivalPlayerNode?.stop()

        stopAllWorldObstacleNodes()
        stopAllProximityZones()
        isProximitySonificationActive = false

        stopHeadTracking()

        engine.stop()
        isRunning = false
        BNLog.spatialAudio.info("Spatial audio engine stopped")
    }

    // MARK: - Audio session management

    private func activateAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true, options: [])
            BNLog.spatialAudio.info("Audio session activated")
        } catch {
            BNLog.spatialAudio.error("Audio session setup failed: \(error.localizedDescription)")
        }
    }

    func ensureRunning() {
        guard isRunning, !engine.isRunning else { return }
        BNLog.spatialAudio.warning("Engine was stopped externally — restarting")
        activateAudioSession()
        do {
            engine.prepare()
            try engine.start()
            BNLog.spatialAudio.info("Engine restarted successfully")
        } catch {
            BNLog.spatialAudio.error("Engine restart failed: \(error.localizedDescription)")
        }
    }

    private func observeAudioSessionEvents() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                guard let info = notification.userInfo,
                      let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

                if type == .ended {
                    BNLog.spatialAudio.info("Audio interruption ended — restarting engine")
                    self.ensureRunning()
                }
            }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                BNLog.spatialAudio.info("Audio route changed — ensuring engine is running")
                self.ensureRunning()
            }
        }
    }

    // MARK: - Azimuth-based positioning

    /// Converts a normalized lateral offset (-1 = hard left, 0 = center, +1 = hard right)
    /// into a 3D audio source position on a sphere around the listener.
    private func positionFromAzimuth(lateralOffset: Float, radius: Float? = nil) -> AVAudio3DPoint {
        let r = radius ?? sourceRadius
        let clampedOffset = max(-1.0, min(1.0, lateralOffset))
        let azimuthRadians = clampedOffset * (.pi / 2.0)
        let x = sin(azimuthRadians) * r
        let z = -cos(azimuthRadians) * r
        return AVAudio3DPoint(x: x, y: 0, z: z)
    }

    // MARK: - Directional cues

    /// Updates the goal guidance beep direction.
    func updateGoalDirection(lateralOffset: Float, distance: Float) {
        guard let node = goalPlayerNode else { return }
        ensureRunning()

        let pos = positionFromAzimuth(lateralOffset: lateralOffset)
        node.position = pos

        let clampedDist = max(0.5, min(distance, 10.0))
        let newInterval = TimeInterval(0.3 + (clampedDist / 10.0) * 0.9)

        if !goalLoopStarted || abs(newInterval - currentGoalInterval) > 0.1 {
            currentGoalInterval = newInterval
            goalLoopStarted = true
            restartGoalLoop()
        }
    }

    /// Legacy direction-vector API.
    func updateGoalDirection(_ direction: SIMD3<Float>, distance: Float) {
        let lateral = direction.x * 2.0
        updateGoalDirection(lateralOffset: lateral, distance: distance)
    }

    /// Plays a single obstacle warning from the obstacle's direction (for urgent/danger alerts).
    func playObstacleWarning(lateralOffset: Float, urgency: Float) {
        guard let node = obstaclePlayerNode, let buffer = obstacleToneBuffer, buffer.frameLength > 0 else {
            BNLog.spatialAudio.warning("Cannot play obstacle tone: node or buffer invalid")
            return
        }
        ensureRunning()

        let pos = positionFromAzimuth(lateralOffset: lateralOffset, radius: 2.0)
        node.position = pos
        node.volume = min(1.0, 0.3 + urgency * 0.7)

        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !node.isPlaying { node.play() }
    }

    /// Legacy direction-vector API for obstacle warnings.
    func playObstacleWarning(direction: SIMD3<Float>, urgency: Float) {
        let lateral = direction.x * 2.0
        playObstacleWarning(lateralOffset: lateral, urgency: urgency)
    }

    /// Plays ground boundary warning.
    func playGroundWarning(direction: SIMD3<Float>) {
        guard let node = groundWarningPlayerNode, let buffer = groundWarningBuffer, buffer.frameLength > 0 else {
            BNLog.spatialAudio.warning("Cannot play ground warning: node or buffer invalid")
            return
        }
        ensureRunning()

        let lateral = direction.x * 2.0
        let pos = positionFromAzimuth(lateralOffset: lateral, radius: 1.5)
        node.position = pos

        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !node.isPlaying { node.play() }
    }

    /// Plays arrival celebration tone (centered).
    func playArrivalTone() {
        guard let node = arrivalPlayerNode, let buffer = arrivalBuffer, buffer.frameLength > 0 else {
            BNLog.spatialAudio.warning("Cannot play arrival tone: node or buffer invalid")
            return
        }
        ensureRunning()

        node.position = AVAudio3DPoint(x: 0, y: 0.5, z: -1)
        node.volume = 0.8

        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !node.isPlaying { node.play() }
        BNLog.spatialAudio.info("Playing arrival tone")
    }

    /// Stops the goal guidance tone loop.
    func stopGoalTone() {
        goalLoopTimer?.invalidate()
        goalLoopTimer = nil
        goalLoopStarted = false
        goalPlayerNode?.stop()
    }

    // MARK: - World-coordinate listener update (called every ARKit frame)

    /// Updates the spatial audio listener position and orientation from the ARKit camera transform.
    /// This makes all spatialized audio sources feel "locked" to real-world positions.
    func updateListenerFromCameraTransform(_ transform: simd_float4x4) {
        currentCameraTransform = transform

        let position = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        environment.listenerPosition = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)

        // Derive listener orientation from the camera (or headphone if available)
        var forward: SIMD3<Float>
        var up: SIMD3<Float>

        if let headAttitude = headphoneAttitudeOffset, isHeadTrackingActive {
            // AirPods head tracking: combine camera world pose with head rotation offset.
            // This decouples audio orientation from phone orientation — audio stays
            // locked to world positions even as the user turns their head.
            let cameraRotation = simd_quatf(transform)
            let worldHeadOrientation = cameraRotation * headAttitude

            let rotMatrix = simd_float3x3(worldHeadOrientation)
            forward = -rotMatrix.columns.2
            up = rotMatrix.columns.1
        } else {
            forward = SIMD3<Float>(
                -transform.columns.2.x,
                -transform.columns.2.y,
                -transform.columns.2.z
            )
            up = SIMD3<Float>(
                transform.columns.1.x,
                transform.columns.1.y,
                transform.columns.1.z
            )
        }

        environment.listenerVectorOrientation = AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: forward.x, y: forward.y, z: forward.z),
            up: AVAudio3DVector(x: up.x, y: up.y, z: up.z)
        )
    }

    // MARK: - Mesh-based world-position obstacle audio

    /// Places spatial click sources at the world coordinates of nearby obstacles
    /// detected via LiDAR mesh reconstruction. Each obstacle gets its own audio source
    /// positioned at its real 3D location — as the user moves or turns, the audio
    /// naturally pans and attenuates.
    func updateWorldObstacles(_ obstacles: [MeshObstacle]) {
        guard isRunning else { return }
        ensureRunning()

        let awarenessRange = BNConstants.obstacleAwarenessRange

        for (i, node) in worldObstacleNodes.enumerated() {
            if i < obstacles.count {
                let obstacle = obstacles[i]

                guard obstacle.distance < awarenessRange else {
                    node.volume = 0
                    continue
                }

                // Place audio source at exact world coordinate
                node.position = AVAudio3DPoint(
                    x: obstacle.worldPosition.x,
                    y: obstacle.worldPosition.y,
                    z: obstacle.worldPosition.z
                )

                // Volume and rate scale with proximity
                let normalized = max(0, (obstacle.distance - 0.2) / (awarenessRange - 0.2))
                node.volume = 0.15 + (1.0 - normalized) * 0.65

                if let buffer = worldObstacleClickBuffer, buffer.frameLength > 0, !node.isPlaying {
                    node.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
                    node.play()
                }
            } else {
                node.volume = 0
                if node.isPlaying { node.stop() }
            }
        }
    }

    /// Plays a one-shot spatial warning at an exact world position (for urgent mesh-based alerts).
    func playWorldPositionWarning(at worldPosition: SIMD3<Float>, urgency: Float) {
        guard let node = obstaclePlayerNode, let buffer = obstacleToneBuffer,
              buffer.frameLength > 0 else { return }
        ensureRunning()

        node.position = AVAudio3DPoint(x: worldPosition.x, y: worldPosition.y, z: worldPosition.z)
        node.volume = min(1.0, 0.3 + urgency * 0.7)
        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !node.isPlaying { node.play() }
    }

    // MARK: - Obstacle proximity zone sonification

    /// Updates the continuous proximity sonification for all obstacle zones.
    /// Each zone entry contains a lateral position and the closest obstacle distance in meters.
    /// Zones within awareness range produce spatial clicks; click rate scales with proximity.
    func updateObstacleProximityZones(_ zones: [ObstacleMap.ObstacleZoneInfo]) {
        guard isProximitySonificationActive else { return }
        ensureRunning()

        for zoneInfo in zones {
            guard zoneInfo.index < proximityZones.count else { continue }

            let distance = zoneInfo.closestDistanceMeters
            let lateral = zoneInfo.lateralOffset
            let awarenessRange = BNConstants.obstacleAwarenessRange

            proximityZones[zoneInfo.index].lateralOffset = lateral
            proximityZones[zoneInfo.index].lastDistance = distance

            let pos = positionFromAzimuth(lateralOffset: lateral, radius: 2.0)
            proximityZones[zoneInfo.index].playerNode.position = pos

            if distance > awarenessRange {
                if proximityZones[zoneInfo.index].timer != nil {
                    proximityZones[zoneInfo.index].timer?.invalidate()
                    proximityZones[zoneInfo.index].timer = nil
                    proximityZones[zoneInfo.index].currentInterval = 0
                }
                continue
            }

            let newInterval = clickIntervalForDistance(distance, maxRange: awarenessRange)
            let volumeForDistance = clickVolumeForDistance(distance, maxRange: awarenessRange)
            proximityZones[zoneInfo.index].playerNode.volume = volumeForDistance

            let currentInterval = proximityZones[zoneInfo.index].currentInterval
            if currentInterval == 0 || abs(newInterval - currentInterval) > 0.03 {
                proximityZones[zoneInfo.index].currentInterval = newInterval
                restartProximityZoneTimer(at: zoneInfo.index, interval: newInterval)
            }
        }
    }

    // MARK: - Proximity zone internals

    private func configureProximityZones(format: AVAudioFormat) {
        let zoneCount = BNConstants.obstacleZoneCount

        proximityClickBuffers = [
            generateClick(frequency: 180, duration: 0.04, format: format),
            generateClick(frequency: 250, duration: 0.04, format: format),
            generateClick(frequency: 320, duration: 0.04, format: format),
        ].compactMap { $0 }

        if proximityClickBuffers.isEmpty {
            BNLog.spatialAudio.error("Failed to generate proximity click buffers")
            return
        }

        for i in 0..<zoneCount {
            let node = createPlayerNode()
            node.volume = 0
            let zone = ProximityZone(
                playerNode: node,
                timer: nil,
                currentInterval: 0,
                lastDistance: 100,
                lateralOffset: Float(i) / Float(zoneCount - 1) * 2.0 - 1.0
            )
            proximityZones.append(zone)
        }

        BNLog.spatialAudio.info("Configured \(zoneCount) obstacle proximity zones")
    }

    /// Maps obstacle distance to click interval.
    /// Closer obstacles -> faster clicking (like a parking sensor).
    private func clickIntervalForDistance(_ distance: Float, maxRange: Float) -> TimeInterval {
        let clamped = max(0.2, min(distance, maxRange))
        let normalized = (clamped - 0.2) / (maxRange - 0.2)  // 0 = very close, 1 = far

        // Exponential curve: very fast when close, slows down with distance
        // 0.08s at closest -> 0.7s at max range
        return TimeInterval(0.08 + pow(normalized, 1.5) * 0.62)
    }

    /// Maps obstacle distance to click volume.
    private func clickVolumeForDistance(_ distance: Float, maxRange: Float) -> Float {
        let clamped = max(0.2, min(distance, maxRange))
        let normalized = (clamped - 0.2) / (maxRange - 0.2)

        // Louder when closer: 0.9 at closest, 0.15 at max range
        return 0.15 + (1.0 - normalized) * 0.75
    }

    private func restartProximityZoneTimer(at index: Int, interval: TimeInterval) {
        guard index < proximityZones.count else { return }
        proximityZones[index].timer?.invalidate()

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.playProximityClick(zoneIndex: index)
        }
        proximityZones[index].timer = timer

        playProximityClick(zoneIndex: index)
    }

    private func playProximityClick(zoneIndex: Int) {
        guard zoneIndex < proximityZones.count else { return }
        let zone = proximityZones[zoneIndex]
        let bufferIndex = min(zoneIndex, proximityClickBuffers.count - 1)
        guard bufferIndex >= 0, bufferIndex < proximityClickBuffers.count else { return }
        let buffer = proximityClickBuffers[bufferIndex]
        guard buffer.frameLength > 0 else { return }

        zone.playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !zone.playerNode.isPlaying {
            zone.playerNode.play()
        }
    }

    private func stopAllProximityZones() {
        for i in 0..<proximityZones.count {
            proximityZones[i].timer?.invalidate()
            proximityZones[i].timer = nil
            proximityZones[i].currentInterval = 0
            proximityZones[i].playerNode.stop()
        }
    }

    // MARK: - Private helpers

    private func createPlayerNode() -> AVAudioPlayerNode {
        let node = AVAudioPlayerNode()
        engine.attach(node)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)
        engine.connect(node, to: environment, format: format)
        node.renderingAlgorithm = .HRTFHQ
        node.sourceMode = .pointSource
        node.reverbBlend = 0
        return node
    }

    private func restartGoalLoop() {
        goalLoopTimer?.invalidate()
        goalLoopTimer = Timer.scheduledTimer(withTimeInterval: currentGoalInterval, repeats: true) { [weak self] _ in
            self?.playGoalBeep()
        }
    }

    private func playGoalBeep() {
        guard let node = goalPlayerNode, let buffer = goalToneBuffer, buffer.frameLength > 0 else {
            return
        }
        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !node.isPlaying {
            node.play()
        }
    }

    private func generateTone(frequency: Double, duration: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(sampleRate * duration)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            BNLog.spatialAudio.error("Failed to create PCM buffer for tone at \(frequency)Hz")
            return nil
        }
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData?[0] else {
            BNLog.spatialAudio.error("Failed to get channel data for tone at \(frequency)Hz")
            return nil
        }

        guard frameCount > 0 else {
            BNLog.spatialAudio.error("Invalid frame count for tone at \(frequency)Hz")
            return nil
        }

        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let envelope = min(t / 0.01, 1.0) * min((duration - t) / 0.01, 1.0)
            channelData[i] = Float(sin(2.0 * .pi * frequency * t) * envelope * 0.5)
        }

        guard buffer.frameLength > 0 else {
            BNLog.spatialAudio.error("Generated buffer has zero frame length for tone at \(frequency)Hz")
            return nil
        }

        BNLog.spatialAudio.debug("Generated tone: \(frequency)Hz, \(Int(frameCount)) frames")
        return buffer
    }

    /// Generates a short percussive click for proximity sonification.
    /// Distinct from the melodic goal beep -- uses a sharp attack/decay with harmonics.
    private func generateClick(frequency: Double, duration: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard frameCount > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData?[0] else { return nil }

        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let envelope = exp(-t * 60.0)
            let fundamental = sin(2.0 * .pi * frequency * t)
            let harmonic2 = sin(2.0 * .pi * frequency * 2.0 * t) * 0.4
            let harmonic3 = sin(2.0 * .pi * frequency * 3.0 * t) * 0.15
            channelData[i] = Float((fundamental + harmonic2 + harmonic3) * envelope * 0.45)
        }

        return buffer
    }

    // MARK: - World obstacle node pool

    private func configureWorldObstacleNodes() {
        for _ in 0..<maxWorldObstacleNodes {
            let node = createPlayerNode()
            node.volume = 0
            worldObstacleNodes.append(node)
        }
        BNLog.spatialAudio.info("Configured \(self.maxWorldObstacleNodes) world-positioned obstacle audio nodes")
    }

    private func stopAllWorldObstacleNodes() {
        for node in worldObstacleNodes {
            node.stop()
            node.volume = 0
        }
    }

    // MARK: - CMHeadphoneMotionManager (AirPods Pro/Max head tracking)

    private func configureHeadphoneMotionTracking() {
        guard CMHeadphoneMotionManager.authorizationStatus() != .denied else {
            BNLog.spatialAudio.warning("Headphone motion permission denied")
            return
        }

        guard headphoneMotionManager.isDeviceMotionAvailable else {
            BNLog.spatialAudio.info("Headphone motion not available — using phone orientation for spatial audio")
            return
        }

        BNLog.spatialAudio.info("CMHeadphoneMotionManager available — will activate on start")
    }

    private func startHeadTracking() {
        guard headphoneMotionManager.isDeviceMotionAvailable else {
            headTrackingSource = .phoneOrientation
            return
        }

        headphoneMotionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    BNLog.spatialAudio.error("Headphone motion error: \(error.localizedDescription)")
                    self.isHeadTrackingActive = false
                    self.headTrackingSource = .phoneOrientation
                    self.headphoneAttitudeOffset = nil
                    return
                }

                guard let motion else { return }

                if !self.isHeadTrackingActive {
                    self.isHeadTrackingActive = true
                    self.headTrackingSource = .airpodsHeadTracking
                    BNLog.spatialAudio.info("AirPods head tracking activated — spatial audio locked to world")
                }

                // Convert CMAttitude quaternion to simd
                let q = motion.attitude.quaternion
                self.headphoneAttitudeOffset = simd_quatf(
                    ix: Float(q.x),
                    iy: Float(q.y),
                    iz: Float(q.z),
                    r: Float(q.w)
                )
            }
        }
    }

    private func stopHeadTracking() {
        headphoneMotionManager.stopDeviceMotionUpdates()
        isHeadTrackingActive = false
        headTrackingSource = .phoneOrientation
        headphoneAttitudeOffset = nil
        BNLog.spatialAudio.info("Head tracking stopped")
    }
}
