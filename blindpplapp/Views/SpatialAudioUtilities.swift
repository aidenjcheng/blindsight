import AVFoundation
import CoreGraphics
import UIKit
import simd

struct SpatialAudioAudioGenerator {
 nonisolated static func generateClick(
  frequency: Double,
  duration: Double,
  format: AVAudioFormat
 ) -> AVAudioPCMBuffer? {
  let sampleRate = format.sampleRate
  let frameCount = AVAudioFrameCount(sampleRate * duration)
  guard frameCount > 0 else { return nil }
  guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
   return nil
  }
  buffer.frameLength = frameCount
  guard let data = buffer.floatChannelData?[0] else { return nil }

  for i in 0..<Int(frameCount) {
   let t = Double(i) / sampleRate
   let envelope = exp(-t * 80.0)
   let fundamental = sin(2.0 * .pi * frequency * t)
   let harm2 = sin(2.0 * .pi * frequency * 2.0 * t) * 0.3
   data[i] = Float((fundamental + harm2) * envelope * 0.85)
  }
  return buffer
 }
}

struct SpatialAudioProjectionHelper {
 nonisolated static func transformedNormalizedRect(from bbox: CGRect) -> CGRect {
  let points = [
   CGPoint(x: bbox.minX, y: bbox.minY),
   CGPoint(x: bbox.maxX, y: bbox.minY),
   CGPoint(x: bbox.maxX, y: bbox.maxY),
   CGPoint(x: bbox.minX, y: bbox.maxY),
  ]
  let mapped = points.map { CGPoint(x: 1.0 - $0.x, y: 1.0 - $0.y) }
  let xs = mapped.map { $0.x }
  let ys = mapped.map { $0.y }
  guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
   return bbox
  }
  return CGRect(
   x: max(0, min(1, minX)),
   y: max(0, min(1, minY)),
   width: max(0, min(1, maxX) - max(0, min(1, minX))),
   height: max(0, min(1, maxY) - max(0, min(1, minY)))
  )
 }
}

extension CGAffineTransform {
 func invertedOrNil() -> CGAffineTransform? {
  if isIdentity { return self }
  if abs(a * d - b * c) < 0.0000001 { return nil }
  return inverted()
 }
}

extension CGImagePropertyOrientation {
 var debugName: String {
  switch self {
  case .up: return "up"
  case .upMirrored: return "upMirrored"
  case .down: return "down"
  case .downMirrored: return "downMirrored"
  case .left: return "left"
  case .leftMirrored: return "leftMirrored"
  case .right: return "right"
  case .rightMirrored: return "rightMirrored"
  @unknown default: return "unknown"
  }
 }
}
