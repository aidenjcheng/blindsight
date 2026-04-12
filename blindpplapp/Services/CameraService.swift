import Foundation
import AVFoundation
import Combine
import CoreImage
import UIKit
import os

// MARK: - Captures camera frames and distributes them to ML pipeline consumers
//
// NOT @MainActor: the AVCaptureVideoDataOutput delegate runs on processingQueue.
// Making this class @MainActor forces every delegate property access through an
// unsafeForcedSync hop, which deadlocks or crashes. Instead, processing state lives
// on the serial processingQueue, and @Published properties are updated explicitly
// on the main thread.

final class CameraService: NSObject, ObservableObject {

    // MARK: - Published outputs

    /// Latest pixel buffer for ML inference consumers
    let framePublisher = PassthroughSubject<CVPixelBuffer, Never>()

    /// Latest JPEG data for Gemini API (compressed snapshot)
    let snapshotPublisher = PassthroughSubject<Data, Never>()

    /// High-frequency UIImage for debug camera preview (bypasses JPEG encode/decode)
    let debugFramePublisher = PassthroughSubject<UIImage, Never>()

    @Published private(set) var isRunning = false
    @Published private(set) var hasFirstSnapshot = false

    // Pauses frame publishing to reduce ML pipeline load (e.g., when waiting for Gemini)
    // Accessed from main thread (write) and processingQueue (read) — benign race on a Bool flag.
    var isFramePublishingPaused = false

    /// Orientation to apply when converting pixel buffers to UIImage.
    /// `.right` rotates landscape-native ARFrame buffers to portrait.
    /// `.up` is used when AVCaptureSession already delivers portrait-rotated buffers.
    var imageOrientation: UIImage.Orientation = .up

    /// Corresponding Vision orientation for ML pipelines (YOLOE).
    var visionOrientation: CGImagePropertyOrientation = .up

    // MARK: - Private

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "com.blindnav.camera", qos: .userInitiated)
    private let ciContext = CIContext()

    // Throttle snapshot capture to avoid overwhelming Gemini
    // Only accessed from processingQueue (inside captureOutput delegate).
    private var lastSnapshotTime: Date = .distantPast
    private let snapshotInterval: TimeInterval = 0.5
    private var firstSnapshotCaptured = false

    // Throttle debug frames separately (much faster than Gemini snapshots)
    // Only accessed from processingQueue (inside captureOutput delegate).
    private var lastDebugFrameTime: Date = .distantPast
    private let debugFrameInterval: TimeInterval = 0.066  // ~15fps for debug view

    // MARK: - Lifecycle

    func configure() {
        BNLog.camera.info("Configuring camera session...")

        captureSession.beginConfiguration()
        // Use lower resolution preset to reduce ML pipeline load
        captureSession.sessionPreset = .hd1280x720

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            BNLog.camera.error("No back camera available")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            guard captureSession.canAddInput(input) else {
                BNLog.camera.error("Cannot add camera input to session")
                return
            }
            captureSession.addInput(input)

            // Lock to 30fps for consistent ML inference timing
            try camera.lockForConfiguration()
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(BNConstants.cameraFPS))
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(BNConstants.cameraFPS))
            camera.unlockForConfiguration()
            BNLog.camera.info("Camera locked to \(BNConstants.cameraFPS) fps")

        } catch {
            BNLog.camera.error("Camera input setup failed: \(error.localizedDescription)")
            return
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)

        guard captureSession.canAddOutput(videoOutput) else {
            BNLog.camera.error("Cannot add video output to session")
            return
        }
        captureSession.addOutput(videoOutput)

        // Lock orientation to portrait (phone on chest)
        if let connection = videoOutput.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            } else {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
            }
        }

        captureSession.commitConfiguration()
        BNLog.camera.info("Camera session configured successfully")
    }

    func start() {
        guard !captureSession.isRunning else {
            BNLog.camera.info("Camera already running")
            return
        }
        processingQueue.async { [weak self] in
            self?.captureSession.startRunning()
            DispatchQueue.main.async {
                self?.isRunning = true
                BNLog.camera.info("Camera session started")
            }
        }
    }

    func stop() {
        guard captureSession.isRunning else { return }
        processingQueue.async { [weak self] in
            self?.captureSession.stopRunning()
            DispatchQueue.main.async {
                self?.isRunning = false
                BNLog.camera.info("Camera session stopped")
            }
        }
    }

    // MARK: - Snapshot for Gemini

    /// Captures a JPEG-compressed snapshot of the current frame for Gemini API.
    private func captureSnapshot(from pixelBuffer: CVPixelBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastSnapshotTime) >= snapshotInterval else { return }
        lastSnapshotTime = now

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            BNLog.camera.error("Failed to create CGImage for snapshot")
            return
        }

        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: imageOrientation)
        // Compress to JPEG at 60% quality to keep Gemini payloads small
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.6) else {
            BNLog.camera.error("Failed to compress snapshot to JPEG")
            return
        }

        snapshotPublisher.send(jpegData)
        BNLog.camera.info("Snapshot published (\(jpegData.count) bytes)")

        // Mark first snapshot as captured
        if !firstSnapshotCaptured {
            firstSnapshotCaptured = true
            DispatchQueue.main.async {
                self.hasFirstSnapshot = true
            }
        }
    }

    // MARK: - Debug frame (fast path, no JPEG)

    /// Publishes a UIImage directly from the pixel buffer for debug visualization.
    /// Skips JPEG encode/decode entirely for near-realtime preview.
    private func captureDebugFrame(from pixelBuffer: CVPixelBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastDebugFrameTime) >= debugFrameInterval else { return }
        lastDebugFrameTime = now

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: imageOrientation)
        debugFramePublisher.send(uiImage)
    }

    // MARK: - External frame ingestion (from ARSession)

    /// Processes a pixel buffer provided externally (e.g., from ARSession's capturedImage).
    /// Deep-copies the buffer so ML consumers on other queues don't hit recycled memory.
    func processExternalFrame(_ pixelBuffer: CVPixelBuffer) {
        processingQueue.async { [weak self] in
            guard let self else { return }

            self.captureDebugFrame(from: pixelBuffer)

            guard !self.isFramePublishingPaused else {
                self.captureSnapshot(from: pixelBuffer)
                return
            }

            guard let copiedBuffer = PixelBufferUtils.copyPixelBuffer(pixelBuffer) else {
                BNLog.camera.error("Failed to copy external pixel buffer")
                self.captureSnapshot(from: pixelBuffer)
                return
            }

            self.framePublisher.send(copiedBuffer)
            self.captureSnapshot(from: pixelBuffer)
        }
    }

    // MARK: - Permission

    static func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            BNLog.camera.error("Camera permission denied (status: \(String(describing: status)))")
            return false
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            BNLog.camera.warning("Received sample buffer without image data")
            return
        }

        // CRITICAL: Create a deep copy of the pixel buffer to prevent EXC_BAD_ACCESS
        // The original buffer may be recycled by the camera after this callback returns,
        // but ML services process it asynchronously.
        guard let copiedBuffer = PixelBufferUtils.copyPixelBuffer(pixelBuffer) else {
            BNLog.camera.error("Failed to copy pixel buffer")
            return
        }

        // Always capture debug frames for near-realtime preview (lightweight, no JPEG)
        // Must use copiedBuffer — original pixelBuffer is recycled by AVFoundation after callback
        captureDebugFrame(from: copiedBuffer)

        // Only publish frames if not paused (reduces ML pipeline load when waiting for Gemini)
        guard !isFramePublishingPaused else {
            // Still capture snapshots for Gemini even when paused
            captureSnapshot(from: copiedBuffer)
            return
        }

        framePublisher.send(copiedBuffer)
        captureSnapshot(from: copiedBuffer)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        BNLog.camera.debug("Dropped frame — ML pipeline may be backlogged")
    }
}
