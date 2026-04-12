import ARKit
import AVFoundation
import Combine
import CoreImage
import CoreMotion
import QuartzCore
import SceneKit
import SwiftUI
import UIKit
import simd

struct SpatialAudioTestView: View {
 @StateObject var testEngine: SpatialAudioTestEngine
 @Environment(\.dismiss) private var dismiss
 @State var hopTargetLabel: String

 init(testEngine: SpatialAudioTestEngine? = nil, hopTargetLabel: String = "chair") {
  self._testEngine = StateObject(wrappedValue: testEngine ?? SpatialAudioTestEngine())
  self._hopTargetLabel = State(initialValue: hopTargetLabel)
 }

 var body: some View {
  ZStack {
   BNTheme.pageBg.ignoresSafeArea()

   if testEngine.showMeshViewer {
    meshViewerScreen
   } else {
    scanningScreen
   }
  }
  .onAppear { testEngine.start() }
  .onDisappear { testEngine.stop() }
 }

 private var scanningScreen: some View {
  ScrollView {
   VStack(spacing: BNTheme.Spacing.md) {
    SpatialAudioHeader(dismiss: dismiss)
    SpatialAudioStatusSection(testEngine: testEngine)
    if testEngine.debugDepthMap != nil {
     DepthVisualizationView(depthMap: testEngine.debugDepthMap)
    }
    if testEngine.isShowingAcquireOverlay {
     SpatialAudioAcquireOverlay(testEngine: testEngine)
    }
    SpatialAudioObstacleList(testEngine: testEngine)
    SpatialAudioControls(testEngine: testEngine, hopTargetLabel: $hopTargetLabel)
   }
   .padding(.horizontal, BNTheme.Spacing.lg)
   .padding(.bottom, BNTheme.Spacing.lg)
  }
 }

 private var meshViewerScreen: some View {
  VStack(spacing: 0) {
   SpatialAudioMeshViewerHeader(testEngine: testEngine, dismiss: dismiss)

   if let scene = testEngine.meshScene {
    MeshSceneView(scene: scene)
     .ignoresSafeArea(edges: .bottom)
   } else {
    VStack {
     Spacer()
     ProgressView("Building 3D mesh...")
      .foregroundColor(BNTheme.textSecondary)
     Spacer()
    }
   }

   SpatialAudioMeshViewerLegend(testEngine: testEngine)
  }
 }
}

struct MeshSceneView: UIViewRepresentable {
 let scene: SCNScene

 func makeUIView(context: Context) -> SCNView {
  let scnView = SCNView()
  scnView.scene = scene
  scnView.backgroundColor = UIColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)
  scnView.allowsCameraControl = true
  scnView.autoenablesDefaultLighting = false
  scnView.antialiasingMode = .multisampling4X
  scnView.defaultCameraController.interactionMode = .orbitTurntable
  scnView.defaultCameraController.maximumVerticalAngle = 89
  return scnView
 }

 func updateUIView(_ uiView: SCNView, context: Context) {
  uiView.scene = scene
 }
}

struct ObstacleDisplayInfo: Identifiable {
 let id = UUID()
 let distance: Float
 let directionLabel: String
 let worldPosition: SIMD3<Float>
}

@MainActor
final class SpatialAudioTestEngine: NSObject, ObservableObject {
 @Published var arStatus = "Initializing"
 @Published var meshStatus = "Waiting for LiDAR..."
 @Published var debugDepthMap:
  (
   depthGrid: [[Float]], gridWidth: Int, gridHeight: Int,
   closestObstacle: (x: Int, y: Int, distance: Float)?
  )?
 @Published var meshAnchorCount = 0
 @Published var totalVertexCount = ""
 @Published var headTrackingStatus = "Phone Orientation"
 @Published var audioStatus = "Stopped"
 @Published var closestObstacleText = "—"
 @Published var closestDistance: Float = 100
 @Published var nearbyObstacles: [ObstacleDisplayInfo] = []
 @Published var isAudioEnabled = true
 @Published var showMeshViewer = false
 @Published var meshScene: SCNScene?
 @Published var meshViewerStats = ""

 @Published var distanceCalibration: Float = 1.0
 @Published var beepMaxRangeMeters: Float = 5.5
 @Published var beepMinDistanceMeters: Float = 0.08
 @Published private(set) var closestDistanceScaled: Float = 100

 @Published var yoloStatusText = "Not loaded"
 @Published var yoloStatusColor: Color = BNTheme.textTertiary
 @Published var hopStatusText = "Idle"
 @Published var hopTargetDescriptor = "—"
 @Published var subgoalDistanceText = "—"
 @Published var orientationStatusText = "Cam: left • Depth: left • Overlay: left"
 @Published var subgoalDistanceColor: Color = BNTheme.textPrimary
 @Published var hopStatusColor: Color = BNTheme.textTertiary
 @Published var subgoalReachRadiusMeters: Float = 1.7
 @Published var acquireOverlayImage: UIImage?
 @Published var isShowingAcquireOverlay = false
 @Published var finalDestination = ""

 private let subgoalAdvanceMaxDistanceMeters: Float = 1.7
 private let canonicalImageOrientation: CGImagePropertyOrientation = .left
 private let depthService = DepthEstimationService()
 private var cancellables = Set<AnyCancellable>()

 private enum HopState {
  case idle
  case acquiring
  case guiding
 }

 private var hopState: HopState = .idle
 private var currentSubgoalWorld: SIMD3<Float>?
 private var mirroredSubgoalWorld: SIMD3<Float>?
 private var currentSubgoalDetection: YOLOEService.Detection?
 private var activePromptGeneration: Int = 0
 private var latestPixelBuffer: CVPixelBuffer?
 private var latestSnapshotJPEG: Data?
 private var latestGeminiTask: Task<Void, Never>?
 private var isGeminiRequestInFlight = false
 private var completedGeminiGoals: [String] = []
 private var pendingInitialGeminiCall = false

 private var arSession: ARSession?
 private let audioEngine = AVAudioEngine()
 private let environment = AVAudioEnvironmentNode()
 private let headphoneMotionManager = CMHeadphoneMotionManager()
 private var obstacleNodes: [AVAudioPlayerNode] = []
 private let maxNodes = 8
 private var clickBuffer: AVAudioPCMBuffer?
 private let meshProcessor = MeshObstacleProcessor()
 private var currentCameraTransform: simd_float4x4 = matrix_identity_float4x4
 private var headphoneAttitude: simd_quatf?
 private var isHeadTrackingActive = false
 private var meshThrottleDate = Date.distantPast
 private var frameThrottleDate = Date.distantPast
 private let frameThrottleIntervalWhenIdle: TimeInterval = 0.1
 private var frozenMeshAnchors: [ARMeshAnchor] = []
 private var cameraPathWorld: [SIMD3<Float>] = []
 private var lastPathSampleWorld: SIMD3<Float>?
 private let pathSampleMinDistance: Float = 0.12
 private var spatialClickTimer: Timer?
 private var lastClickMediaTime: CFTimeInterval = 0
 private var audioGraphIsBuilt = false

 private let yoloeService = YOLOEService()
 private let geminiService = GeminiService()
 private let speechService = SpeechService()
 private let voiceCommandService = VoiceCommandService()
 private let framePublisher = PassthroughSubject<CVPixelBuffer, Never>()
 private var yoloCancellables = Set<AnyCancellable>()
 private let ciContext = CIContext()

 private var stereoOutputFormat: AVAudioFormat {
  AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
 }

 func start() {
  cameraPathWorld = []
  lastPathSampleWorld = nil
  lastClickMediaTime = 0
  meshProcessor.skipFloorAndCeilingClassifications = false
  meshProcessor.minForwardDotForInclusion = -0.45
  meshProcessor.vertexSamplingStride = 4
  meshProcessor.maxScanRange = 6.0
  setupAudioEngine()
  setupARSession()
  setupHeadTracking()
  setupYOLOPipeline()
  startSpatialClickTimer()
 }

 func stop() {
  spatialClickTimer?.invalidate()
  spatialClickTimer = nil
  arSession?.pause()
  arSession = nil
  arStatus = "Stopped"
  headphoneMotionManager.stopDeviceMotionUpdates()
  headTrackingStatus = "Stopped"
  for node in obstacleNodes { node.stop() }
  audioEngine.stop()
  audioStatus = "Stopped"
  yoloCancellables.removeAll()
  latestGeminiTask?.cancel()
  latestGeminiTask = nil
  isGeminiRequestInFlight = false
  hopState = .idle
  currentSubgoalWorld = nil
  mirroredSubgoalWorld = nil
  currentSubgoalDetection = nil
  hopStatusText = "Idle"
  hopStatusColor = BNTheme.textTertiary
  voiceCommandService.stopListening()
 }

 func configure(apiKey: String) {
  geminiService.configure(apiKey: apiKey)
 }

 func startNavigation(destination: String) {
  finalDestination = destination
  completedGeminiGoals = []
  hopState = .acquiring
  hopTargetDescriptor = "Finding route to \(destination)..."
  hopStatusText = "Acquiring route to \(destination)..."
  hopStatusColor = BNTheme.warning
  pendingInitialGeminiCall = true

  setupVoiceCommands()
  voiceCommandService.startListening()

  if arStatus != "Running" {
   start()
  }
 }

 private func setupVoiceCommands() {
  voiceCommandService.commandPublisher
   .receive(on: DispatchQueue.main)
   .sink { [weak self] command in
    self?.handleVoiceCommand(command)
   }
   .store(in: &yoloCancellables)
 }

 private func handleVoiceCommand(_ command: String) {
  voiceCommandService.pause()
  speechService.speak("Got it, let me look.", priority: .normal)

  if let pixelBuffer = latestPixelBuffer {
   updateLatestSnapshot(from: pixelBuffer)
  }

  guard let snapshot = latestSnapshotJPEG else {
   speechService.speak("I can't see right now. Try again in a moment.", priority: .normal)
   voiceCommandService.resume()
   return
  }

  Task { [weak self] in
   guard let self = self else { return }
   let response = await self.geminiService.requestWithVoiceCommand(
    imageData: snapshot,
    command: command,
    destination: self.finalDestination,
    completedGoals: self.completedGeminiGoals,
    currentGoalDescriptor: self.hopTargetDescriptor
   )

   await MainActor.run {
    if let response = response {
     self.speechService.speak(response.directionHint, priority: .normal)
     let newGoal = response.secondaryGoalDescriptor
     if !newGoal.isEmpty {
      self.hopTargetDescriptor = newGoal
      self.hopState = .acquiring
      self.yoloeService.clearSecondaryGoal()
      self.yoloeService.setSecondaryGoalPrompt(newGoal)
      self.hopStatusText = "Voice command updated subgoal: \(newGoal)"
     }
    } else {
     self.speechService.speak("Sorry, I couldn't process that.", priority: .normal)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
     self.voiceCommandService.resume()
    }
   }
  }
 }

 func startHopMode(descriptor: String) {
  hopTargetDescriptor = descriptor
  hopState = .acquiring
  currentSubgoalWorld = nil
  mirroredSubgoalWorld = nil
  currentSubgoalDetection = nil
  activePromptGeneration += 1
  yoloeService.clearSecondaryGoal()
  yoloeService.setSecondaryGoalPrompt(descriptor)
  hopStatusText = "Acquiring subgoal..."
  hopStatusColor = BNTheme.warning
  subgoalDistanceText = "—"
  subgoalDistanceColor = BNTheme.textPrimary
  isShowingAcquireOverlay = true
  acquireOverlayImage = nil
 }

 func cancelHopMode() {
  hopState = .idle
  currentSubgoalWorld = nil
  mirroredSubgoalWorld = nil
  currentSubgoalDetection = nil
  yoloeService.clearSecondaryGoal()
  hopStatusText = "Idle"
  hopStatusColor = BNTheme.textTertiary
  subgoalDistanceText = "—"
  subgoalDistanceColor = BNTheme.textPrimary
  isShowingAcquireOverlay = false
  acquireOverlayImage = nil
 }

 func endScanAndShowMesh() {
  guard let session = arSession, let frame = session.currentFrame else { return }

  frozenMeshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
  let cameraTransform = currentCameraTransform
  let pathPoints = cameraPathWorld
  let waypoint = currentSubgoalWorld
  let mirroredWaypoint = mirroredSubgoalWorld

  spatialClickTimer?.invalidate()
  spatialClickTimer = nil
  for node in obstacleNodes {
   node.stop()
   node.volume = 0
  }
  session.pause()
  arStatus = "Paused (scan ended)"
  headphoneMotionManager.stopDeviceMotionUpdates()

  let anchors = frozenMeshAnchors
  Task.detached { [weak self] in
   let scene = SpatialAudioMeshBuilder.buildScene(
    from: anchors,
    cameraTransform: cameraTransform,
    cameraPath: pathPoints,
    waypoint: waypoint,
    mirroredWaypoint: mirroredWaypoint
   )
   await MainActor.run {
    guard let self else { return }
    let totalVerts = anchors.reduce(0) { $0 + $1.geometry.vertices.count }
    let totalFaces = anchors.reduce(0) { $0 + $1.geometry.faces.count }
    let pathCount = pathPoints.count
    self.meshViewerStats =
     "\(anchors.count) chunks • \(totalVerts) vertices • \(totalFaces) faces • path \(pathCount) pts"
    self.meshScene = scene
    self.showMeshViewer = true
   }
  }
 }

 func resumeScanning() {
  showMeshViewer = false
  meshScene = nil
  frozenMeshAnchors = []
  cameraPathWorld = []
  lastPathSampleWorld = nil
  lastClickMediaTime = 0
  setupARSession()
  setupHeadTracking()
  for node in obstacleNodes { node.volume = 0 }
  startSpatialClickTimer()
 }

 private func setupYOLOPipeline() {
  yoloStatusText = "Loading..."
  yoloStatusColor = BNTheme.warning

  yoloeService.bufferOrientation = canonicalImageOrientation
  yoloeService.updatePerformanceMode(.balanced)
  yoloeService.subscribe(to: framePublisher)

  yoloeService.secondaryGoalDetectionPublisher
   .receive(on: DispatchQueue.main)
   .sink { [weak self] tracked in
    self?.handleTrackedGoal(tracked)
   }
   .store(in: &yoloCancellables)

  yoloeService.$isModelLoaded
   .receive(on: DispatchQueue.main)
   .sink { [weak self] loaded in
    guard let self else { return }
    self.yoloStatusText = loaded ? "Loaded" : "Loading..."
    self.yoloStatusColor = loaded ? BNTheme.success : BNTheme.warning
   }
   .store(in: &yoloCancellables)

  yoloeService.loadModel()
 }

 private func handleTrackedGoal(_ tracked: YOLOEService.TrackedInstance?) {
  guard hopState == .acquiring else { return }
  guard let tracked, let detection = tracked.lastDetection else {
   hopStatusText = "Searching \(hopTargetDescriptor)..."
   hopStatusColor = BNTheme.warning
   return
  }
  guard let frame = arSession?.currentFrame else {
   hopStatusText = "Waiting for frame..."
   hopStatusColor = BNTheme.warning
   return
  }
  guard let (correctWorld, mirroredWorld) = computeWorldPoints(for: detection, frame: frame) else {
   hopStatusText = "Detected but cannot project to 3D"
   hopStatusColor = BNTheme.warning
   return
  }

  currentSubgoalDetection = detection
  currentSubgoalWorld = correctWorld
  mirroredSubgoalWorld = mirroredWorld
  hopState = .guiding
  hopStatusText = "Approaching subgoal"
  hopStatusColor = BNTheme.success
  isShowingAcquireOverlay = true
 }

 private func setupAudioEngine() {
  let avSession = AVAudioSession.sharedInstance()
  do {
   try avSession.setCategory(
    .playAndRecord, mode: .default,
    options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
  } catch {
   audioStatus = "setCategory failed: \(error.localizedDescription) (\(error))"
   return
  }
  do {
   try avSession.setActive(true, options: .notifyOthersOnDeactivation)
  } catch {
   audioStatus = "setActive failed: \(error.localizedDescription) (\(error))"
   return
  }

  if !audioGraphIsBuilt {
   audioEngine.attach(environment)
   audioEngine.connect(environment, to: audioEngine.mainMixerNode, format: stereoOutputFormat)
   audioEngine.mainMixerNode.outputVolume = 1.0

   if #available(iOS 18.0, *) {
    environment.isListenerHeadTrackingEnabled = false
   }
   environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
   environment.distanceAttenuationParameters.distanceAttenuationModel = .linear
   environment.distanceAttenuationParameters.referenceDistance = 0.25
   environment.distanceAttenuationParameters.maximumDistance = 12.0
   environment.distanceAttenuationParameters.rolloffFactor = 0.9

   let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
   clickBuffer = SpatialAudioAudioGenerator.generateClick(
    frequency: 880, duration: 0.08, format: format)

   for _ in 0..<maxNodes {
    let node = AVAudioPlayerNode()
    audioEngine.attach(node)
    audioEngine.connect(node, to: environment, format: format)
    node.renderingAlgorithm = .HRTFHQ
    node.sourceMode = .pointSource
    node.reverbBlend = 0
    node.volume = 0
    obstacleNodes.append(node)
   }
   audioGraphIsBuilt = true
  }

  do {
   audioEngine.prepare()
   try audioEngine.start()
   audioStatus = "Running"
  } catch {
   audioStatus = "engine.start failed: \(error.localizedDescription) (\(error))"
  }
 }

 private func startSpatialClickTimer() {
  spatialClickTimer?.invalidate()
  let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
   Task { @MainActor in self?.playSpatialClickPulse() }
  }
  RunLoop.main.add(timer, forMode: .common)
  spatialClickTimer = timer
 }

 private func clickIntervalSeconds(forClosestScaled d: Float) -> Float {
  let minD = max(beepMinDistanceMeters, 0.001)
  let maxR = max(beepMaxRangeMeters, minD + 0.1)
  if d >= maxR { return 2.0 }
  if d <= minD { return 0.07 }
  let span = maxR - minD
  let t = (d - minD) / span
  let eased = powf(max(0, min(1, t)), 1.35)
  return 0.07 + eased * 0.92
 }

 private func playSpatialClickPulse() {
  guard isAudioEnabled, audioEngine.isRunning, !showMeshViewer else { return }
  guard let buffer = clickBuffer, buffer.frameLength > 0 else { return }

  let hasActive = obstacleNodes.contains { $0.volume > 0.001 }
  guard hasActive else {
   lastClickMediaTime = 0
   for node in obstacleNodes where node.isPlaying { node.stop() }
   return
  }

  let now = CACurrentMediaTime()
  let interval = Double(clickIntervalSeconds(forClosestScaled: closestDistanceScaled))
  if lastClickMediaTime > 0, now - lastClickMediaTime < interval { return }
  lastClickMediaTime = now

  for node in obstacleNodes where node.volume > 0.001 {
   if !node.isPlaying { node.play() }
   node.scheduleBuffer(buffer, at: nil, options: .interruptsAtLoop, completionHandler: nil)
  }
 }

 private func setupARSession() {
  let session = ARSession()
  session.delegate = self
  self.arSession = session
  depthService.configure(session: session)
  depthService.obstacleMapPublisher.sink { [weak self] map in
   guard let self = self else { return }
   let closest = map.closestObstacleInWalkingDirection()
   self.debugDepthMap = (
    depthGrid: map.depthGrid,
    gridWidth: map.gridWidth,
    gridHeight: map.gridHeight,
    closestObstacle: closest.map {
     (
      x: Int($0.normalizedX * Float(map.gridWidth)), y: Int($0.normalizedY * Float(map.gridHeight)),
      distance: ObstacleMap.approximateDistance(
       inverseDepth: $0.depth, scaleFactor: self.depthService.depthScaleFactor)
     )
    }
   )
  }.store(in: &cancellables)

  let config = ARWorldTrackingConfiguration()
  config.planeDetection = [.horizontal, .vertical]
  config.environmentTexturing = .none

  if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
   config.frameSemantics = .sceneDepth
  }

  if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
   config.sceneReconstruction = .mesh
   meshStatus = "Mesh enabled — scanning..."
  } else {
   meshStatus = "No LiDAR — mesh unavailable"
  }

  session.run(config, options: [.resetTracking, .removeExistingAnchors])
  arStatus = "Running"
 }

 private func setupHeadTracking() {
  guard headphoneMotionManager.isDeviceMotionAvailable else {
   headTrackingStatus = "Phone Orientation (no AirPods)"
   return
  }

  headphoneMotionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
   Task { @MainActor in
    guard let self else { return }
    if error != nil {
     self.isHeadTrackingActive = false
     self.headphoneAttitude = nil
     self.headTrackingStatus = "Phone Orientation"
     return
    }
    guard let motion else { return }

    if !self.isHeadTrackingActive {
     self.isHeadTrackingActive = true
     self.headTrackingStatus = "AirPods Head Tracking ✓"
    }

    let q = motion.attitude.quaternion
    self.headphoneAttitude = simd_quatf(
     ix: Float(q.x), iy: Float(q.y), iz: Float(q.z), r: Float(q.w))
   }
  }
 }

 private func updateListener(from transform: simd_float4x4) {
  currentCameraTransform = transform

  let pos = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
  if let last = lastPathSampleWorld {
   if simd_length(pos - last) >= pathSampleMinDistance {
    cameraPathWorld.append(pos)
    lastPathSampleWorld = pos
   }
  } else {
   cameraPathWorld = [pos]
   lastPathSampleWorld = pos
  }

  environment.listenerPosition = AVAudio3DPoint(x: pos.x, y: pos.y, z: pos.z)

  var forward: SIMD3<Float>
  var up: SIMD3<Float>

  if let headAtt = headphoneAttitude, isHeadTrackingActive {
   let cameraRot = simd_quatf(transform)
   let worldHead = cameraRot * headAtt
   let rotMatrix = simd_float3x3(worldHead)
   forward = -rotMatrix.columns.2
   up = rotMatrix.columns.1
  } else {
   forward = SIMD3<Float>(-transform.columns.2.x, -transform.columns.2.y, -transform.columns.2.z)
   up = SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
  }

  environment.listenerVectorOrientation = AVAudio3DVectorOrientation(
   forward: AVAudio3DVector(x: -forward.x, y: forward.y, z: forward.z),
   up: AVAudio3DVector(x: -up.x, y: up.y, z: up.z)
  )

  updateSubgoalDistanceUI(cameraPos: pos)
 }

 private func updateSubgoalDistanceUI(cameraPos: SIMD3<Float>) {
  guard let g = currentSubgoalWorld else {
   subgoalDistanceText = "—"
   subgoalDistanceColor = BNTheme.textPrimary
   return
  }
  let d = simd_length(g - cameraPos)
  subgoalDistanceText = String(format: "%.2f m", d)
  if d <= subgoalReachRadiusMeters {
   subgoalDistanceColor = BNTheme.success
  } else if d <= max(subgoalReachRadiusMeters * 2, 1.5) {
   subgoalDistanceColor = BNTheme.warning
  } else {
   subgoalDistanceColor = BNTheme.textPrimary
  }
 }

 private func processMeshAnchors(_ anchors: [ARMeshAnchor]) {
  let now = Date()
  guard now.timeIntervalSince(meshThrottleDate) > 0.25 else { return }
  meshThrottleDate = now

  meshProcessor.maxScanRange = max(beepMaxRangeMeters * 2.5, 6.0)
  meshAnchorCount = anchors.count
  let verts = anchors.reduce(0) { $0 + $1.geometry.vertices.count }
  totalVertexCount = "\(verts)"

  if anchors.isEmpty {
   meshStatus = "Scanning..."
   closestDistanceScaled = 100
   return
  }
  meshStatus = "Active (\(anchors.count) chunks)"

  let obstacles = meshProcessor.findNearbyObstacles(
   meshAnchors: anchors, cameraTransform: currentCameraTransform, maxResults: maxNodes)

  let cameraPos = SIMD3<Float>(
   currentCameraTransform.columns.3.x, currentCameraTransform.columns.3.y,
   currentCameraTransform.columns.3.z)
  let cameraRight = normalize(
   SIMD3<Float>(
    currentCameraTransform.columns.0.x, currentCameraTransform.columns.0.y,
    currentCameraTransform.columns.0.z))
  let cameraForward = normalize(
   SIMD3<Float>(
    -currentCameraTransform.columns.2.x, -currentCameraTransform.columns.2.y,
    -currentCameraTransform.columns.2.z))

  nearbyObstacles = obstacles.prefix(6).map { obs in
   let scaled = obs.distance * distanceCalibration
   let toObs = obs.worldPosition - cameraPos
   let lateral = dot(normalize(toObs), cameraRight)
   let frontal = dot(normalize(toObs), cameraForward)

   let label: String
   if frontal > 0.7 {
    label = lateral < -0.3 ? "Front-L" : (lateral > 0.3 ? "Front-R" : "Front")
   } else if frontal > 0.2 {
    label = lateral < 0 ? "Left" : "Right"
   } else {
    label = lateral < 0 ? "Far Left" : "Far Right"
   }

   return ObstacleDisplayInfo(
    distance: scaled, directionLabel: label, worldPosition: obs.worldPosition)
  }

  if let closest = obstacles.first {
   let scaled = closest.distance * distanceCalibration
   closestDistance = scaled
   closestObstacleText = String(format: "%.2fm (raw %.2f)", scaled, closest.distance)
  } else {
   closestDistance = 100
   closestObstacleText = "—"
  }

  let audibleScaled =
   obstacles
   .map { $0.distance * distanceCalibration }
   .filter { $0 >= beepMinDistanceMeters && $0 <= beepMaxRangeMeters }
  closestDistanceScaled = audibleScaled.min() ?? (beepMaxRangeMeters + 1)

  updateHopStateAndAudio(obstacles: obstacles, cameraPos: cameraPos)
 }

 private func updateHopStateAndAudio(obstacles: [MeshObstacle], cameraPos: SIMD3<Float>) {
  guard isAudioEnabled, audioEngine.isRunning else { return }

  if hopState == .guiding, let goal = currentSubgoalWorld {
   let d = simd_length(goal - cameraPos)
   if d <= subgoalAdvanceMaxDistanceMeters {
    let reachedDescriptor = hopTargetDescriptor
    if !reachedDescriptor.isEmpty, reachedDescriptor != "—" {
     completedGeminiGoals.append(reachedDescriptor)
    }

    hopState = .acquiring
    currentSubgoalWorld = nil
    mirroredSubgoalWorld = nil
    currentSubgoalDetection = nil
    activePromptGeneration += 1
    yoloeService.clearSecondaryGoal()
    hopStatusText = "Subgoal reached • asking Gemini for next..."
    hopStatusColor = BNTheme.success
    for node in obstacleNodes { node.volume = 0 }

    requestGeminiNextSubgoal(
     currentGoalStatus:
      "Successfully reached waypoint: '\(reachedDescriptor)'. Need next waypoint to reach \(finalDestination)."
    )
    return
   }
  }

  if hopState == .guiding, let goal = currentSubgoalWorld {
   let d = simd_length(goal - cameraPos)
   closestDistanceScaled = min(max(d, beepMinDistanceMeters), beepMaxRangeMeters)
   obstacleNodes[0].position = AVAudio3DPoint(x: -goal.x, y: goal.y, z: goal.z)
   let span = max(beepMaxRangeMeters - beepMinDistanceMeters, 0.05)
   let normalized = max(0, min(1, (d - beepMinDistanceMeters) / span))
   obstacleNodes[0].volume = 0.4 + (1.0 - normalized) * 0.6
   for i in 1..<obstacleNodes.count { obstacleNodes[i].volume = 0 }
   hopStatusText = "Guiding to subgoal"
   hopStatusColor = BNTheme.brandPrimary
   return
  }

  let span = max(beepMaxRangeMeters - beepMinDistanceMeters, 0.05)
  for (i, node) in obstacleNodes.enumerated() {
   if i < obstacles.count {
    let obs = obstacles[i]
    let scaled = obs.distance * distanceCalibration
    guard scaled >= beepMinDistanceMeters, scaled <= beepMaxRangeMeters else {
     node.volume = 0
     continue
    }
    node.position = AVAudio3DPoint(
     x: -obs.worldPosition.x, y: obs.worldPosition.y, z: obs.worldPosition.z)
    let normalized = max(0, min(1, (scaled - beepMinDistanceMeters) / span))
    node.volume = 0.3 + (1.0 - normalized) * 0.7
   } else {
    node.volume = 0
   }
  }
 }

 private func computeWorldPoints(
  for detection: YOLOEService.Detection,
  frame: ARFrame
 ) -> (correct: SIMD3<Float>, mirrored: SIMD3<Float>)? {

  let bx = detection.boundingBox.midX
  let by = detection.boundingBox.midY

  let rawCenter = CGPoint(x: by, y: 1.0 - bx)
  let mirroredCenter = CGPoint(x: 1.0 - bx, y: 1.0 - by)

  updateAcquireOverlayImage(frame: frame, detection: detection)

  guard
   let imageToDepth = frame.displayTransform(
    for: .portrait, viewportSize: CGSize(width: 1, height: 1)
   ).invertedOrNil()
  else { return nil }

  func unproject(_ normalizedPoint: CGPoint) -> SIMD3<Float>? {
   let mapped = normalizedPoint.applying(imageToDepth)
   let sx = Float(max(0, min(1, mapped.x)))
   let sy = Float(max(0, min(1, mapped.y)))

   if let depthMap = frame.sceneDepth?.depthMap {
    CVPixelBufferLockBaseAddress(depthMap, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

    let w = CVPixelBufferGetWidth(depthMap)
    let h = CVPixelBufferGetHeight(depthMap)
    guard w > 0, h > 0 else { return nil }

    let cxPix = max(0, min(w - 1, Int(round(sx * Float(w - 1)))))
    let cyPix = max(0, min(h - 1, Int(round(sy * Float(h - 1)))))

    guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
    let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
    let fptr = base.assumingMemoryBound(to: Float32.self)
    let row = rowBytes / MemoryLayout<Float32>.size

    let radius = 3
    var samples: [Float] = []
    samples.reserveCapacity((radius * 2 + 1) * (radius * 2 + 1))
    for yy in max(0, cyPix - radius)...min(h - 1, cyPix + radius) {
     for xx in max(0, cxPix - radius)...min(w - 1, cxPix + radius) {
      let d = fptr[yy * row + xx]
      if d.isFinite, d > 0.1, d < 12 { samples.append(d) }
     }
    }

    let depth: Float
    if !samples.isEmpty {
     let sorted = samples.sorted()
     depth = sorted[sorted.count / 2]
    } else {
     let raw = fptr[cyPix * row + cxPix]
     guard raw.isFinite, raw > 0.1, raw < 12 else {
      if let session = arSession {
       let query = frame.raycastQuery(
        from: normalizedPoint, allowing: .estimatedPlane, alignment: .any)
       if let result = session.raycast(query).first {
        let t = result.worldTransform
        return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
       }
      }
      return nil
     }
     depth = raw
    }

    let intr = frame.camera.intrinsics
    let fx = intr[0, 0]
    let fy = intr[1, 1]
    let cxi = intr[2, 0]
    let cyi = intr[2, 1]

    let X = (Float(cxPix) - cxi) * depth / fx
    let Y = (Float(cyPix) - cyi) * depth / fy
    let camPoint = SIMD4<Float>(X, Y, -depth, 1.0)
    let world = frame.camera.transform * camPoint
    return SIMD3<Float>(world.x, world.y, world.z)
   }

   if let session = arSession {
    let query = frame.raycastQuery(
     from: normalizedPoint, allowing: .estimatedPlane, alignment: .any)
    if let result = session.raycast(query).first {
     let t = result.worldTransform
     return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
    }
   }
   return nil
  }

  let correct = unproject(rawCenter)
  let mirrored = unproject(mirroredCenter)

  guard let correct else { return nil }
  return (correct: correct, mirrored: mirrored ?? correct)
 }

 private func requestGeminiNextSubgoal(currentGoalStatus: String) {
  guard !isGeminiRequestInFlight else { return }

  if let pixelBuffer = latestPixelBuffer {
   updateLatestSnapshot(from: pixelBuffer)
  }

  guard let snapshot = latestSnapshotJPEG else {
   hopStatusText = "Need camera snapshot for Gemini..."
   hopStatusColor = BNTheme.warning
   yoloeService.setSecondaryGoalPrompt(hopTargetDescriptor)
   return
  }

  isGeminiRequestInFlight = true
  latestGeminiTask?.cancel()
  hopState = .acquiring
  hopStatusText = "Acquiring next waypoint..."
  hopStatusColor = BNTheme.warning

  latestGeminiTask = Task { [weak self] in
   guard let self else { return }

   let response = await self.geminiService.requestNextGoal(
    imageData: snapshot,
    destination: self.finalDestination.isEmpty ? "navigation waypoint" : self.finalDestination,
    completedGoals: self.completedGeminiGoals,
    currentGoalStatus: currentGoalStatus
   )

   await MainActor.run {
    self.isGeminiRequestInFlight = false
    guard let response else {
     self.hopStatusText = "Gemini unavailable • reacquiring \(self.hopTargetDescriptor)..."
     self.hopStatusColor = BNTheme.warning
     self.yoloeService.setSecondaryGoalPrompt(self.hopTargetDescriptor)
     return
    }

    self.hopTargetDescriptor = response.secondaryGoalDescriptor
    self.yoloeService.clearSecondaryGoal()
    self.yoloeService.setSecondaryGoalPrompt(response.secondaryGoalDescriptor)
    self.speechService.speak(response.directionHint, priority: .normal)
    self.hopStatusText = "Gemini next subgoal: \(response.secondaryGoalDescriptor)"
    self.hopStatusColor = BNTheme.brandPrimary
   }
  }
 }

 private func updateLatestSnapshot(from pixelBuffer: CVPixelBuffer) {
  let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
  guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
  let image = UIImage(cgImage: cgImage)
  guard let jpeg = image.jpegData(compressionQuality: 0.7) else { return }
  latestSnapshotJPEG = jpeg
 }

 private func updateAcquireOverlayImage(frame: ARFrame, detection: YOLOEService.Detection) {
  guard isShowingAcquireOverlay else { return }

  let ciImage = CIImage(cvPixelBuffer: frame.capturedImage).oriented(canonicalImageOrientation)
  guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

  let width = CGFloat(cgImage.width)
  let height = CGFloat(cgImage.height)
  if width <= 0 || height <= 0 { return }

  let normalized = SpatialAudioProjectionHelper.transformedNormalizedRect(
   from: detection.boundingBox)
  let boxX = normalized.minX * width
  let boxY = (1.0 - normalized.maxY) * height
  let boxW = normalized.width * width
  let boxH = normalized.height * height
  let center = CGPoint(x: boxX + boxW * 0.5, y: boxY + boxH * 0.5)

  UIGraphicsBeginImageContextWithOptions(CGSize(width: width, height: height), true, 1.0)
  guard let ctx = UIGraphicsGetCurrentContext() else {
   UIGraphicsEndImageContext()
   return
  }

  ctx.interpolationQuality = .high
  ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

  ctx.setStrokeColor(UIColor.systemYellow.cgColor)
  ctx.setLineWidth(3)
  ctx.stroke(CGRect(x: boxX, y: boxY, width: boxW, height: boxH))

  ctx.setFillColor(UIColor.systemRed.cgColor)
  ctx.fillEllipse(in: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))

  let diag = "ori \(canonicalImageOrientation.debugName) • 3D: raw bbox center"
  let attrs: [NSAttributedString.Key: Any] = [
   .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .semibold),
   .foregroundColor: UIColor.white,
  ]
  let textRect = CGRect(x: 14, y: 14, width: width - 28, height: 30)
  let bgRect = textRect.insetBy(dx: -8, dy: -6)
  ctx.setFillColor(UIColor.black.withAlphaComponent(0.5).cgColor)
  ctx.fill(bgRect)
  (diag as NSString).draw(in: textRect, withAttributes: attrs)

  let output = UIGraphicsGetImageFromCurrentImageContext()
  UIGraphicsEndImageContext()

  if let output { acquireOverlayImage = output }
 }
}

extension SpatialAudioTestEngine: ARSessionDelegate {
 nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
  let transform = frame.camera.transform
  let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
  let pixelBuffer = frame.capturedImage

  DispatchQueue.main.async { [weak self] in
   guard let self = self else { return }
   self.depthService.sessionDidUpdateFrame(frame)

   let now = Date()
   if self.hopState != .acquiring {
    guard now.timeIntervalSince(self.frameThrottleDate) >= self.frameThrottleIntervalWhenIdle else {
     return
    }
    self.frameThrottleDate = now
   }

   self.latestPixelBuffer = pixelBuffer

   if self.pendingInitialGeminiCall {
    self.pendingInitialGeminiCall = false
    self.requestGeminiNextSubgoal(
     currentGoalStatus: "Navigation to \(self.finalDestination) just started. Need first waypoint.")
   }

   if self.hopState == .acquiring {
    self.framePublisher.send(pixelBuffer)
   }
   self.updateListener(from: transform)
   self.processMeshAnchors(meshAnchors)
  }
 }
}
