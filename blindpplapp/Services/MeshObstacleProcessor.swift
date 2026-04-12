import ARKit
import Foundation
import simd

// MARK: - Extracts nearby obstacles from ARKit mesh anchors in world coordinates

struct MeshObstacle {
 /// World-space position of the obstacle
 let worldPosition: SIMD3<Float>
 /// Distance from the camera in meters
 let distance: Float
 /// Direction vector from camera to obstacle (normalized)
 let direction: SIMD3<Float>
 /// Mesh classification if available (wall, floor, ceiling, etc.)
 let classification: ARMeshClassification
}

final class MeshObstacleProcessor {

 /// Maximum distance to scan for obstacles (meters)
 var maxScanRange: Float = 5.0

 /// Minimum height relative to camera for obstacles to consider.
 /// Negative = below camera level. Filters out floor geometry.
 var minObstacleHeightRelativeToCamera: Float = -0.8

 /// Maximum height relative to camera. Filters out ceiling geometry.
 var maxObstacleHeightRelativeToCamera: Float = 1.5

 /// Stride for vertex sampling — skip vertices for performance.
 /// 1 = every vertex, 3 = every 3rd vertex, etc.
 var vertexSamplingStride: Int = 3

 /// When false, floor/ceiling mesh is also used (e.g. spatial-audio test / full-room sonification).
 var skipFloorAndCeilingClassifications: Bool = true

 /// Minimum dot(cameraForward, directionToVertex). Lower = wider field (e.g. -0.5 hears sides/behind).
 var minForwardDotForInclusion: Float = -0.2

 /// Scans all mesh anchors and returns obstacles within range, sorted by distance.
 func findNearbyObstacles(
  meshAnchors: [ARMeshAnchor],
  cameraTransform: simd_float4x4,
  maxResults: Int = 20
 ) -> [MeshObstacle] {
  let cameraPosition = SIMD3<Float>(
   cameraTransform.columns.3.x,
   cameraTransform.columns.3.y,
   cameraTransform.columns.3.z
  )

  let cameraForward = normalize(
   SIMD3<Float>(
    -cameraTransform.columns.2.x,
    -cameraTransform.columns.2.y,
    -cameraTransform.columns.2.z
   ))

  var obstacles: [MeshObstacle] = []

  for anchor in meshAnchors {
   let anchorTransform = anchor.transform
   let geometry = anchor.geometry
   let vertices = geometry.vertices
   let vertexCount = vertices.count

   guard vertexCount > 0 else { continue }

   // Quick bounding check: skip anchors that are too far from camera
   let anchorPos = SIMD3<Float>(
    anchorTransform.columns.3.x,
    anchorTransform.columns.3.y,
    anchorTransform.columns.3.z
   )
   let anchorDist = length(anchorPos - cameraPosition)
   if anchorDist > maxScanRange + 3.0 { continue }

   let vertexBuffer = vertices.buffer
   let vertexStride = vertices.stride
   let classificationSource = geometry.classification

   for i in stride(from: 0, to: vertexCount, by: vertexSamplingStride) {
    let vertexPointer = vertexBuffer.contents()
     .advanced(by: vertices.offset + i * vertexStride)
    let localVertex =
     vertexPointer
     .assumingMemoryBound(to: SIMD3<Float>.self)
     .pointee

    // Transform vertex from anchor-local space to world space
    let localPoint = SIMD4<Float>(localVertex.x, localVertex.y, localVertex.z, 1.0)
    let worldPoint4 = anchorTransform * localPoint
    let worldPoint = SIMD3<Float>(worldPoint4.x, worldPoint4.y, worldPoint4.z)

    let toVertex = worldPoint - cameraPosition
    let dist = length(toVertex)

    // Cylinder detection: limit by horizontal distance to encompass the space below the phone
    let horizontalDist = length(SIMD2<Float>(toVertex.x, toVertex.z))
    guard horizontalDist > 0.15, horizontalDist < maxScanRange else { continue }

    let heightDelta = worldPoint.y - cameraPosition.y
    guard heightDelta > minObstacleHeightRelativeToCamera,
     heightDelta < maxObstacleHeightRelativeToCamera
    else { continue }

    let dirNorm = toVertex / dist
    let dotForward = dot(dirNorm, cameraForward)

    // Relax forward check for points directly below the user in the cylinder
    if horizontalDist > 0.5 {
     guard dotForward > minForwardDotForInclusion else { continue }
    }

    var classification = ARMeshClassification.none
    if let classSource = classificationSource {
     let faceIndex = i / 3
     if faceIndex < classSource.count {
      let rawValue = classSource.buffer.contents()
       .advanced(by: faceIndex)
       .assumingMemoryBound(to: UInt8.self).pointee
      classification = ARMeshClassification(rawValue: Int(rawValue)) ?? .none
     }
    }

    if skipFloorAndCeilingClassifications,
     classification == .floor || classification == .ceiling
    {
     continue
    }

    obstacles.append(
     MeshObstacle(
      worldPosition: worldPoint,
      distance: dist,
      direction: dirNorm,
      classification: classification
     ))
   }
  }

  obstacles.sort { $0.distance < $1.distance }
  return Array(obstacles.prefix(maxResults))
 }

 /// Finds the closest obstacle in each angular zone relative to the camera's forward direction.
 /// Returns obstacles binned into left/center/right (or more) zones for spatial audio placement.
 func findZonedObstacles(
  meshAnchors: [ARMeshAnchor],
  cameraTransform: simd_float4x4,
  numZones: Int = 5
 ) -> [ZonedObstacle] {
  let cameraPosition = SIMD3<Float>(
   cameraTransform.columns.3.x,
   cameraTransform.columns.3.y,
   cameraTransform.columns.3.z
  )

  let cameraForward = normalize(
   SIMD3<Float>(
    -cameraTransform.columns.2.x,
    -cameraTransform.columns.2.y,
    -cameraTransform.columns.2.z
   ))

  let cameraRight = normalize(
   SIMD3<Float>(
    cameraTransform.columns.0.x,
    cameraTransform.columns.0.y,
    cameraTransform.columns.0.z
   ))

  var zoneBins: [Int: MeshObstacle] = [:]

  for anchor in meshAnchors {
   let anchorTransform = anchor.transform
   let geometry = anchor.geometry
   let vertices = geometry.vertices
   let vertexCount = vertices.count

   guard vertexCount > 0 else { continue }

   let anchorPos = SIMD3<Float>(
    anchorTransform.columns.3.x,
    anchorTransform.columns.3.y,
    anchorTransform.columns.3.z
   )
   if length(anchorPos - cameraPosition) > maxScanRange + 3.0 { continue }

   for i in stride(from: 0, to: vertexCount, by: vertexSamplingStride) {
    let vertexPointer = geometry.vertices.buffer.contents()
     .advanced(by: vertices.offset + i * vertices.stride)
    let localVertex =
     vertexPointer
     .assumingMemoryBound(to: SIMD3<Float>.self)
     .pointee

    let localPoint = SIMD4<Float>(localVertex.x, localVertex.y, localVertex.z, 1.0)
    let worldPoint4 = anchorTransform * localPoint
    let worldPoint = SIMD3<Float>(worldPoint4.x, worldPoint4.y, worldPoint4.z)

    let toVertex = worldPoint - cameraPosition
    let dist = length(toVertex)

    // Cylinder detection: limit by horizontal distance to encompass the space below the phone
    let horizontalDist = length(SIMD2<Float>(toVertex.x, toVertex.z))
    guard horizontalDist > 0.15, horizontalDist < maxScanRange else { continue }

    let heightDelta = worldPoint.y - cameraPosition.y
    guard heightDelta > minObstacleHeightRelativeToCamera,
     heightDelta < maxObstacleHeightRelativeToCamera
    else { continue }

    let dirNorm = toVertex / dist
    let dotForward = dot(dirNorm, cameraForward)

    // Relax forward check for points directly below the user in the cylinder
    if horizontalDist > 0.5 {
     guard dotForward > 0 else { continue }
    }

    // Project onto camera-right axis to determine lateral position
    let lateralDot = dot(dirNorm, cameraRight)
    // Map lateral position [-1, 1] to zone index [0, numZones-1]
    let normalizedLateral = (lateralDot + 1.0) / 2.0
    let zoneIndex = min(numZones - 1, max(0, Int(normalizedLateral * Float(numZones))))

    if let existing = zoneBins[zoneIndex] {
     if dist < existing.distance {
      zoneBins[zoneIndex] = MeshObstacle(
       worldPosition: worldPoint,
       distance: dist,
       direction: dirNorm,
       classification: .none
      )
     }
    } else {
     zoneBins[zoneIndex] = MeshObstacle(
      worldPosition: worldPoint,
      distance: dist,
      direction: dirNorm,
      classification: .none
     )
    }
   }
  }

  var result: [ZonedObstacle] = []
  for zone in 0..<numZones {
   let lateralOffset = (Float(zone) / Float(numZones - 1)) * 2.0 - 1.0
   if let obstacle = zoneBins[zone] {
    result.append(
     ZonedObstacle(
      zoneIndex: zone,
      lateralOffset: lateralOffset,
      obstacle: obstacle
     ))
   } else {
    result.append(
     ZonedObstacle(
      zoneIndex: zone,
      lateralOffset: lateralOffset,
      obstacle: nil
     ))
   }
  }

  return result
 }
}

struct ZonedObstacle {
 let zoneIndex: Int
 /// -1 = far left, 0 = center, +1 = far right
 let lateralOffset: Float
 /// Closest obstacle in this zone, or nil if zone is clear
 let obstacle: MeshObstacle?

 var distance: Float {
  obstacle?.distance ?? 100.0
 }
}
