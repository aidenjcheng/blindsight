import Combine
import CoreML
import Foundation
import UIKit
import Vision
import os
import simd

// MARK: - YOLOE open-vocabulary object detection with instance locking and phantom coordinates
//
// The YOLOE CoreML model outputs raw tensors (no embedded NMS) because
// nms=True is only supported for YOLO26 Detect models, not YOLOE.
// This service decodes the raw output, applies confidence thresholding
// and greedy NMS, then publishes Detection structs.

@MainActor
final class YOLOEService: ObservableObject {

  // MARK: - Detection result

  struct Detection {
    let label: String
    let confidence: Float
    let boundingBox: CGRect  // Normalized [0,1] Vision coords (origin bottom-left)
    let centerNormalized: SIMD2<Float>  // Screen coords (origin top-left, 0-1)
  }

  // MARK: - Tracked instance with world position

  struct TrackedInstance {
    let id: UUID
    let descriptor: String
    var lastDetection: Detection?
    var worldPosition: SIMD3<Float>?
    var lastSeenTime: Date?
    var isVisible: Bool = false
  }

  // MARK: - Class labels (must match NAVIGATION_CLASSES order in export script)

  private static let classLabels: [String] = [
    "door", "doorway", "exit sign", "entrance",
    "elevator", "escalator", "stairs", "staircase",
    "hallway", "corridor",
    "chair", "table", "desk", "bench", "couch",
    "trash can", "recycling bin",
    "vending machine", "water fountain",
    "sign", "room number", "restroom sign",
    "fire extinguisher", "emergency exit",
    "handrail", "ramp",
    "person", "wheelchair", "cart", "luggage",
    "pillar", "column", "wall",
    "restroom", "bathroom", "toilet",
    "window", "clock", "light", "plant", "potted plant",
  ]

  private static let nmsIoUThreshold: Float = 0.45

  // MARK: - Output

  let secondaryGoalDetectionPublisher = PassthroughSubject<TrackedInstance?, Never>()
  let finalDestinationDetectionPublisher = PassthroughSubject<TrackedInstance?, Never>()

  // MARK: - State

  @Published private(set) var isModelLoaded = false
  @Published private(set) var lastInferenceTimeMs: Double = 0

  private(set) var secondaryGoalInstance: TrackedInstance?
  private(set) var finalDestinationInstance: TrackedInstance?

  // MARK: - Private

  private var model: VNCoreMLModel?
  private let inferenceQueue = DispatchQueue(label: "com.blindnav.yoloe", qos: .userInitiated)
  private var cancellables = Set<AnyCancellable>()

  private var secondaryGoalPrompt: String?
  private var finalDestinationPrompt: String?

  var bufferOrientation: CGImagePropertyOrientation = .up

  private var frameCounter = 0
  private var processEveryNFrames = 15

  func updatePerformanceMode(_ mode: BNConstants.PerformanceMode) {
    switch mode {
    case .balanced:
      processEveryNFrames = 15
    case .performance:
      processEveryNFrames = 10
    case .battery:
      processEveryNFrames = 20
    }
    BNLog.yoloe.info(
      "YOLOE frame skipping set to 1/\(self.processEveryNFrames) for \(mode.description)")
  }

  // MARK: - Configuration

  func loadModel() {
    inferenceQueue.async { [weak self] in
      guard let self else { return }
      BNLog.yoloe.info("Loading YOLOE-11S CoreML model...")

      do {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        guard
          let modelURL = Bundle.main.url(
            forResource: "YOLOE11S",
            withExtension: "mlmodelc"
          )
        else {
          BNLog.yoloe.error("YOLOE11S.mlmodelc not found in bundle. Run the export script first.")
          return
        }

        let coreMLModel = try MLModel(contentsOf: modelURL, configuration: config)
        let vnModel = try VNCoreMLModel(for: coreMLModel)

        self.model = vnModel
        DispatchQueue.main.async {
          self.isModelLoaded = true
          BNLog.yoloe.info("YOLOE-11S model loaded successfully")
        }
      } catch {
        BNLog.yoloe.error("Failed to load YOLOE model: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Prompt management

  func setSecondaryGoalPrompt(_ descriptor: String) {
    BNLog.yoloe.info("Secondary goal prompt set: '\(descriptor)'")
    secondaryGoalPrompt = descriptor
    secondaryGoalInstance = TrackedInstance(id: UUID(), descriptor: descriptor)
  }

  func setFinalDestinationPrompt(_ descriptor: String) {
    BNLog.yoloe.info("Final destination prompt set: '\(descriptor)'")
    finalDestinationPrompt = descriptor
    finalDestinationInstance = TrackedInstance(id: UUID(), descriptor: descriptor)
  }

  func clearSecondaryGoal() {
    secondaryGoalPrompt = nil
    secondaryGoalInstance = nil
    secondaryGoalDetectionPublisher.send(nil)
    BNLog.yoloe.info("Secondary goal cleared")
  }

  // MARK: - Subscribe to camera frames

  func subscribe(to framePublisher: PassthroughSubject<CVPixelBuffer, Never>) {
    framePublisher
      .receive(on: inferenceQueue)
      .sink { [weak self] pixelBuffer in
        self?.processFrame(pixelBuffer)
      }
      .store(in: &cancellables)
    BNLog.yoloe.info("Subscribed to camera frame publisher")
  }

  // MARK: - Frame processing

  private func processFrame(_ pixelBuffer: CVPixelBuffer) {
    frameCounter += 1
    guard frameCounter % processEveryNFrames == 0 else { return }
    guard let model else { return }

    guard PixelBufferUtils.isValid(pixelBuffer) else {
      BNLog.yoloe.warning("Invalid pixel buffer, skipping frame")
      return
    }

    let startTime = CFAbsoluteTimeGetCurrent()

    let request = VNCoreMLRequest(model: model) { [weak self] request, error in
      guard let self else { return }

      if let error {
        BNLog.yoloe.error("YOLOE inference error: \(error.localizedDescription)")
        return
      }

      let detections = self.parseResults(request.results)
      self.processDetections(detections)

      let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
      DispatchQueue.main.async {
        self.lastInferenceTimeMs = elapsed
      }
    }

    request.imageCropAndScaleOption = .scaleFill

    let handler = VNImageRequestHandler(
      cvPixelBuffer: pixelBuffer, orientation: bufferOrientation, options: [:])
    do {
      try handler.perform([request])
    } catch {
      BNLog.yoloe.error("YOLOE VNImageRequestHandler failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Raw tensor parsing

  /// Parses VNCoreMLRequest results. Handles both raw tensor output (YOLOE)
  /// and VNRecognizedObjectObservation (if a model with NMS is ever used).
  private func parseResults(_ results: [Any]?) -> [Detection] {
    guard let results else { return [] }

    // Try legacy recognized-object path first (models with embedded NMS)
    if let recognized = results as? [VNRecognizedObjectObservation], !recognized.isEmpty {
      return recognized.compactMap { obs -> Detection? in
        guard let top = obs.labels.first else { return nil }
        let box = obs.boundingBox
        return Detection(
          label: top.identifier,
          confidence: top.confidence,
          boundingBox: box,
          centerNormalized: SIMD2<Float>(Float(box.midX), Float(1.0 - box.midY))
        )
      }
    }

    // Raw tensor path — YOLOE without embedded NMS
    guard let featureObs = results as? [VNCoreMLFeatureValueObservation] else {
      return []
    }

    // Find the detection tensor: shape [1, numFeatures, numPredictions]
    guard
      let detArray =
        featureObs
        .compactMap({ $0.featureValue.multiArrayValue })
        .first(where: { $0.shape.count == 3 && $0.shape[1].intValue > 4 })
    else {
      BNLog.yoloe.warning("No valid detection tensor found in model output")
      return []
    }

    return decodeRawOutput(detArray)
  }

  /// Decodes the raw YOLOE output tensor into Detection structs with NMS.
  /// Tensor shape: [1, 4 + numClasses + maskCoeffs, numPredictions]
  private func decodeRawOutput(_ output: MLMultiArray) -> [Detection] {
    let numFeatures = output.shape[1].intValue
    let numPredictions = output.shape[2].intValue
    let numClasses = Self.classLabels.count
    let maskCoeffs = numFeatures - 4 - numClasses

    guard numClasses > 0, maskCoeffs >= 0 else {
      BNLog.yoloe.error(
        "Unexpected output shape: features=\(numFeatures), expected 4+\(numClasses)+masks")
      return []
    }

    let s1 = output.strides[1].intValue  // feature stride
    let s2 = output.strides[2].intValue  // prediction stride

    // Type-safe float reader handles Float32, Float16, or fallback
    let readFloat: (Int, Int) -> Float
    switch output.dataType {
    case .float32:
      let ptr = output.dataPointer.assumingMemoryBound(to: Float.self)
      readFloat = { f, p in ptr[f * s1 + p * s2] }
    case .float16:
      let ptr = output.dataPointer.assumingMemoryBound(to: Float16.self)
      readFloat = { f, p in Float(ptr[f * s1 + p * s2]) }
    default:
      readFloat = { f, p in output[[0, f, p] as [NSNumber]].floatValue }
    }

    var candidates: [Detection] = []

    for p in 0..<numPredictions {
      var bestIdx = 0
      var bestScore: Float = -Float.infinity
      for c in 0..<numClasses {
        let score = readFloat(4 + c, p)
        if score > bestScore {
          bestScore = score
          bestIdx = c
        }
      }

      guard bestScore >= BNConstants.yoloeConfidenceThreshold else { continue }

      let cx = readFloat(0, p)
      let cy = readFloat(1, p)
      let bw = readFloat(2, p)
      let bh = readFloat(3, p)

      // Model input is BCHW: (1, 3, H=736, W=414) per imgsz=[736, 414]
      let inputW: Float = 414
      let inputH: Float = 736
      let normW = bw / inputW
      let normH = bh / inputH
      let normCx = cx / inputW
      let normCy = cy / inputH

      // Vision coordinate space: origin bottom-left, y-up
      let visionX = max(0, normCx - normW / 2)
      let visionY = max(0, (1.0 - normCy) - normH / 2)

      let bbox = CGRect(
        x: CGFloat(visionX),
        y: CGFloat(visionY),
        width: CGFloat(min(normW, 1.0)),
        height: CGFloat(min(normH, 1.0))
      )

      let label =
        bestIdx < Self.classLabels.count
        ? Self.classLabels[bestIdx]
        : "class_\(bestIdx)"

      candidates.append(
        Detection(
          label: label,
          confidence: bestScore,
          boundingBox: bbox,
          centerNormalized: SIMD2<Float>(normCx, normCy)
        ))
    }

    candidates.sort { $0.confidence > $1.confidence }
    return applyNMS(candidates)
  }

  // MARK: - Non-maximum suppression

  private func applyNMS(_ detections: [Detection]) -> [Detection] {
    var kept: [Detection] = []
    var suppressed = Set<Int>()

    for i in 0..<detections.count {
      guard !suppressed.contains(i) else { continue }
      kept.append(detections[i])

      for j in (i + 1)..<detections.count {
        guard !suppressed.contains(j) else { continue }
        if iou(detections[i].boundingBox, detections[j].boundingBox) > CGFloat(Self.nmsIoUThreshold)
        {
          suppressed.insert(j)
        }
      }
    }
    return kept
  }

  private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let intersection = a.intersection(b)
    guard !intersection.isNull else { return 0 }
    let interArea = intersection.width * intersection.height
    let unionArea = a.width * a.height + b.width * b.height - interArea
    return unionArea > 0 ? interArea / unionArea : 0
  }

  // MARK: - Process parsed detections (goal matching)

  private func processDetections(_ allDetections: [Detection]) {
    let filtered = allDetections.filter {
      $0.confidence >= BNConstants.yoloeConfidenceThreshold
    }

    if let prompt = secondaryGoalPrompt {
      let match = findBestMatch(for: prompt, in: filtered)
      updateTrackedInstance(
        &secondaryGoalInstance,
        detection: match,
        publisher: secondaryGoalDetectionPublisher,
        label: "secondary goal"
      )
    }

    if let prompt = finalDestinationPrompt {
      let match = findBestMatch(for: prompt, in: filtered)
      updateTrackedInstance(
        &finalDestinationInstance,
        detection: match,
        publisher: finalDestinationDetectionPublisher,
        label: "final destination"
      )
    }
  }

  /// Fuzzy-match a text prompt against detection labels.
  private func findBestMatch(for prompt: String, in detections: [Detection]) -> Detection? {
    let promptWords = Set(prompt.lowercased().split(separator: " ").map(String.init))

    var bestMatch: Detection?
    var bestScore: Float = 0

    for detection in detections {
      let labelWords = Set(detection.label.lowercased().split(separator: " ").map(String.init))
      let overlap = Float(promptWords.intersection(labelWords).count)
      let score = overlap / max(Float(promptWords.count), 1.0) * detection.confidence

      if score > bestScore {
        bestScore = score
        bestMatch = detection
      }
    }

    if bestMatch == nil {
      bestMatch = detections.first { detection in
        detection.label.lowercased().contains(prompt.lowercased().prefix(10))
      }
    }

    return bestMatch
  }

  // MARK: - Instance tracking with phantom coordinates

  private func updateTrackedInstance(
    _ instance: inout TrackedInstance?,
    detection: Detection?,
    publisher: PassthroughSubject<TrackedInstance?, Never>,
    label: String
  ) {
    guard var tracked = instance else { return }

    if let detection {
      tracked.isVisible = true
      tracked.lastDetection = detection
      tracked.lastSeenTime = Date()
      tracked.worldPosition = nil

      if !instance!.isVisible {
        BNLog.yoloe.info(
          "\(label) re-acquired: '\(tracked.descriptor)' at confidence \(detection.confidence)")
      }
    } else {
      if tracked.isVisible {
        BNLog.yoloe.info(
          "\(label) lost from frame: '\(tracked.descriptor)'. Using phantom coordinate.")
        tracked.isVisible = false
      }
    }

    instance = tracked
    publisher.send(tracked)
  }

  // MARK: - Single-image inference (for testing)

  func detect(in image: UIImage) async -> [Detection] {
    guard let model else {
      BNLog.yoloe.error("detect(in:) called but model is not loaded")
      return []
    }

    guard let cgImage = image.cgImage else {
      BNLog.yoloe.error("detect(in:) — failed to get CGImage from UIImage")
      return []
    }

    return await withCheckedContinuation { continuation in
      inferenceQueue.async { [weak self] in
        guard let self else {
          continuation.resume(returning: [])
          return
        }

        let request = VNCoreMLRequest(model: model) { request, error in
          if let error {
            BNLog.yoloe.error("detect(in:) inference error: \(error.localizedDescription)")
            continuation.resume(returning: [])
            return
          }

          let detections = self.parseResults(request.results)
          continuation.resume(returning: detections)
        }
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
          try handler.perform([request])
        } catch {
          BNLog.yoloe.error("detect(in:) handler failed: \(error.localizedDescription)")
          continuation.resume(returning: [])
        }
      }
    }
  }

  // MARK: - Distance estimation (SLAM disabled - simplified)

  func distanceToInstance(_ instance: TrackedInstance?) -> Float? {
    guard let detection = instance?.lastDetection else { return nil }
    let boxArea = Float(detection.boundingBox.width * detection.boundingBox.height)
    return max(0.2, 5.0 * (1.0 - boxArea))
  }

  func directionToInstance(_ instance: TrackedInstance?) -> SIMD3<Float>? {
    guard let detection = instance?.lastDetection else { return nil }
    let centerX = Float(detection.boundingBox.midX) - 0.5
    let centerY = 0.5 - Float(detection.boundingBox.midY)
    return normalize(SIMD3<Float>(centerX * 2.0, centerY * 0.5, -1.0))
  }
}
