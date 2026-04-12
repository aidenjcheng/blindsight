// SLAM functionality disabled - entire file commented out
//
// import Foundation
// import simd
//
// // MARK: - Lightweight visited-area map built from ARKit poses
//
// struct SLAMMap {
//     /// Grid cell that the user has visited. Keyed by discretized (x, z) grid coordinates.
//     private(set) var visitedCells: [GridCell: Int] = [:]
//     /// Chronological path of user poses
//     private(set) var pathHistory: [(position: SIMD3<Float>, timestamp: Date)] = []
//     /// Current device pose from ARKit
//     var currentPose: simd_float4x4?
//
//     struct GridCell: Hashable {
//         let x: Int
//         let z: Int
//     }
//
//     // MARK: - Update
//
//     mutating func recordPose(position: SIMD3<Float>, timestamp: Date) {
//         pathHistory.append((position: position, timestamp: timestamp))
//         let cellX = Int(floor(position.x / BNConstants.slamGridCellSize))
//         let cellZ = Int(floor(position.z / BNConstants.slamGridCellSize))
//         let cell = GridCell(x: cellX, z: cellZ)
//         visitedCells[cell, default: 0] += 1
//     }
//
//     // MARK: - Circle detection
//
//     func isCircleDetected() -> Bool {
//         let threshold = BNConstants.circleDetectionThreshold
//         let recentCells = pathHistory.suffix(50).map { pos -> GridCell in
//             GridCell(
//                 x: Int(floor(pos.position.x / BNConstants.slamGridCellSize)),
//                 z: Int(floor(pos.position.z / BNConstants.slamGridCellSize))
//             )
//         }
//         var frequency: [GridCell: Int] = [:]
//         for cell in recentCells {
//             frequency[cell, default: 0] += 1
//         }
//         return frequency.values.contains(where: { $0 >= threshold })
//     }
//
//     // MARK: - Text summary for Gemini
//
//     func textSummary() -> String {
//         guard !pathHistory.isEmpty else {
//             return "User has not moved yet. Standing at the starting position."
//         }
//         let start = pathHistory.first!.position
//         let current = pathHistory.last!.position
//         let displacement = current - start
//         let totalDistance = computePathLength()
//         var summary = "User has walked approximately \(String(format: "%.1f", totalDistance)) meters total. "
//         summary += "Current displacement from start: \(String(format: "%.1f", length(displacement))) meters. "
//         if abs(displacement.x) > abs(displacement.z) {
//             summary += displacement.x > 0 ? "Net direction: right/east. " : "Net direction: left/west. "
//         } else {
//             summary += displacement.z > 0 ? "Net direction: backward. " : "Net direction: forward. "
//         }
//         let visitedArea = visitedCells.count
//         summary += "Explored approximately \(visitedArea) grid cells (\(Float(visitedArea) * BNConstants.slamGridCellSize * BNConstants.slamGridCellSize) sq meters). "
//         if isCircleDetected() {
//             summary += "WARNING: User appears to be going in circles. "
//         }
//         let unvisitedDirections = suggestUnexploredDirections()
//         if !unvisitedDirections.isEmpty {
//             summary += "Unexplored directions: \(unvisitedDirections.joined(separator: ", ")). "
//         }
//         return summary
//     }
//
//     // MARK: - Helpers
//
//     private func computePathLength() -> Float {
//         guard pathHistory.count > 1 else { return 0 }
//         var total: Float = 0
//         for i in 1..<pathHistory.count {
//             total += length(pathHistory[i].position - pathHistory[i - 1].position)
//         }
//         return total
//     }
//
//     private func suggestUnexploredDirections() -> [String] {
//         guard let last = pathHistory.last else { return [] }
//         let cx = Int(floor(last.position.x / BNConstants.slamGridCellSize))
//         let cz = Int(floor(last.position.z / BNConstants.slamGridCellSize))
//         var directions: [String] = []
//         let checkRadius = 4
//         let leftCells = (-checkRadius...(-1)).map { GridCell(x: cx + $0, z: cz) }
//         let rightCells = (1...checkRadius).map { GridCell(x: cx + $0, z: cz) }
//         let forwardCells = (-checkRadius...(-1)).map { GridCell(x: cx, z: cz + $0) }
//         let backwardCells = (1...checkRadius).map { GridCell(x: cx, z: cz + $0) }
//         if leftCells.allSatisfy({ visitedCells[$0] == nil }) { directions.append("left") }
//         if rightCells.allSatisfy({ visitedCells[$0] == nil }) { directions.append("right") }
//         if forwardCells.allSatisfy({ visitedCells[$0] == nil }) { directions.append("forward") }
//         if backwardCells.allSatisfy({ visitedCells[$0] == nil }) { directions.append("behind") }
//         return directions
//     }
// }
