import ARKit
import SceneKit
import UIKit
import simd

struct SpatialAudioMeshBuilder {
 nonisolated static func buildScene(
  from anchors: [ARMeshAnchor],
  cameraTransform: simd_float4x4,
  cameraPath: [SIMD3<Float>],
  waypoint: SIMD3<Float>?,
  mirroredWaypoint: SIMD3<Float>?
 ) -> SCNScene {
  let scene = SCNScene()

  for anchor in anchors {
   guard let node = buildSCNNode(from: anchor) else { continue }
   scene.rootNode.addChildNode(node)
  }

  addCameraPath(to: scene.rootNode, points: cameraPath)

  let cameraSphere = SCNSphere(radius: 0.06)
  cameraSphere.firstMaterial?.diffuse.contents = UIColor.systemYellow
  cameraSphere.firstMaterial?.emission.contents = UIColor.systemYellow.withAlphaComponent(0.4)
  let cameraNode = SCNNode(geometry: cameraSphere)
  cameraNode.position = SCNVector3(
   cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
  scene.rootNode.addChildNode(cameraNode)

  if let waypoint {
   let goalGeo = SCNSphere(radius: 0.09)
   goalGeo.firstMaterial?.diffuse.contents = UIColor.systemPink
   goalGeo.firstMaterial?.emission.contents = UIColor.systemPink.withAlphaComponent(0.55)
   let goalNode = SCNNode(geometry: goalGeo)
   goalNode.position = SCNVector3(waypoint.x, waypoint.y, waypoint.z)
   scene.rootNode.addChildNode(goalNode)
  }

  if let mirroredWaypoint {
   let mirrorGeo = SCNSphere(radius: 0.09)
   mirrorGeo.firstMaterial?.diffuse.contents = UIColor.cyan
   mirrorGeo.firstMaterial?.emission.contents = UIColor.cyan.withAlphaComponent(0.55)
   let mirrorNode = SCNNode(geometry: mirrorGeo)
   mirrorNode.position = SCNVector3(mirroredWaypoint.x, mirroredWaypoint.y, mirroredWaypoint.z)
   scene.rootNode.addChildNode(mirrorNode)
  }

  let cameraPos = SIMD3<Float>(
   cameraTransform.columns.3.x, cameraTransform.columns.3.y + 4.0, cameraTransform.columns.3.z + 4.0
  )
  let camera = SCNCamera()
  camera.zNear = 0.1
  camera.zFar = 50
  camera.fieldOfView = 60
  let camNode = SCNNode()
  camNode.camera = camera
  camNode.position = SCNVector3(cameraPos.x, cameraPos.y, cameraPos.z)
  camNode.look(
   at: SCNVector3(
    cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z))
  scene.rootNode.addChildNode(camNode)

  let ambientLight = SCNNode()
  ambientLight.light = SCNLight()
  ambientLight.light?.type = .ambient
  ambientLight.light?.color = UIColor(white: 0.4, alpha: 1)
  scene.rootNode.addChildNode(ambientLight)

  let dirLight = SCNNode()
  dirLight.light = SCNLight()
  dirLight.light?.type = .directional
  dirLight.light?.color = UIColor(white: 0.8, alpha: 1)
  dirLight.light?.castsShadow = true
  dirLight.position = SCNVector3(0, 5, 5)
  dirLight.look(at: SCNVector3(0, 0, 0))
  scene.rootNode.addChildNode(dirLight)

  return scene
 }

 private nonisolated static func quaternionAligningYAxis(to direction: SIMD3<Float>) -> simd_quatf {
  let y = SIMD3<Float>(0, 1, 0)
  let d = simd_normalize(direction)
  let c = simd_cross(y, d)
  let clen = simd_length(c)
  if clen < 1e-5 {
   if simd_dot(y, d) > 0 { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
   return simd_quatf(ix: 1, iy: 0, iz: 0, r: 0)
  }
  let axis = c / clen
  let angle = acos(max(-1, min(1, simd_dot(y, d))))
  return simd_quatf(angle: angle, axis: axis)
 }

 private nonisolated static func addCameraPath(to root: SCNNode, points: [SIMD3<Float>]) {
  guard !points.isEmpty else { return }

  let sphereMat = SCNMaterial()
  sphereMat.diffuse.contents = UIColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 1.0)
  sphereMat.emission.contents = UIColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 0.4)
  sphereMat.lightingModel = .constant

  let tubeMat = SCNMaterial()
  tubeMat.diffuse.contents = UIColor(red: 0.95, green: 0.25, blue: 0.2, alpha: 1.0)
  tubeMat.emission.contents = UIColor(red: 0.95, green: 0.25, blue: 0.2, alpha: 0.35)
  tubeMat.lightingModel = .constant

  for p in points {
   let s = SCNSphere(radius: 0.035)
   s.materials = [sphereMat]
   let n = SCNNode(geometry: s)
   n.position = SCNVector3(p.x, p.y, p.z)
   root.addChildNode(n)
  }

  guard points.count >= 2 else { return }
  for i in 0..<(points.count - 1) {
   let a = points[i]
   let b = points[i + 1]
   let d = b - a
   let len = simd_length(d)
   guard len > 1e-4 else { continue }

   let cyl = SCNCylinder(radius: 0.018, height: CGFloat(len))
   cyl.materials = [tubeMat]
   let seg = SCNNode(geometry: cyl)
   let mid = (a + b) * 0.5
   seg.position = SCNVector3(mid.x, mid.y, mid.z)
   seg.simdOrientation = quaternionAligningYAxis(to: d)
   root.addChildNode(seg)
  }
 }

 private nonisolated static func buildSCNNode(from anchor: ARMeshAnchor) -> SCNNode? {
  let geometry = anchor.geometry
  let vertices = geometry.vertices
  let faces = geometry.faces
  let vertexCount = vertices.count
  let faceCount = faces.count
  guard vertexCount > 0, faceCount > 0 else { return nil }

  var scnVertices: [SCNVector3] = []
  scnVertices.reserveCapacity(vertexCount)
  for i in 0..<vertexCount {
   let ptr = vertices.buffer.contents().advanced(by: vertices.offset + i * vertices.stride)
   let v = ptr.assumingMemoryBound(to: SIMD3<Float>.self).pointee
   scnVertices.append(SCNVector3(v.x, v.y, v.z))
  }

  let normals = geometry.normals
  var scnNormals: [SCNVector3] = []
  scnNormals.reserveCapacity(normals.count)
  for i in 0..<normals.count {
   let ptr = normals.buffer.contents().advanced(by: normals.offset + i * normals.stride)
   let n = ptr.assumingMemoryBound(to: SIMD3<Float>.self).pointee
   scnNormals.append(SCNVector3(n.x, n.y, n.z))
  }

  let indexCountPerFace = faces.indexCountPerPrimitive
  let bytesPerIndex = faces.bytesPerIndex
  var indices: [UInt32] = []
  indices.reserveCapacity(faceCount * indexCountPerFace)

  for f in 0..<faceCount {
   for j in 0..<indexCountPerFace {
    let offset = (f * indexCountPerFace + j) * bytesPerIndex
    let ptr = faces.buffer.contents().advanced(by: offset)
    let index: UInt32 =
     bytesPerIndex == 4
     ? ptr.assumingMemoryBound(to: UInt32.self).pointee
     : UInt32(ptr.assumingMemoryBound(to: UInt16.self).pointee)
    indices.append(index)
   }
  }

  var colors: [UIColor] = Array(
   repeating: SpatialAudioMeshColorizer.classificationFallbackGray(), count: vertexCount)
  if let classification = geometry.classification {
   for f in 0..<min(faceCount, classification.count) {
    let rawValue = classification.buffer.contents().advanced(by: f).assumingMemoryBound(
     to: UInt8.self
    ).pointee
    let meshClass = ARMeshClassification(rawValue: Int(rawValue)) ?? .none
    let color = SpatialAudioMeshColorizer.colorForClassification(meshClass)
    for j in 0..<indexCountPerFace {
     let idx = Int(indices[f * indexCountPerFace + j])
     if idx < vertexCount { colors[idx] = color }
    }
   }
  }

  let vertexSource = SCNGeometrySource(vertices: scnVertices)
  let normalSource = SCNGeometrySource(normals: scnNormals)

  var colorFloats: [Float] = []
  colorFloats.reserveCapacity(vertexCount * 4)
  for color in colors {
   let rgba = SpatialAudioMeshColorizer.floatRGBAComponents(color)
   colorFloats.append(rgba.x)
   colorFloats.append(rgba.y)
   colorFloats.append(rgba.z)
   colorFloats.append(rgba.w)
  }
  let colorData = colorFloats.withUnsafeBytes { Data($0) }

  let colorSource = SCNGeometrySource(
   data: colorData,
   semantic: .color,
   vectorCount: vertexCount,
   usesFloatComponents: true,
   componentsPerVector: 4,
   bytesPerComponent: MemoryLayout<Float>.size,
   dataOffset: 0,
   dataStride: MemoryLayout<Float>.size * 4
  )

  let indexData = indices.withUnsafeBytes { Data($0) }
  let element = SCNGeometryElement(
   data: indexData,
   primitiveType: .triangles,
   primitiveCount: faceCount,
   bytesPerIndex: MemoryLayout<UInt32>.size
  )

  let scnGeometry = SCNGeometry(
   sources: [vertexSource, normalSource, colorSource], elements: [element])
  let material = SCNMaterial()
  material.isDoubleSided = true
  material.lightingModel = .constant
  material.diffuse.contents = UIColor.white
  material.transparency = 0.92
  scnGeometry.materials = [material]

  let node = SCNNode(geometry: scnGeometry)
  node.simdTransform = anchor.transform
  return node
 }
}

struct SpatialAudioMeshColorizer {
 nonisolated static func classificationFallbackGray() -> UIColor {
  UIColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 1.0)
 }

 nonisolated static func floatRGBAComponents(_ color: UIColor) -> SIMD4<Float> {
  let c = color.cgColor
  guard let comps = c.components else { return SIMD4<Float>(0.55, 0.55, 0.58, 1) }
  switch c.numberOfComponents {
  case 4: return SIMD4<Float>(Float(comps[0]), Float(comps[1]), Float(comps[2]), Float(comps[3]))
  case 2: return SIMD4<Float>(Float(comps[0]), Float(comps[0]), Float(comps[0]), Float(comps[1]))
  case 3: return SIMD4<Float>(Float(comps[0]), Float(comps[1]), Float(comps[2]), 1)
  default: return SIMD4<Float>(0.55, 0.55, 0.58, 1)
  }
 }

 nonisolated static func colorForClassification(_ classification: ARMeshClassification) -> UIColor {
  switch classification {
  case .wall: return UIColor(red: 0.25, green: 0.45, blue: 0.95, alpha: 1.0)
  case .floor: return UIColor(red: 0.2, green: 0.75, blue: 0.35, alpha: 1.0)
  case .ceiling: return UIColor(red: 0.65, green: 0.65, blue: 0.68, alpha: 1.0)
  case .table: return UIColor(red: 0.95, green: 0.55, blue: 0.2, alpha: 1.0)
  case .seat: return UIColor(red: 0.2, green: 0.72, blue: 0.75, alpha: 1.0)
  case .door: return UIColor(red: 0.65, green: 0.35, blue: 0.9, alpha: 1.0)
  case .window: return UIColor(red: 0.35, green: 0.85, blue: 0.95, alpha: 1.0)
  case .none: return classificationFallbackGray()
  @unknown default: return classificationFallbackGray()
  }
 }
}
