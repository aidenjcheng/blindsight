import Foundation
import CoreML
import Vision
import Combine
import os

// MARK: - Runs MobileNetV4-Small ground segmentation to identify walkable floor areas

@MainActor
final class GroundSegmentationService: ObservableObject {

    // MARK: - Output

    /// Binary ground mask: 2D array of probabilities (0.0 = not ground, 1.0 = ground)
    struct GroundMask {
        let mask: [[Float]]
        let width: Int
        let height: Int
        let timestamp: Date

        /// Checks if the area directly in front of the user (bottom-center of frame) is ground.
        /// Returns a safety ratio: 1.0 = fully safe, 0.0 = no ground detected ahead.
        func groundSafetyAhead() -> Float {
            guard height > 0, width > 0 else { return 0 }

            // Sample the bottom-center region (where the user is about to step)
            let yStart = Int(Float(height) * 0.6)
            let yEnd = height
            let xStart = Int(Float(width) * 0.3)
            let xEnd = Int(Float(width) * 0.7)

            var groundPixels: Float = 0
            var totalPixels: Float = 0

            for y in yStart..<yEnd {
                for x in xStart..<xEnd {
                    totalPixels += 1
                    if mask[y][x] > 0.5 {
                        groundPixels += 1
                    }
                }
            }

            guard totalPixels > 0 else { return 0 }
            return groundPixels / totalPixels
        }

        /// Returns the boundary direction if ground is disappearing on one side.
        /// Useful for warning the user they're veering off the walkable path.
        func groundBoundaryWarning() -> SIMD3<Float>? {
            guard height > 0, width > 0 else { return nil }

            let yStart = Int(Float(height) * 0.5)
            let yEnd = height
            let midX = width / 2

            var leftGround: Float = 0
            var rightGround: Float = 0
            var count: Float = 0

            for y in yStart..<yEnd {
                for x in 0..<midX {
                    if mask[y][x] > 0.5 { leftGround += 1 }
                    count += 1
                }
                for x in midX..<width {
                    if mask[y][x] > 0.5 { rightGround += 1 }
                }
            }

            guard count > 0 else { return nil }
            let leftRatio = leftGround / count
            let rightRatio = rightGround / count

            // If one side has significantly less ground, warn in that direction
            let threshold: Float = 0.3
            if leftRatio < threshold && rightRatio > threshold {
                return SIMD3<Float>(-1, 0, 0)  // Ground disappearing on the left
            } else if rightRatio < threshold && leftRatio > threshold {
                return SIMD3<Float>(1, 0, 0)   // Ground disappearing on the right
            }
            return nil
        }
    }

    let groundMaskPublisher = PassthroughSubject<GroundMask, Never>()

    // MARK: - State

    @Published private(set) var isModelLoaded = false
    @Published private(set) var lastInferenceTimeMs: Double = 0

    // MARK: - Private

    private var model: VNCoreMLModel?
    private let inferenceQueue = DispatchQueue(label: "com.blindnav.groundseg", qos: .userInitiated)
    private var cancellables = Set<AnyCancellable>()

    private var frameCounter = 0
    private var processEveryNFrames = 12  // Dynamic based on performance mode

    // Update frame skipping based on performance mode
    func updatePerformanceMode(_ mode: BNConstants.PerformanceMode) {
        switch mode {
        case .balanced:
            processEveryNFrames = 12
        case .performance:
            processEveryNFrames = 8
        case .battery:
            processEveryNFrames = 15
        }
        BNLog.groundSeg.info("Ground segmentation frame skipping set to 1/\(self.processEveryNFrames) for \(mode.description)")
    }

    // MARK: - Init

    func loadModel() {
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            BNLog.groundSeg.info("Loading GroundSegMNV4Small CoreML model...")

            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all

                guard let modelURL = Bundle.main.url(
                    forResource: "GroundSegMNV4Small",
                    withExtension: "mlmodelc"
                ) else {
                    BNLog.groundSeg.error("GroundSegMNV4Small.mlmodelc not found in bundle. Run the conversion script first.")
                    return
                }

                let coreMLModel = try MLModel(contentsOf: modelURL, configuration: config)
                let vnModel = try VNCoreMLModel(for: coreMLModel)

                self.model = vnModel
                DispatchQueue.main.async {
                    self.isModelLoaded = true
                    BNLog.groundSeg.info("Ground segmentation model loaded successfully")
                }
            } catch {
                BNLog.groundSeg.error("Failed to load ground seg model: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Subscribe

    func subscribe(to framePublisher: PassthroughSubject<CVPixelBuffer, Never>) {
        framePublisher
            .receive(on: inferenceQueue)
            .sink { [weak self] pixelBuffer in
                self?.processFrame(pixelBuffer)
            }
            .store(in: &cancellables)
        BNLog.groundSeg.info("Subscribed to camera frame publisher")
    }

    // MARK: - Inference

    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        frameCounter += 1
        guard frameCounter % processEveryNFrames == 0 else { return }
        guard let model else { return }

        // Validate pixel buffer before processing
        guard PixelBufferUtils.isValid(pixelBuffer) else {
            BNLog.groundSeg.warning("Invalid pixel buffer, skipping frame")
            return
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        let request = VNCoreMLRequest(model: model) { [weak self] request, error in
            guard let self else { return }

            if let error {
                BNLog.groundSeg.error("Ground seg inference error: \(error.localizedDescription)")
                return
            }

            guard let results = request.results as? [VNCoreMLFeatureValueObservation],
                  let maskMultiArray = results.first?.featureValue.multiArrayValue else {
                BNLog.groundSeg.warning("No ground seg output from model")
                return
            }

            // Copy the multiArray data immediately to avoid memory access issues
            let copiedMap = self.copyMultiArray(maskMultiArray)
            let groundMask = self.copiedDataToGroundMask(copiedMap)
            self.groundMaskPublisher.send(groundMask)

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            DispatchQueue.main.async {
                self.lastInferenceTimeMs = elapsed
            }
        }

        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            BNLog.groundSeg.error("Ground seg VNImageRequestHandler failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Conversion

    // Safely copy MLMultiArray data to prevent EXC_BAD_ACCESS
    private func copyMultiArray(_ multiArray: MLMultiArray) -> (data: [Float], height: Int, width: Int) {
        let shape = multiArray.shape.map { $0.intValue }

        // Expected output: [1, 1, H, W] or [1, H, W] or [H, W]
        let height: Int
        let width: Int
        if shape.count == 4 {
            height = shape[2]
            width = shape[3]
        } else if shape.count == 3 {
            height = shape[1]
            width = shape[2]
        } else if shape.count == 2 {
            height = shape[0]
            width = shape[1]
        } else {
            BNLog.groundSeg.error("Unexpected ground seg output shape: \(shape)")
            return ([], 0, 0)
        }

        let count = height * width
        var data = [Float](repeating: 0, count: count)

        // Copy data safely using indexed access
        multiArray.withUnsafeMutableBytes { rawPtr, _ in
            guard let ptr = rawPtr.baseAddress?.assumingMemoryBound(to: Float.self) else {
                return
            }
            for i in 0..<count {
                data[i] = ptr[i]
            }
        }

        return (data, height, width)
    }

    private func copiedDataToGroundMask(_ copied: (data: [Float], height: Int, width: Int)) -> GroundMask {
        let (data, height, width) = copied
        guard height > 0, width > 0 else {
            return GroundMask(mask: [], width: 0, height: 0, timestamp: Date())
        }

        var mask: [[Float]] = []
        mask.reserveCapacity(height)

        for y in 0..<height {
            var row: [Float] = []
            row.reserveCapacity(width)
            for x in 0..<width {
                row.append(data[y * width + x])
            }
            mask.append(row)
        }

        return GroundMask(mask: mask, width: width, height: height, timestamp: Date())
    }

    private func multiArrayToGroundMask(_ multiArray: MLMultiArray) -> GroundMask {
        let copied = copyMultiArray(multiArray)
        return copiedDataToGroundMask(copied)
    }
}
