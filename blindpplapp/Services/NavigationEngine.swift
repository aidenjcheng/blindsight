import Foundation
import ARKit
import Combine
import UIKit
import simd
import os

// MARK: - Core orchestrator: wires all services together and drives the navigation state machine

@MainActor
final class NavigationEngine: ObservableObject {

    // MARK: - Services (injected)

    let cameraService: CameraService
    let depthService: DepthEstimationService
    let yoloeService: YOLOEService
    let geminiService: GeminiService
    // SLAM disabled
    // let slamService: SLAMService
    let spatialAudioService: SpatialAudioService
    let speechService: SpeechService
    let hapticService: HapticService
    let voiceCommandService: VoiceCommandService

    /// Processes ARKit mesh anchors into world-space obstacle positions for spatial audio.
    private let meshObstacleProcessor = MeshObstacleProcessor()

    // MARK: - State

    private weak var appState: AppState?
    private var cancellables = Set<AnyCancellable>()

    /// Storage for external Combine subscriptions (e.g., from views)
    var cancellableStorage = Set<AnyCancellable>()

    // Latest sensor data from the continuous pipeline
    private var latestObstacleMap: ObstacleMap?
    private var latestSnapshot: Data?

    // Gemini call management
    private var geminiCallTask: Task<Void, Never>?
    private var heartbeatTimer: Timer?
    private var isGeminiCallInFlight = false

    // Safety state
    private var consecutiveDangerFrames = 0
    private let dangerFrameThreshold = 3

    // Obstacle-aware guidance: latest raw goal lateral offset from YOLOE (-1..+1)
    private var latestGoalLateralOffset: Float = 0
    private var latestGoalDistance: Float = 5.0
    private var hasActiveGoalTracking = false
    private var latestSectorClearances: [ObstacleMap.SectorClearance] = []

    /// Minimum clear distance (meters) for a sector to be considered passable.
    /// Uses the obstacle avoidance range so steering begins well before collision.
    private var sectorClearThreshold: Float { BNConstants.obstacleAvoidanceRange }

    // Avoidance announcement state
    private var isCurrentlyAvoiding = false
    private var lastAvoidanceAnnouncementTime: Date?
    private var lastObstacleDescriptionTime: Date?

    // ARKit world tracking state
    private var latestCameraTransform: simd_float4x4 = matrix_identity_float4x4

    // MARK: - Init

    init(appState: AppState) {
        self.appState = appState

        self.cameraService = CameraService()
        self.depthService = DepthEstimationService()
        self.yoloeService = YOLOEService()
        self.geminiService = GeminiService()
        // SLAM disabled
        // self.slamService = SLAMService()
        self.spatialAudioService = SpatialAudioService()
        self.speechService = SpeechService()
        self.hapticService = HapticService()
        self.voiceCommandService = VoiceCommandService()

        BNLog.navigation.info("NavigationEngine initialized")
    }

    // MARK: - Bootstrap: load models and configure all services

    func updatePerformanceMode(_ mode: BNConstants.PerformanceMode) {
        yoloeService.updatePerformanceMode(mode)
        depthService.updatePerformanceMode(mode)
        BNLog.navigation.info("Performance mode updated to: \(mode.description)")
    }

    func bootstrap() {
        BNLog.navigation.info("Bootstrapping all services...")

        // Configure services
        cameraService.configure()
        // SLAM disabled — depth service manages its own ARSession
        depthService.configureStandalone()
        spatialAudioService.configure()
        hapticService.configure()

        let apiKey = appState?.geminiAPIKey ?? ""
        let effectiveKey = apiKey.isEmpty ? BNConstants.hardcodedGeminiAPIKey : apiKey
        if !effectiveKey.isEmpty {
            geminiService.configure(apiKey: effectiveKey)
        }

        if let speed = appState?.voiceSpeed {
            speechService.configure(speechRate: Float(speed))
        }

        // SLAM disabled
        // yoloeService.setSLAMService(slamService)

        // Load ML models (depth uses LiDAR, no model needed)
        // depthService.loadModel()  // No model needed for LiDAR
        yoloeService.loadModel()

        // ARSession delivers frames in landscape sensor orientation — tell CameraService
        // to rotate to portrait for display and Vision requests.
        cameraService.imageOrientation = .right
        cameraService.visionOrientation = .right

        // Subscribe YOLOE to camera frames (with matching orientation)
        yoloeService.bufferOrientation = cameraService.visionOrientation
        yoloeService.subscribe(to: cameraService.framePublisher)

        // Subscribe to ML outputs for the navigation loop
        bindPipelineOutputs()

        // Subscribe to first snapshot availability
        cameraService.$hasFirstSnapshot
            .filter { $0 }
            .first()
            .sink { [weak self] _ in
                guard let self else { return }
                BNLog.navigation.info("First snapshot captured, ready for Gemini calls")
            }
            .store(in: &cancellables)

        BNLog.navigation.info("All services bootstrapped (LiDAR depth enabled)")
    }

    // MARK: - Start navigation

    func start(destination: String) {
        BNLog.navigation.info("=== NAVIGATION START: '\(destination)' ===")

        // Start ARKit depth session (also provides RGB frames via capturedFramePublisher).
        // NOTE: AVCaptureSession is NOT started — ARKit takes exclusive camera ownership,
        // so RGB frames are sourced from ARFrame.capturedImage instead.
        depthService.start()
        spatialAudioService.start()

        speechService.speak("Starting navigation to \(destination). Please hold still for a moment while I analyze your surroundings.", priority: .normal)

        // Wait for first snapshot before calling Gemini
        cameraService.$hasFirstSnapshot
            .filter { $0 }
            .first()
            .sink { [weak self] _ in
                self?.requestGeminiGuidance(status: "Navigation just started. This is the first request.")
            }
            .store(in: &cancellables)

        // Start the heartbeat timer for periodic Gemini re-checks
        startHeartbeatTimer()

        // Start continuous voice command listening
        voiceCommandService.startListening()
        appState?.isVoiceCommandListening = true
    }

    // MARK: - Stop navigation

    func stop() {
        BNLog.navigation.info("=== NAVIGATION STOP ===")

        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        geminiCallTask?.cancel()

        depthService.stop()
        spatialAudioService.stop()
        yoloeService.clearSecondaryGoal()

        consecutiveDangerFrames = 0
        hasActiveGoalTracking = false
        latestGoalLateralOffset = 0
        latestGoalDistance = 5.0
        latestSectorClearances = []
        isCurrentlyAvoiding = false
        lastAvoidanceAnnouncementTime = nil
        lastObstacleDescriptionTime = nil
        appState?.session.safetyAlert = .clear
        appState?.session.currentSecondaryGoal = nil

        // Stop voice command listening
        voiceCommandService.stopListening()
        appState?.isVoiceCommandListening = false
        appState?.isVoiceCommandProcessing = false
        appState?.lastVoiceCommand = ""

        speechService.speak("Navigation stopped.", priority: .normal)
    }

    // MARK: - Pipeline bindings

    private func bindPipelineOutputs() {
        // Depth → obstacle avoidance
        depthService.obstacleMapPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] map in
                self?.latestObstacleMap = map
                self?.processObstacleMap(map)
            }
            .store(in: &cancellables)

        // YOLOE secondary goal updates → spatial audio + goal lifecycle
        yoloeService.secondaryGoalDetectionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracked in
                self?.processSecondaryGoalUpdate(tracked)
            }
            .store(in: &cancellables)

        // ARSession RGB frames → camera service processing pipeline
        // AVCaptureSession gets interrupted when ARKit takes exclusive camera ownership,
        // so we source RGB frames from the ARSession instead.
        depthService.capturedFramePublisher
            .sink { [weak self] pixelBuffer in
                self?.cameraService.processExternalFrame(pixelBuffer)
            }
            .store(in: &cancellables)

        // Camera snapshots → store for Gemini API
        cameraService.snapshotPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                self?.latestSnapshot = data
            }
            .store(in: &cancellables)

        // ARKit camera transform → spatial audio listener positioning
        depthService.cameraTransformPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transform in
                self?.spatialAudioService.updateListenerFromCameraTransform(transform)
                self?.latestCameraTransform = transform
            }
            .store(in: &cancellables)

        // ARKit mesh anchors → world-position obstacle spatial audio
        depthService.meshAnchorsPublisher
            .receive(on: DispatchQueue.main)
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] anchors in
                self?.processMeshAnchorsForSpatialAudio(anchors)
            }
            .store(in: &cancellables)

        // SLAM circle detection disabled
        // slamService.$isCircling
        //     .removeDuplicates()
        //     .sink { [weak self] isCircling in
        //         guard let self, let appState = self.appState else { return }
        //         appState.session.isCircleDetected = isCircling
        //         if isCircling {
        //             BNLog.navigation.warning("Circle detected — will inform Gemini on next call")
        //             self.requestGeminiGuidance(status: "User is going in circles. Need a new direction.")
        //         }
        //     }
        //     .store(in: &cancellables)

        // Voice commands → Gemini with user's question
        voiceCommandService.commandPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] command in
                self?.handleVoiceCommand(command)
            }
            .store(in: &cancellables)

        BNLog.navigation.info("Pipeline outputs bound (SLAM disabled)")
    }

    // MARK: - Obstacle processing (SAFETY PRIORITY 1)

    private func processObstacleMap(_ map: ObstacleMap) {
        guard appState?.session.phase == .navigating || appState?.session.phase == .planning else { return }
        guard spatialAudioService.isRunning else { return }

        // Feed multi-zone obstacle proximity data to the spatial audio engine.
        // This produces continuous spatial clicks so users can "hear" obstacles around them.
        let obstacleZones = map.obstacleZones(
            numZones: BNConstants.obstacleZoneCount,
            scaleFactor: depthService.depthScaleFactor
        )
        spatialAudioService.updateObstacleProximityZones(obstacleZones)

        // Build sector clearance map for avoidance steering
        let sectors = map.sectorClearances(numSectors: 9, scaleFactor: depthService.depthScaleFactor)
        latestSectorClearances = sectors

        // Compute obstacle-aware guidance direction and update the goal beep
        if hasActiveGoalTracking {
            let guidanceLateral = computeGuidanceLateralOffset(
                goalLateral: latestGoalLateralOffset,
                sectors: sectors
            )
            spatialAudioService.updateGoalDirection(lateralOffset: guidanceLateral, distance: latestGoalDistance)

            let avoidanceDelta = abs(guidanceLateral - latestGoalLateralOffset)
            if avoidanceDelta > 0.2 {
                if !isCurrentlyAvoiding {
                    isCurrentlyAvoiding = true
                    announceAvoidanceDirection(guidanceLateral: guidanceLateral, zones: obstacleZones)
                } else if let lastTime = lastAvoidanceAnnouncementTime,
                          Date().timeIntervalSince(lastTime) > 3.0 {
                    announceAvoidanceDirection(guidanceLateral: guidanceLateral, zones: obstacleZones)
                }
            } else if isCurrentlyAvoiding {
                isCurrentlyAvoiding = false
                lastAvoidanceAnnouncementTime = Date()
                speechService.speak("Path ahead is clear.", priority: .low)
            }
        }

        // Safety warnings for the closest obstacle in the walking cone
        guard let closest = closest else {
            consecutiveDangerFrames = 0
            appState?.session.safetyAlert = .clear
            return
        }

        let distanceMeters = ObstacleMap.approximateDistance(
            inverseDepth: closest.depth,
            scaleFactor: depthService.depthScaleFactor
        )

        let obstacleLateral = (closest.normalizedX - 0.5) * 2.0
        let direction = SIMD3<Float>(closest.normalizedX - 0.5, 0, -1.0)
        let dangerDist = Float(appState?.dangerDistance ?? Double(BNConstants.dangerDistanceMeters))
        let warningDist = Float(appState?.warningDistance ?? Double(BNConstants.warningDistanceMeters))

        if distanceMeters < dangerDist {
            consecutiveDangerFrames += 1
            if consecutiveDangerFrames >= dangerFrameThreshold {
                appState?.session.safetyAlert = .danger(direction: direction, distanceMeters: distanceMeters)
                hapticService.play(.obstacleDanger)
                spatialAudioService.playObstacleWarning(lateralOffset: obstacleLateral, urgency: 1.0)
                let dirWord = obstacleLateral < -0.2 ? "to your left" : (obstacleLateral > 0.2 ? "to your right" : "directly ahead")
                speechService.speak("Stop! Obstacle \(dirWord), less than a meter away.", priority: .urgent)
            }
        } else if distanceMeters < warningDist {
            consecutiveDangerFrames = 0
            appState?.session.safetyAlert = .caution(direction: direction, distanceMeters: distanceMeters)
            let urgency = 1.0 - ((distanceMeters - dangerDist) / (warningDist - dangerDist))
            spatialAudioService.playObstacleWarning(lateralOffset: obstacleLateral, urgency: urgency)
            hapticService.play(.obstacleWarning)

            describeNearbyObstacle(distance: distanceMeters, lateral: obstacleLateral)
        } else {
            consecutiveDangerFrames = 0
            appState?.session.safetyAlert = .clear
        }
    }

    /// Periodically describes nearby obstacles so the user knows what's around them.
    private func describeNearbyObstacle(distance: Float, lateral: Float) {
        let now = Date()
        if let lastTime = lastObstacleDescriptionTime, now.timeIntervalSince(lastTime) < 4.0 {
            return
        }
        lastObstacleDescriptionTime = now

        let distStr = String(format: "%.1f", distance)
        let dirWord: String
        if lateral < -0.3 { dirWord = "on your left" }
        else if lateral > 0.3 { dirWord = "on your right" }
        else { dirWord = "ahead" }

        speechService.speak("Obstacle \(dirWord), \(distStr) meters.", priority: .normal)
    }

    // MARK: - Mesh-based spatial obstacle processing

    /// Processes ARKit mesh anchors to extract world-position obstacles and feed them
    /// to the spatial audio engine for true 3D sonification. This runs alongside the
    /// depth-buffer-based proximity system as a higher-fidelity overlay on LiDAR devices.
    private func processMeshAnchorsForSpatialAudio(_ anchors: [ARMeshAnchor]) {
        guard appState?.session.phase == .navigating || appState?.session.phase == .planning else { return }
        guard spatialAudioService.isRunning else { return }

        let obstacles = meshObstacleProcessor.findNearbyObstacles(
            meshAnchors: anchors,
            cameraTransform: latestCameraTransform,
            maxResults: 8
        )

        spatialAudioService.updateWorldObstacles(obstacles)

        // Check for very close mesh obstacles that need urgent speech warning
        if let closest = obstacles.first, closest.distance < Float(appState?.dangerDistance ?? Double(BNConstants.dangerDistanceMeters)) {
            let cameraPos = SIMD3<Float>(
                latestCameraTransform.columns.3.x,
                latestCameraTransform.columns.3.y,
                latestCameraTransform.columns.3.z
            )
            let cameraRight = SIMD3<Float>(
                latestCameraTransform.columns.0.x,
                latestCameraTransform.columns.0.y,
                latestCameraTransform.columns.0.z
            )
            let toObstacle = closest.worldPosition - cameraPos
            let lateral = dot(normalize(toObstacle), normalize(cameraRight))

            spatialAudioService.playWorldPositionWarning(
                at: closest.worldPosition,
                urgency: 1.0
            )
            hapticService.play(.obstacleDanger)

            let dirWord: String
            if lateral < -0.3 { dirWord = "to your left" }
            else if lateral > 0.3 { dirWord = "to your right" }
            else { dirWord = "directly ahead" }

            let distStr = String(format: "%.1f", closest.distance)
            speechService.speak("Wall \(dirWord), \(distStr) meters.", priority: .urgent)
        }
    }

    // MARK: - Obstacle-aware guidance direction

    /// Given the raw goal lateral offset and the sector clearance map, computes
    /// an adjusted lateral offset that steers the user around obstacles toward the goal.
    private func computeGuidanceLateralOffset(
        goalLateral: Float,
        sectors: [ObstacleMap.SectorClearance]
    ) -> Float {
        guard !sectors.isEmpty else { return goalLateral }

        let numSectors = sectors.count

        // Map goalLateral (-1..+1) to a sector index
        let goalNormX = (goalLateral + 1.0) / 2.0  // 0..1
        let goalSectorIdx = min(numSectors - 1, max(0, Int(goalNormX * Float(numSectors))))

        // If the goal sector is clear, go directly toward the goal
        if sectors[goalSectorIdx].minDistanceMeters > sectorClearThreshold {
            return goalLateral
        }

        // Goal sector is blocked — search outward for the nearest clear sector,
        // preferring the side closer to the goal direction
        var bestOffset: Int?
        for offset in 1..<numSectors {
            let leftIdx = goalSectorIdx - offset
            let rightIdx = goalSectorIdx + offset

            let leftClear = leftIdx >= 0 && sectors[leftIdx].minDistanceMeters > sectorClearThreshold
            let rightClear = rightIdx < numSectors && sectors[rightIdx].minDistanceMeters > sectorClearThreshold

            if leftClear && rightClear {
                // Both sides have openings — pick the one that keeps us closer to the goal
                bestOffset = (goalLateral <= 0) ? -offset : offset
                break
            } else if leftClear {
                bestOffset = -offset
                break
            } else if rightClear {
                bestOffset = offset
                break
            }
        }

        guard let offset = bestOffset else {
            // Everything is blocked; fall back to the most open sector
            if let bestSector = sectors.max(by: { $0.minDistanceMeters < $1.minDistanceMeters }) {
                return (bestSector.normalizedCenterX - 0.5) * 2.0
            }
            return goalLateral
        }

        let guidanceSectorIdx = goalSectorIdx + offset
        let guidanceNormX = sectors[guidanceSectorIdx].normalizedCenterX
        return (guidanceNormX - 0.5) * 2.0
    }

    // MARK: - Secondary goal tracking

    private func processSecondaryGoalUpdate(_ tracked: YOLOEService.TrackedInstance?) {
        guard appState?.session.phase == .navigating else { return }
        guard let tracked else {
            hasActiveGoalTracking = false
            return
        }

        if tracked.isVisible, let detection = tracked.lastDetection {
            let boxArea = Float(detection.boundingBox.width * detection.boundingBox.height)
            if boxArea >= BNConstants.goalReachedBoxAreaThreshold {
                BNLog.navigation.info("Goal '\(tracked.descriptor)' fills \(String(format: "%.0f%%", boxArea * 100)) of frame — treating as reached")
                hasActiveGoalTracking = false
                onSecondaryGoalReached()
                return
            }

            if let direction = yoloeService.directionToInstance(tracked),
               let distance = yoloeService.distanceToInstance(tracked) {

                // Store the raw goal lateral offset for obstacle-aware guidance.
                // direction.x is in roughly -0.5..+0.5 range; scale to -1..+1.
                latestGoalLateralOffset = direction.x * 2.0
                latestGoalDistance = distance
                hasActiveGoalTracking = true

                // Compute obstacle-aware guidance direction using latest sector data
                let guidanceLateral = computeGuidanceLateralOffset(
                    goalLateral: latestGoalLateralOffset,
                    sectors: latestSectorClearances
                )
                spatialAudioService.updateGoalDirection(lateralOffset: guidanceLateral, distance: distance)

                appState?.session.estimatedDistanceToGoal = distance
                appState?.session.currentSecondaryGoal?.lastEstimatedDistance = distance

                if distance < BNConstants.goalReachedDistanceMeters {
                    hasActiveGoalTracking = false
                    onSecondaryGoalReached()
                    return
                }
            }

            appState?.session.secondaryGoalLostSince = nil
            appState?.session.currentSecondaryGoal?.isCurrentlyTracked = true
            appState?.session.currentSecondaryGoal?.leftFrameTime = nil
        } else {
            if let goal = appState?.session.currentSecondaryGoal {
                if goal.leftFrameTime == nil {
                    appState?.session.currentSecondaryGoal?.leftFrameTime = Date()
                    appState?.session.secondaryGoalLostSince = Date()
                }

                if let lastDist = goal.lastEstimatedDistance,
                   lastDist < BNConstants.goalCloseEnoughToAssumeReached {
                    BNLog.navigation.info("Goal '\(tracked.descriptor)' was \(String(format: "%.1f", lastDist))m away and left frame — treating as reached")
                    hasActiveGoalTracking = false
                    onSecondaryGoalReached()
                    return
                }

                if let lostSince = appState?.session.secondaryGoalLostSince,
                   Date().timeIntervalSince(lostSince) > BNConstants.goalLostRecallDelay {
                    BNLog.navigation.warning("Secondary goal lost for >\(BNConstants.goalLostRecallDelay)s — re-calling Gemini")
                    requestGeminiGuidance(status: "Secondary goal '\(tracked.descriptor)' has been lost from view for too long.")
                    appState?.session.secondaryGoalLostSince = nil
                }
            }
        }
    }

    // MARK: - Goal lifecycle

    private func onSecondaryGoalReached() {
        guard let goal = appState?.session.currentSecondaryGoal else { return }

        BNLog.navigation.info("Secondary goal reached: '\(goal.descriptor)'")
        hasActiveGoalTracking = false
        latestGoalLateralOffset = 0
        isCurrentlyAvoiding = false
        hapticService.play(.goalReached)
        spatialAudioService.playArrivalTone()
        spatialAudioService.stopGoalTone()

        appState?.session.completedSecondaryGoals.append(goal.descriptor)
        speechService.speak("Waypoint reached. Looking for the next landmark.", priority: .normal)

        // Request next goal from Gemini
        requestGeminiGuidance(status: "Successfully reached waypoint: '\(goal.descriptor)'. Need next waypoint.")
    }

    private func onFinalDestinationReached() {
        let dest = appState?.session.destination ?? "destination"
        BNLog.navigation.info("=== FINAL DESTINATION REACHED: '\(dest)' ===")

        hapticService.play(.arrived)
        spatialAudioService.playArrivalTone()
        spatialAudioService.stopGoalTone()

        appState?.updatePhase(.arrived)
        appState?.updateStatus("You have arrived at the \(dest)!")
        speechService.speak("You have arrived at the \(dest). Well done!", priority: .urgent)

        // Stop continuous processing
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    // MARK: - Gemini integration

    private func requestGeminiGuidance(status: String) {
        guard !isGeminiCallInFlight else {
            BNLog.navigation.info("Gemini call already in flight — skipping")
            return
        }

        guard let snapshot = latestSnapshot else {
            BNLog.navigation.warning("No camera snapshot available for Gemini — camera may still be starting up")
            // Retry after 2 seconds if this is the initial request
            if appState?.session.phase == .planning {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    BNLog.navigation.info("Retrying Gemini request after snapshot delay")
                    self?.requestGeminiGuidance(status: status)
                }
            }
            return
        }

        isGeminiCallInFlight = true
        appState?.session.lastGeminiCallTime = Date()

        // Pause frame publishing to reduce ML pipeline load while waiting for Gemini
        cameraService.isFramePublishingPaused = true
        BNLog.navigation.info("Paused ML frame publishing while waiting for Gemini response")

        geminiCallTask = Task { [weak self] in
            guard let self else { return }

            let response = await self.geminiService.requestNextGoal(
                imageData: snapshot,
                destination: self.appState?.session.destination ?? "",
                completedGoals: self.appState?.session.completedSecondaryGoals ?? [],
                currentGoalStatus: status
            )

            await MainActor.run {
                self.isGeminiCallInFlight = false
                // Resume frame publishing after Gemini response
                self.cameraService.isFramePublishingPaused = false
                BNLog.navigation.info("Resumed ML frame publishing after Gemini response")
                self.handleGeminiResponse(response)
            }
        }
    }

    private func handleGeminiResponse(_ response: GeminiNavigationResponse?) {
        guard let response else {
            BNLog.navigation.error("Gemini returned nil — entering cautious mode")

            let message: String
            let status: String
            switch geminiService.lastFailureReason {
            case .quotaExhausted:
                message = "The AI service has reached its daily limit. Please try again later or update your API key in settings."
                status = "Daily quota exceeded — update API key in settings"
            case .rateLimited(let seconds):
                message = "The AI service is busy. I'll try again in \(Int(seconds)) seconds."
                status = "Rate limited — retrying shortly"
            case .apiKeyMissing:
                message = "No API key configured. Please add your Gemini API key in settings."
                status = "API key missing — add in settings"
            case .networkError:
                message = "I can't reach the AI service. Please check your internet connection."
                status = "Network error — check connection"
            default:
                message = "I'm having trouble analyzing the environment. Please proceed carefully."
                status = "Analysis unavailable — proceed with caution"
            }

            speechService.speak(message, priority: .normal)
            appState?.updateStatus(status)
            return
        }

        // Transition from planning to navigating on first successful Gemini response
        if appState?.session.phase == .planning {
            appState?.updatePhase(.navigating)
        }

        // Create the new secondary goal
        let goal = SecondaryGoal(
            id: UUID(),
            descriptor: response.secondaryGoalDescriptor,
            directionHint: response.directionHint
        )
        appState?.session.currentSecondaryGoal = goal

        // Set YOLOE to track this new goal
        yoloeService.setSecondaryGoalPrompt(response.secondaryGoalDescriptor)

        // Start the goal beep immediately from the hinted direction,
        // so the user gets audio guidance before YOLOE detects the object.
        let hintLateral = lateralOffsetFromDirectionHint(response.directionHint)
        latestGoalLateralOffset = hintLateral
        latestGoalDistance = 5.0
        hasActiveGoalTracking = true
        isCurrentlyAvoiding = false
        spatialAudioService.updateGoalDirection(lateralOffset: hintLateral, distance: 5.0)

        // Announce to the user
        let announcement = "Head toward the \(response.secondaryGoalDescriptor), \(response.directionHint)."
        appState?.updateStatus(announcement)
        speechService.speak(announcement, priority: .normal)

        BNLog.navigation.info("New secondary goal set: '\(response.secondaryGoalDescriptor)' (\(response.directionHint))")

        appState?.session.isFinalDestinationVisible = response.destinationInSight
        if response.destinationInSight {
            BNLog.navigation.info("Gemini confirms final destination is visible in frame")
            speechService.speak("I can see your destination ahead.", priority: .low)
        }
    }

    // MARK: - Voice commands

    private func handleVoiceCommand(_ command: String) {
        guard appState?.session.phase == .navigating else { return }

        BNLog.navigation.info("Voice command received: '\(command)'")
        appState?.lastVoiceCommand = command
        appState?.isVoiceCommandProcessing = true

        // Pause voice command listening while TTS responds to avoid echo
        voiceCommandService.pause()

        speechService.speak("Got it, let me look.", priority: .normal)

        requestGeminiVoiceCommand(command: command)
    }

    private func requestGeminiVoiceCommand(command: String) {
        guard let snapshot = latestSnapshot else {
            BNLog.navigation.warning("No snapshot available for voice command")
            speechService.speak("I can't see right now. Try again in a moment.", priority: .normal)
            appState?.isVoiceCommandProcessing = false
            voiceCommandService.resume()
            return
        }

        Task { [weak self] in
            guard let self else { return }

            let response = await self.geminiService.requestWithVoiceCommand(
                imageData: snapshot,
                command: command,
                destination: self.appState?.session.destination ?? "",
                completedGoals: self.appState?.session.completedSecondaryGoals ?? [],
                currentGoalDescriptor: self.appState?.session.currentSecondaryGoal?.descriptor
            )

            await MainActor.run {
                self.appState?.isVoiceCommandProcessing = false

                if let response {
                    self.handleGeminiResponse(response)
                } else {
                    self.speechService.speak(
                        "Sorry, I couldn't get an answer. Try asking again.",
                        priority: .normal
                    )
                }

                // Resume listening after a short delay to let TTS finish
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.voiceCommandService.resume()
                }
            }
        }
    }

    // MARK: - Avoidance guidance helpers

    private func announceAvoidanceDirection(guidanceLateral: Float, zones: [ObstacleMap.ObstacleZoneInfo] = []) {
        lastAvoidanceAnnouncementTime = Date()

        // Find which zones have close obstacles to describe the situation
        let closeZones = zones.filter { $0.closestDistanceMeters < BNConstants.obstacleAvoidanceRange }

        if guidanceLateral < -0.15 {
            if closeZones.contains(where: { $0.lateralOffset > 0.1 }) && closeZones.contains(where: { abs($0.lateralOffset) < 0.3 }) {
                speechService.speak("Obstacle ahead and to the right. Move left to go around.", priority: .normal)
            } else {
                speechService.speak("Obstacle ahead. Move left to go around.", priority: .normal)
            }
        } else if guidanceLateral > 0.15 {
            if closeZones.contains(where: { $0.lateralOffset < -0.1 }) && closeZones.contains(where: { abs($0.lateralOffset) < 0.3 }) {
                speechService.speak("Obstacle ahead and to the left. Move right to go around.", priority: .normal)
            } else {
                speechService.speak("Obstacle ahead. Move right to go around.", priority: .normal)
            }
        }
    }

    private func lateralOffsetFromDirectionHint(_ hint: String) -> Float {
        let lower = hint.lowercased()
        if lower.contains("left") {
            if lower.contains("slightly") { return -0.3 }
            if lower.contains("far") { return -0.8 }
            return -0.5
        }
        if lower.contains("right") {
            if lower.contains("slightly") { return 0.3 }
            if lower.contains("far") { return 0.8 }
            return 0.5
        }
        return 0.0
    }

    // MARK: - Heartbeat timer

    private func startHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: BNConstants.geminiHeartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.appState?.session.phase == .navigating else { return }
                BNLog.navigation.info("Heartbeat: periodic Gemini re-check")
                self.requestGeminiGuidance(status: "Periodic check-in. Still navigating.")
            }
        }
    }
}
