import CoreLocation
import Foundation
import simd

/// GPS geometry for a route preview. It can be shared by multiple previews.
public struct Route3DPath {
    public enum ValidationError: LocalizedError {
        case notEnoughLocations
        case invalidLocation(index: Int)
        case stationaryPath

        public var errorDescription: String? {
            switch self {
            case .notEnoughLocations:
                return "A route needs at least two GPS locations."
            case .invalidLocation(let index):
                return "Invalid GPS location at index \(index)."
            case .stationaryPath:
                return "A route needs a nonzero horizontal distance."
            }
        }
    }

    struct Sample {
        let distance: Double
        let elevation: Double
        let position: SIMD3<Float>
    }

    let samples: [Sample]
    let track: [SIMD4<Float>]
    let high: Sample
    let low: Sample

    /// Total horizontal distance along the track, in meters.
    public var distanceMeters: Double { samples[samples.count - 1].distance }

    public var minimumElevationMeters: Double { low.elevation }
    public var maximumElevationMeters: Double { high.elevation }

    /// Creates a path from ordered GPS samples. Altitude is read in meters.
    public init(locations points: [CLLocation]) throws {
        guard points.count >= 2 else { throw ValidationError.notEnoughLocations }
        for (index, point) in points.enumerated() {
            guard CLLocationCoordinate2DIsValid(point.coordinate),
                  Int(exactly: point.altitude.rounded()) != nil else {
                throw ValidationError.invalidLocation(index: index)
            }
        }

        let highIndex = points.indices.max { points[$0].altitude < points[$1].altitude }!
        let lowIndex = points.indices.min { points[$0].altitude < points[$1].altitude }!
        let midElevation = (points[highIndex].altitude + points[lowIndex].altitude) / 2
        let meanLatitude = points.map(\.coordinate.latitude).reduce(0, +) / Double(points.count)
        let origin = points[0].coordinate
        let metersPerDegree = 6_371_008.8 * Double.pi / 180
        let longitudeScale = metersPerDegree * cos(meanLatitude * .pi / 180)

        // East, elevation, and south in a local tangent plane.
        let positions = points.map { point in
            var longitudeDelta = point.coordinate.longitude - origin.longitude
            if abs(longitudeDelta) > 180 {
                longitudeDelta += longitudeDelta > 0 ? -360 : 360
            }
            return SIMD3(
                longitudeDelta * longitudeScale,
                (point.altitude - midElevation) * 1.45,
                (origin.latitude - point.coordinate.latitude) * metersPerDegree
            )
        }
        let minX = positions.map(\.x).min()!
        let maxX = positions.map(\.x).max()!
        let minZ = positions.map(\.z).min()!
        let maxZ = positions.map(\.z).max()!
        let center = SIMD3((minX + maxX) / 2, 0, (minZ + maxZ) / 2)
        let horizontalDiameter = 2 * positions.map { hypot($0.x - center.x, $0.z - center.z) }.max()!
        guard horizontalDiameter > 0 else { throw ValidationError.stationaryPath }
        let verticalDiameter = (points[highIndex].altitude - points[lowIndex].altitude) * 1.45
        let diameter = max(horizontalDiameter, verticalDiameter)

        var distance = 0.0
        let samples = points.indices.map { index in
            if index > 0 {
                distance += points[index].distance(from: points[index - 1])
            }
            return Sample(
                distance: distance,
                elevation: points[index].altitude,
                position: SIMD3<Float>((positions[index] - center) / diameter)
            )
        }

        guard distance.isFinite, distance > 0 else { throw ValidationError.stationaryPath }

        // Preserve both extrema while removing subpixel bends from the render mesh.
        let anchors = Set([0, highIndex, lowIndex, samples.count - 1]).sorted()
        let vertices = Self.simplifiedIndices(positions, anchors: anchors, tolerance: min(9, horizontalDiameter * 0.001))
        self.samples = samples
        self.high = samples[highIndex]
        self.low = samples[lowIndex]
        self.track = vertices.map { index in
            let point = samples[index].position
            return SIMD4(point.x, point.y, point.z, 1)
        }
    }

    func position(at fraction: Double) -> SIMD3<Float> {
        let target = min(max(fraction, 0), 1) * distanceMeters
        var lower = 0
        var upper = samples.count - 1
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if samples[middle].distance < target {
                lower = middle
            } else {
                upper = middle
            }
        }
        let a = samples[lower]
        let b = samples[upper]
        let segment = b.distance - a.distance
        let amount = segment > 0 ? Float((target - a.distance) / segment) : 0
        return a.position + (b.position - a.position) * amount
    }

    private static func simplifiedIndices(
        _ points: [SIMD3<Double>],
        anchors: [Int],
        tolerance: Double
    ) -> [Int] {
        var kept = Set(anchors)
        var ranges = Array(zip(anchors, anchors.dropFirst()))
        let toleranceSquared = tolerance * tolerance
        while let (start, end) = ranges.popLast(), end > start {
            guard end - start > 1 else { continue }
            let a = points[start]
            let direction = points[end] - a
            let lengthSquared = simd_length_squared(direction)
            var split = start
            var maximum = toleranceSquared
            for index in (start + 1)..<end {
                let offset = points[index] - a
                let ratio = lengthSquared > 0 ? simd_dot(offset, direction) / lengthSquared : 0
                let error = simd_length_squared(offset - direction * min(max(ratio, 0), 1))
                if error > maximum {
                    maximum = error
                    split = index
                }
            }
            if split != start {
                kept.insert(split)
                ranges.append((start, split))
                ranges.append((split, end))
            }
        }
        return kept.sorted()
    }

}
