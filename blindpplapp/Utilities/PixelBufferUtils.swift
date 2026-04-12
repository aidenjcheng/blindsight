import Foundation
import CoreVideo
import Accelerate

// MARK: - Safe CVPixelBuffer handling utilities

enum PixelBufferUtils {

    /// Creates a deep copy of a CVPixelBuffer to prevent EXC_BAD_ACCESS when used asynchronously.
    /// This is critical for Vision requests that process after the camera callback returns.
    static func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        var dest: CVPixelBuffer?

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &dest
        )

        guard status == kCVReturnSuccess, let dest else {
            return nil
        }

        // Lock both buffers
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dest, [])

        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(dest, [])
        }

        // Copy each plane
        let planeCount = CVPixelBufferGetPlaneCount(source)

        if planeCount == 0 {
            // Planar (single plane) - e.g., 32BGRA
            guard let srcData = CVPixelBufferGetBaseAddress(source),
                  let dstData = CVPixelBufferGetBaseAddress(dest) else {
                return nil
            }

            let srcBytes = CVPixelBufferGetBytesPerRow(source)
            let dstBytes = CVPixelBufferGetBytesPerRow(dest)

            for row in 0..<height {
                let srcOffset = row * srcBytes
                let dstOffset = row * dstBytes
                let srcPtr = srcData.advanced(by: srcOffset)
                let dstPtr = dstData.advanced(by: dstOffset)
                dstPtr.copyMemory(from: srcPtr, byteCount: min(srcBytes, dstBytes))
            }
        } else {
            // Bi-planar (e.g., YUV 420) - copy each plane separately
            for plane in 0..<planeCount {
                guard let srcData = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dstData = CVPixelBufferGetBaseAddressOfPlane(dest, plane) else {
                    return nil
                }

                let srcBytes = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let dstBytes = CVPixelBufferGetBytesPerRowOfPlane(dest, plane)
                let srcHeight = CVPixelBufferGetHeightOfPlane(source, plane)
                let dstHeight = CVPixelBufferGetHeightOfPlane(dest, plane)

                for row in 0..<min(srcHeight, dstHeight) {
                    let srcOffset = row * srcBytes
                    let dstOffset = row * dstBytes
                    let srcPtr = srcData.advanced(by: srcOffset)
                    let dstPtr = dstData.advanced(by: dstOffset)
                    dstPtr.copyMemory(from: srcPtr, byteCount: min(srcBytes, dstBytes))
                }
            }
        }

        // Copy attachments
        if let attachments = CVBufferCopyAttachments(source, .shouldPropagate) as? [String: Any] {
            CVBufferSetAttachments(dest, attachments as CFDictionary, .shouldPropagate)
        }

        return dest
    }

    /// Checks if a pixel buffer is valid and safe to access
    static func isValid(_ buffer: CVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        return width > 0 && height > 0
    }
}
