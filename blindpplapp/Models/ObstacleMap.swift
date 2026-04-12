import Foundation
import simd
import CoreGraphics

// MARK: - Depth-based obstacle representation

struct ObstacleMap {
    /// Raw depth values in a 2D grid, row-major. Values are relative inverse depth (higher = closer).
    let depthGrid: [[Float]]
    let gridWidth: Int
    let gridHeight: Int
    /// Timestamp of the frame that produced this map
    let timestamp: Date

    // MARK: - Sector clearance for obstacle avoidance

    struct SectorClearance {
        let index: Int
        /// Normalized X center of this sector (0 = left edge, 1 = right edge)
        let normalizedCenterX: Float
        /// Closest obstacle distance in meters within this sector
        let minDistanceMeters: Float
    }

    /// Scans the depth map in vertical sectors across the full frame width.
    /// Returns per-sector clearance info so the navigation engine can find
    /// obstacle-free directions to guide the user around obstacles.
    func sectorClearances(numSectors: Int = 9, scaleFactor: Float = 1.0) -> [SectorClearance] {
        guard gridWidth > 0, gridHeight > 0 else { return [] }

        let sectorWidth = gridWidth / numSectors
        guard sectorWidth > 0 else { return [] }

        // Scan the lower 70% of the frame (the area physically in front of the user)
        let yStart = Int(Float(gridHeight) * 0.3)
        let yEnd = gridHeight

        var sectors: [SectorClearance] = []
        sectors.reserveCapacity(numSectors)

        for s in 0..<numSectors {
            let xStart = s * sectorWidth
            let xEnd = min(xStart + sectorWidth, gridWidth)

            var maxInverseDepth: Float = 0

            for y in yStart..<yEnd {
                for x in xStart..<xEnd {
                    let d = depthGrid[y][x]
                    if d > maxInverseDepth {
                        maxInverseDepth = d
                    }
                }
            }

            let distance = Self.approximateDistance(inverseDepth: maxInverseDepth, scaleFactor: scaleFactor)
            let centerX = (Float(xStart) + Float(xEnd)) / 2.0 / Float(gridWidth)

            sectors.append(SectorClearance(
                index: s,
                normalizedCenterX: centerX,
                minDistanceMeters: distance
            ))
        }

        return sectors
    }

    // MARK: - Multi-zone obstacle proximity

    struct ObstacleZoneInfo {
        let index: Int
        /// -1 = far left, 0 = center, +1 = far right
        let lateralOffset: Float
        /// Closest obstacle distance in meters within this zone
        let closestDistanceMeters: Float
    }

    /// Divides the lower portion of the frame into `numZones` equal-width zones
    /// and returns the closest obstacle distance in each. Covers the full frame
    /// width so obstacles to the sides are detected early.
    func obstacleZones(numZones: Int = 3, scaleFactor: Float = 1.0) -> [ObstacleZoneInfo] {
        guard gridWidth > 0, gridHeight > 0, numZones > 0 else { return [] }

        let zoneWidth = gridWidth / numZones
        guard zoneWidth > 0 else { return [] }

        let yStart = Int(Float(gridHeight) * 0.25)
        let yEnd = gridHeight

        var zones: [ObstacleZoneInfo] = []
        zones.reserveCapacity(numZones)

        for z in 0..<numZones {
            let xStart = z * zoneWidth
            let xEnd = min(xStart + zoneWidth, gridWidth)

            var maxInverseDepth: Float = 0
            for y in yStart..<yEnd {
                for x in xStart..<xEnd {
                    let d = depthGrid[y][x]
                    if d > maxInverseDepth {
                        maxInverseDepth = d
                    }
                }
            }

            let distance = Self.approximateDistance(inverseDepth: maxInverseDepth, scaleFactor: scaleFactor)
            let centerNormX = (Float(xStart) + Float(xEnd)) / 2.0 / Float(gridWidth)
            let lateral = (centerNormX - 0.5) * 2.0

            zones.append(ObstacleZoneInfo(
                index: z,
                lateralOffset: lateral,
                closestDistanceMeters: distance
            ))
        }

        return zones
    }

    // MARK: - Obstacle query

    /// Returns the closest obstacle info in the center region of the frame (the walking direction).
    /// Returns (relativeDepth, normalizedX, normalizedY) or nil if nothing dangerously close.
    func closestObstacleInWalkingDirection() -> (depth: Float, normalizedX: Float, normalizedY: Float)? {
        guard gridWidth > 0, gridHeight > 0 else { return nil }

        let xStart = Int(Float(gridWidth) * 0.3)
        let xEnd = Int(Float(gridWidth) * 0.7)
        let yStart = Int(Float(gridHeight) * 0.4)
        let yEnd = gridHeight

        var maxDepth: Float = 0
        var maxX = 0
        var maxY = 0

        for y in yStart..<yEnd {
            for x in xStart..<xEnd {
                let d = depthGrid[y][x]
                if d > maxDepth {
                    maxDepth = d
                    maxX = x
                    maxY = y
                }
            }
        }

        guard maxDepth > 0 else { return nil }

        let normalizedX = Float(maxX) / Float(gridWidth)
        let normalizedY = Float(maxY) / Float(gridHeight)
        return (depth: maxDepth, normalizedX: normalizedX, normalizedY: normalizedY)
    }

    /// Converts a relative inverse depth to an approximate distance in meters.
    /// MiDaS produces relative inverse depth; this is a rough linear mapping calibrated at runtime.
    static func approximateDistance(inverseDepth: Float, scaleFactor: Float = 1.0) -> Float {
        guard inverseDepth > 0.001 else { return 100.0 }
        return scaleFactor / inverseDepth
    }
}
