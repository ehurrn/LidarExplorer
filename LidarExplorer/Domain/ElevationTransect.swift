//
//  ElevationTransect.swift
//  LidarExplorer
//
//  1D elevation transects: uniform bilinear sampling, along-track slope and
//  curvature, and earthwork signature detection.
//

import CoreLocation
import Foundation
import simd

// MARK: - Elevation fields

/// Elevations addressable in a local metric frame: x east, y north, metres.
public nonisolated protocol ElevationField: Sendable {
    /// Elevation at `point`, or `nil` outside the field or over a void.
    func elevation(at point: SIMD2<Float>) -> Float?
}

/// An ``ElevationField`` that also knows where its frame sits on the globe.
public nonisolated protocol GeoreferencedElevationField: ElevationField {
    func point(for coordinate: CLLocationCoordinate2D) -> SIMD2<Float>
    func coordinate(for point: SIMD2<Float>) -> CLLocationCoordinate2D
}

/// One grid, in its own frame: origin at the south-west cell centre (column 0,
/// last row), x along columns, y up the rows.
public nonisolated struct GridElevationField: GeoreferencedElevationField {
    public let grid: ElevationGrid

    public init(grid: ElevationGrid) {
        self.grid = grid
    }

    /// Void-aware bilinear interpolation: `nil` if any of the four neighbours
    /// is a void, rather than blending across the gap.
    public func elevation(at point: SIMD2<Float>) -> Float? {
        let column = Double(point.x) / grid.metersPerColumn
        let row = Double(grid.height - 1) - Double(point.y) / grid.metersPerRow
        guard column >= 0, row >= 0, column <= Double(grid.width - 1), row <= Double(grid.height - 1) else { return nil }
        let x0 = Int(column), y0 = Int(row)
        let x1 = min(x0 + 1, grid.width - 1), y1 = min(y0 + 1, grid.height - 1)
        guard let v00 = grid.sample(x: x0, y: y0), let v10 = grid.sample(x: x1, y: y0),
              let v01 = grid.sample(x: x0, y: y1), let v11 = grid.sample(x: x1, y: y1)
        else { return nil }
        let fx = Float(column - Double(x0)), fy = Float(row - Double(y0))
        let top = v00 + (v10 - v00) * fx
        let bottom = v01 + (v11 - v01) * fx
        return top + (bottom - top) * fy
    }

    public func point(for coordinate: CLLocationCoordinate2D) -> SIMD2<Float> {
        let (column, row) = grid.gridCoordinates(for: coordinate)
        return SIMD2(Float(column * grid.metersPerColumn), Float((Double(grid.height - 1) - row) * grid.metersPerRow))
    }

    public func coordinate(for point: SIMD2<Float>) -> CLLocationCoordinate2D {
        let fx = grid.width > 1 ? Double(point.x) / grid.metersPerColumn / Double(grid.width - 1) : 0.5
        let fy = grid.height > 1 ? Double(point.y) / grid.metersPerRow / Double(grid.height - 1) : 0.5
        return CLLocationCoordinate2D(
            latitude: grid.region.minLatitude + fy * grid.region.latitudeSpan,
            longitude: grid.region.minLongitude + fx * grid.region.longitudeSpan
        )
    }
}

/// Several cached map tiles as one field, finest first, in a local tangent
/// plane anchored at `origin` -- accurate to well under 0.1% over the few
/// kilometres a transect spans.
public nonisolated struct TileMosaicField: GeoreferencedElevationField {
    public struct Layer: Sendable {
        public let grid: ElevationGrid
        /// The part of the grid that answers (a tile's display area, skirt excluded).
        public let bounds: GeoRegion

        public init(grid: ElevationGrid, bounds: GeoRegion) {
            self.grid = grid
            self.bounds = bounds
        }
    }

    public let origin: CLLocationCoordinate2D
    public let layers: [Layer]
    private let metersPerDegreeLongitude: Double

    public init(origin: CLLocationCoordinate2D, layers: [Layer]) {
        self.origin = origin
        self.layers = layers.sorted { $0.grid.groundSampleDistance < $1.grid.groundSampleDistance }
        self.metersPerDegreeLongitude = GeoRegion.metersPerDegreeLatitude * cos(origin.latitude * .pi / 180)
    }

    public var finestGroundSampleDistance: Double? { layers.first?.grid.groundSampleDistance }

    public func point(for coordinate: CLLocationCoordinate2D) -> SIMD2<Float> {
        SIMD2(
            Float((coordinate.longitude - origin.longitude) * metersPerDegreeLongitude),
            Float((coordinate.latitude - origin.latitude) * GeoRegion.metersPerDegreeLatitude)
        )
    }

    public func coordinate(for point: SIMD2<Float>) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: origin.latitude + Double(point.y) / GeoRegion.metersPerDegreeLatitude,
            longitude: origin.longitude + Double(point.x) / metersPerDegreeLongitude
        )
    }

    public func elevation(at point: SIMD2<Float>) -> Float? {
        let c = coordinate(for: point)
        for layer in layers where layer.bounds.contains(c) {
            if let value = layer.grid.interpolatedElevation(at: c) { return value }
        }
        return nil
    }

    /// Checks if a projected point is within `marginMeters` of any layer boundary.
    public func isNearBoundary(point: SIMD2<Float>, marginMeters: Float = 1.5) -> Bool {
        let c = coordinate(for: point)
        let latMargin = Double(marginMeters) / GeoRegion.metersPerDegreeLatitude
        let lonMargin = Double(marginMeters) / metersPerDegreeLongitude
        for layer in layers {
            let b = layer.bounds
            let nearLat = abs(c.latitude - b.minLatitude) <= latMargin || abs(c.latitude - b.maxLatitude) <= latMargin
            let nearLon = abs(c.longitude - b.minLongitude) <= lonMargin || abs(c.longitude - b.maxLongitude) <= lonMargin
            if (nearLat || nearLon) &&
                c.latitude >= b.minLatitude - latMargin && c.latitude <= b.maxLatitude + latMargin &&
                c.longitude >= b.minLongitude - lonMargin && c.longitude <= b.maxLongitude + lonMargin {
                return true
            }
        }
        return false
    }

    /// Ground sample distance of the layer that actually answers at `point`.
    func answeringGroundSampleDistance(at point: SIMD2<Float>) -> Double? {
        let c = coordinate(for: point)
        for layer in layers where layer.bounds.contains(c) {
            if layer.grid.interpolatedElevation(at: c) != nil { return layer.grid.groundSampleDistance }
        }
        return nil
    }

    /// True near a boundary where the answering resolution changes by more than
    /// `resolutionRatio` (e.g. 3DEP beside upsampled Terrarium). Same-zoom tile
    /// edges are continuous -- their padded skirts carry the neighbour's samples.
    public func isResolutionSeam(point: SIMD2<Float>, marginMeters: Float = 1.5, resolutionRatio: Double = 1.25) -> Bool {
        guard isNearBoundary(point: point, marginMeters: marginMeters) else { return false }
        let probes: [SIMD2<Float>] = [
            point, point + SIMD2(marginMeters, 0), point - SIMD2(marginMeters, 0),
            point + SIMD2(0, marginMeters), point - SIMD2(0, marginMeters),
        ]
        let resolutions = probes.compactMap(answeringGroundSampleDistance(at:))
        guard let finest = resolutions.min(), let coarsest = resolutions.max(), finest > 0 else { return false }
        return coarsest / finest > resolutionRatio
    }
}

// MARK: - Profile samples

/// One sample of a transect.
public nonisolated struct ProfileSample: Sendable, Equatable, Identifiable {
    public let index: Int
    /// Ground distance from the transect start, metres.
    public let distance: Float
    /// Position in the field's frame.
    public let position: SIMD2<Float>
    /// Bilinear elevation, NaN where the field has no data.
    public let elevation: Float
    /// Elevation after light Gaussian smoothing (suppresses lidar return noise
    /// before differentiating), NaN over voids.
    public var smoothedElevation: Float
    /// Along-track slope `atan(dz/dx)` in degrees, positive rising toward the end.
    public var slopeDegrees: Float
    /// Along-track curvature `d²z/dx²` in 1/m: negative at a convex break
    /// (a platform's edge), positive at a concave one (a flank's foot).
    public var curvature: Float
    /// True when the sample lies on or near a tile boundary seam.
    public var isSeamArtifact: Bool
    /// Regional baseline elevation in metres (linear regression / interpolation between endpoints).
    public var baselineElevation: Float

    public var id: Int { index }

    public init(
        index: Int,
        distance: Float,
        position: SIMD2<Float>,
        elevation: Float,
        smoothedElevation: Float,
        slopeDegrees: Float,
        curvature: Float,
        isSeamArtifact: Bool = false,
        baselineElevation: Float = .nan
    ) {
        self.index = index
        self.distance = distance
        self.position = position
        self.elevation = elevation
        self.smoothedElevation = smoothedElevation
        self.slopeDegrees = slopeDegrees
        self.curvature = curvature
        self.isSeamArtifact = isSeamArtifact
        self.baselineElevation = baselineElevation
    }
}

// MARK: - Signatures

public nonisolated struct TransectSignatureParameters: Sendable, Equatable, Hashable {
    /// Gaussian sigma applied before differentiating, metres.
    public var smoothingMeters: Float = 1.0

    /// Platform mound: flanks at least this steep...
    public var flankMinimumSlopeDegrees: Float = 20
    /// ...either side of a top no steeper than this...
    public var plateauMaximumSlopeDegrees: Float = 5
    /// ...between 10 and 40 metres across.
    public var plateauWidthRange: ClosedRange<Float> = 10...40
    /// How far beyond each plateau edge to look for its flank.
    public var flankSearchMeters: Float = 12
    /// Brief rough patches a plateau may contain and still count as one.
    public var plateauGapToleranceMeters: Float = 1.5

    /// Ditch-and-berm: adjacent minimum and maximum at least this far apart
    /// vertically...
    public var minimumReliefMeters: Float = 0.3
    /// ...at most this far apart horizontally...
    public var maximumPairSpacingMeters: Float = 12
    /// ...and no taller than an earthwork (rules out valley walls).
    public var maximumReliefMeters: Float = 5

    /// Rejects candidate earthwork signatures whose breaks fall within the
    /// margin of a resolution seam -- a boundary where the answering tile's
    /// ground resolution changes. Same-zoom tile edges are continuous and are
    /// never flagged.
    public var filterSeamArtifacts: Bool = true
    /// Margin in metres around tile seams for artifact suppression.
    public var seamArtifactMarginMeters: Float = 1.5

    public init() {}
}

public nonisolated enum TransectSignatureKind: String, Sendable, CaseIterable {
    case platformMound
    case ditchAndBerm

    public var displayName: String {
        switch self {
        case .platformMound: "Platform mound"
        case .ditchAndBerm: "Ditch & berm"
        }
    }
}

public nonisolated struct TransectSignature: Sendable, Equatable, Identifiable {
    public let id: Int
    public let kind: TransectSignatureKind
    public let startDistance: Float
    public let endDistance: Float
    /// Mound: the two plateau-edge slope breaks. Ditch-and-berm: every
    /// extremum in the chain (ditch floors and berm crests), in order.
    public let breakDistances: [Float]
    public let reliefMeters: Float
    /// Mounds only.
    public let plateauWidthMeters: Float?
    /// Mounds only: rising and falling flank slopes, degrees.
    public let flankSlopesDegrees: [Float]
    /// Cross-sectional area above and below baseline in square metres.
    public let cutFillAreaSquareMeters: (cut: Double, fill: Double)
    /// Estimated solid of revolution (radial mounds) or prism (linear berms) volume in cubic metres.
    public let estimatedVolumeCubicMeters: Double
    /// Baseline elevation range spanned by the signature.
    public let baselineElevationRange: ClosedRange<Double>?

    public init(
        id: Int,
        kind: TransectSignatureKind,
        startDistance: Float,
        endDistance: Float,
        breakDistances: [Float],
        reliefMeters: Float,
        plateauWidthMeters: Float? = nil,
        flankSlopesDegrees: [Float] = [],
        cutFillAreaSquareMeters: (cut: Double, fill: Double) = (0, 0),
        estimatedVolumeCubicMeters: Double = 0,
        baselineElevationRange: ClosedRange<Double>? = nil
    ) {
        self.id = id
        self.kind = kind
        self.startDistance = startDistance
        self.endDistance = endDistance
        self.breakDistances = breakDistances
        self.reliefMeters = reliefMeters
        self.plateauWidthMeters = plateauWidthMeters
        self.flankSlopesDegrees = flankSlopesDegrees
        self.cutFillAreaSquareMeters = cutFillAreaSquareMeters
        self.estimatedVolumeCubicMeters = estimatedVolumeCubicMeters
        self.baselineElevationRange = baselineElevationRange
    }

    public static func == (lhs: TransectSignature, rhs: TransectSignature) -> Bool {
        lhs.id == rhs.id &&
        lhs.kind == rhs.kind &&
        lhs.startDistance == rhs.startDistance &&
        lhs.endDistance == rhs.endDistance &&
        lhs.breakDistances == rhs.breakDistances &&
        lhs.reliefMeters == rhs.reliefMeters &&
        lhs.plateauWidthMeters == rhs.plateauWidthMeters &&
        lhs.flankSlopesDegrees == rhs.flankSlopesDegrees &&
        lhs.cutFillAreaSquareMeters.cut == rhs.cutFillAreaSquareMeters.cut &&
        lhs.cutFillAreaSquareMeters.fill == rhs.cutFillAreaSquareMeters.fill &&
        lhs.estimatedVolumeCubicMeters == rhs.estimatedVolumeCubicMeters &&
        lhs.baselineElevationRange == rhs.baselineElevationRange
    }

    public var summary: String {
        switch kind {
        case .platformMound:
            let flanks = flankSlopesDegrees.map { String(format: "%.0f°", $0) }.joined(separator: "/")
            return String(format: "%.0f m plateau · %.1f m high · flanks %@", plateauWidthMeters ?? 0, reliefMeters, flanks)
        case .ditchAndBerm:
            return String(format: "%.1f m relief over %.0f m", reliefMeters, endDistance - startDistance)
        }
    }
}

/// A sampled transect with its derived signatures and summary statistics.
public nonisolated struct TransectAnalysis: Sendable, Equatable {
    public let samples: [ProfileSample]
    public let signatures: [TransectSignature]
    public let stepDistance: Float
    public let lengthMeters: Float
    public let minimumElevation: Float
    public let maximumElevation: Float
    public let gainMeters: Float
    public let lossMeters: Float
    public let maximumSlopeDegrees: Float
    public let validFraction: Double
    public let cutFillAreaSquareMeters: (cut: Double, fill: Double)
    public let estimatedVolumeCubicMeters: Double
    public let baselineElevationRange: ClosedRange<Double>?

    public init(samples: [ProfileSample], stepDistance: Float, parameters: TransectSignatureParameters) {
        var samples = samples
        TransectMath.fillBaseline(&samples)
        self.samples = samples
        self.stepDistance = stepDistance
        self.lengthMeters = samples.last?.distance ?? 0
        self.signatures = TransectSignatureDetector.detect(samples, step: stepDistance, parameters: parameters)

        var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
        var gain: Float = 0, loss: Float = 0, steepest: Float = 0
        var valid = 0
        var previous: Float?
        var totalCut: Double = 0
        var totalFill: Double = 0
        let deltaD = Double(stepDistance > 0 ? stepDistance : 0.5)

        for s in samples {
            guard !s.elevation.isNaN else { previous = nil; continue }
            valid += 1
            low = min(low, s.elevation)
            high = max(high, s.elevation)
            if let previous {
                let d = s.elevation - previous
                if d > 0 { gain += d } else { loss -= d }
            }
            previous = s.elevation
            if !s.slopeDegrees.isNaN { steepest = max(steepest, abs(s.slopeDegrees)) }
            if !s.baselineElevation.isNaN {
                let diff = Double(s.elevation - s.baselineElevation)
                if diff > 0 {
                    totalCut += diff * deltaD
                } else {
                    totalFill += (-diff) * deltaD
                }
            }
        }
        self.minimumElevation = valid > 0 ? low : .nan
        self.maximumElevation = valid > 0 ? high : .nan
        self.gainMeters = gain
        self.lossMeters = loss
        self.maximumSlopeDegrees = steepest
        self.validFraction = samples.isEmpty ? 0 : Double(valid) / Double(samples.count)
        self.cutFillAreaSquareMeters = (totalCut, totalFill)
        self.estimatedVolumeCubicMeters = self.signatures.reduce(0.0) { $0 + $1.estimatedVolumeCubicMeters }

        let validBaselines = samples.compactMap { $0.baselineElevation.isNaN ? nil : Double($0.baselineElevation) }
        if let minB = validBaselines.min(), let maxB = validBaselines.max() {
            self.baselineElevationRange = minB...maxB
        } else {
            self.baselineElevationRange = nil
        }
    }

    public static func == (lhs: TransectAnalysis, rhs: TransectAnalysis) -> Bool {
        lhs.samples.count == rhs.samples.count && lhs.stepDistance == rhs.stepDistance
            && lhs.signatures == rhs.signatures && lhs.lengthMeters == rhs.lengthMeters
            && lhs.cutFillAreaSquareMeters.cut == rhs.cutFillAreaSquareMeters.cut
            && lhs.cutFillAreaSquareMeters.fill == rhs.cutFillAreaSquareMeters.fill
            && lhs.estimatedVolumeCubicMeters == rhs.estimatedVolumeCubicMeters
            && lhs.baselineElevationRange == rhs.baselineElevationRange
            && zip(lhs.samples, rhs.samples).allSatisfy {
                ($0.elevation == $1.elevation || ($0.elevation.isNaN && $1.elevation.isNaN))
                    && ($0.baselineElevation == $1.baselineElevation || ($0.baselineElevation.isNaN && $1.baselineElevation.isNaN))
            }
    }
}

// MARK: - Engine

/// Real-time 1D elevation transects over any ``ElevationField``.
public nonisolated struct ElevationTransectEngine<Field: ElevationField>: Sendable {
    public let field: Field
    public var parameters: TransectSignatureParameters

    /// Longest profile produced; a longer line coarsens its step instead.
    public static var maximumSamples: Int { 20_001 }

    public init(field: Field, parameters: TransectSignatureParameters = TransectSignatureParameters()) {
        self.field = field
        self.parameters = parameters
    }

    /// Samples the field every `stepDistance` metres from `start` toward
    /// `end` (bilinear), with smoothed elevation, slope and curvature filled in.
    ///
    /// Samples sit at exact multiples of the step, so the last one lands on
    /// `end` only when the length is a whole number of steps.
    public func sampleProfile(from start: SIMD2<Float>, to end: SIMD2<Float>, stepDistance: Float) -> [ProfileSample] {
        let delta = end - start
        let length = simd_length(delta)
        guard length.isFinite, stepDistance > 0 else { return [] }
        let step = length / stepDistance + 1 > Float(Self.maximumSamples)
            ? length / Float(Self.maximumSamples - 1) : stepDistance
        let count = Int((length / step + 1e-3).rounded(.down)) + 1
        let direction = length > 0 ? delta / length : SIMD2<Float>(0, 0)

        var samples = [ProfileSample]()
        samples.reserveCapacity(count)
        for k in 0..<count {
            let distance = Float(k) * step
            let position = start + direction * distance
            let isSeam = parameters.filterSeamArtifacts
                && ((field as? TileMosaicField)?.isResolutionSeam(point: position, marginMeters: parameters.seamArtifactMarginMeters) ?? false)
            samples.append(ProfileSample(
                index: k, distance: distance, position: position,
                elevation: field.elevation(at: position) ?? .nan,
                smoothedElevation: .nan, slopeDegrees: .nan, curvature: .nan,
                isSeamArtifact: isSeam
            ))
        }
        TransectMath.fillDerivatives(&samples, step: step, smoothingMeters: parameters.smoothingMeters)
        return samples
    }

    /// Fast decimated profile for 120 Hz interactive touch preview (no derivatives or signatures).
    public func previewProfile(from start: SIMD2<Float>, to end: SIMD2<Float>, maxPoints: Int = 256) -> [ProfileSample] {
        let delta = end - start
        let length = simd_length(delta)
        guard length.isFinite, maxPoints > 1 else { return [] }
        let count = min(max(Int(length.rounded()), 2), maxPoints)
        let step = length / Float(count - 1)
        let direction = length > 0 ? delta / length : SIMD2<Float>(0, 0)

        var samples = [ProfileSample]()
        samples.reserveCapacity(count)
        for k in 0..<count {
            let distance = Float(k) * step
            let position = start + direction * distance
            let elev = field.elevation(at: position) ?? .nan
            samples.append(ProfileSample(
                index: k, distance: distance, position: position,
                elevation: elev, smoothedElevation: elev, slopeDegrees: 0, curvature: 0
            ))
        }
        return samples
    }

    public func analyze(from start: SIMD2<Float>, to end: SIMD2<Float>, stepDistance: Float = 0.5) -> TransectAnalysis {
        let samples = sampleProfile(from: start, to: end, stepDistance: stepDistance)
        let step = samples.count > 1 ? samples[1].distance - samples[0].distance : stepDistance
        return TransectAnalysis(samples: samples, stepDistance: step, parameters: parameters)
    }
}

extension ElevationTransectEngine where Field: GeoreferencedElevationField {
    public nonisolated func sampleProfile(
        from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D, stepDistance: Float
    ) -> [ProfileSample] {
        sampleProfile(from: field.point(for: start), to: field.point(for: end), stepDistance: stepDistance)
    }

    public nonisolated func previewProfile(
        from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D, maxPoints: Int = 256
    ) -> [ProfileSample] {
        previewProfile(from: field.point(for: start), to: field.point(for: end), maxPoints: maxPoints)
    }

    public nonisolated func analyze(
        from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D, stepDistance: Float = 0.5
    ) -> TransectAnalysis {
        analyze(from: field.point(for: start), to: field.point(for: end), stepDistance: stepDistance)
    }
}

// MARK: - Math

public nonisolated enum TransectMath {

    /// Void-aware (normalised) Gaussian smoothing; NaN wherever the input is.
    public static func smoothed(_ z: [Float], sigmaSamples: Float) -> [Float] {
        guard sigmaSamples > 0.3, z.count > 2 else { return z }
        let radius = max(Int((sigmaSamples * 3).rounded(.up)), 1)
        let inverse = 1 / (2 * sigmaSamples * sigmaSamples)
        let weights = (0...radius).map { exp(-Float($0 * $0) * inverse) }
        var out = [Float](repeating: .nan, count: z.count)
        for i in z.indices where !z[i].isNaN {
            var sum: Float = 0, weight: Float = 0
            for j in max(i - radius, 0)...min(i + radius, z.count - 1) where !z[j].isNaN {
                let w = weights[abs(j - i)]
                sum += w * (z[j] - z[i])
                weight += w
            }
            out[i] = z[i] + sum / weight
        }
        return out
    }

    /// Fills smoothed elevation, slope and curvature from central differences
    /// of the smoothed profile (one-sided at the ends, NaN next to voids).
    public static func fillDerivatives(_ samples: inout [ProfileSample], step: Float, smoothingMeters: Float) {
        guard !samples.isEmpty, step > 0 else { return }
        let z = smoothed(samples.map(\.elevation), sigmaSamples: smoothingMeters / step)
        let n = z.count
        for i in 0..<n {
            samples[i].smoothedElevation = z[i]
            guard !z[i].isNaN, n > 1 else { continue }
            let previous = i > 0 ? z[i - 1] : Float.nan
            let next = i + 1 < n ? z[i + 1] : Float.nan
            let gradient: Float
            if !previous.isNaN && !next.isNaN {
                gradient = (next - previous) / (2 * step)
                samples[i].curvature = (next - 2 * z[i] + previous) / (step * step)
            } else if !next.isNaN {
                gradient = (next - z[i]) / step
            } else if !previous.isNaN {
                gradient = (z[i] - previous) / step
            } else {
                continue
            }
            samples[i].slopeDegrees = atan(gradient) * 180 / .pi
        }
    }

    /// Computes a regional baseline z_base(d) via linear interpolation between the
    /// endpoints (or endpoint averages to resist noise) and fills baselineElevation.
    public static func fillBaseline(_ samples: inout [ProfileSample]) {
        let valid = samples.filter { !$0.elevation.isNaN }
        guard valid.count >= 2 else {
            for i in samples.indices {
                samples[i].baselineElevation = samples[i].elevation
            }
            return
        }
        let headCount = min(3, max(1, valid.count / 4))
        let tailCount = min(3, max(1, valid.count / 4))
        let head = valid.prefix(headCount)
        let tail = valid.suffix(tailCount)
        let d0 = Double(head.map(\.distance).reduce(0, +)) / Double(headCount)
        let z0 = Double(head.map(\.elevation).reduce(0, +)) / Double(headCount)
        let d1 = Double(tail.map(\.distance).reduce(0, +)) / Double(tailCount)
        let z1 = Double(tail.map(\.elevation).reduce(0, +)) / Double(tailCount)
        let slope = (d1 > d0) ? (z1 - z0) / (d1 - d0) : 0.0

        for i in samples.indices {
            let d = Double(samples[i].distance)
            samples[i].baselineElevation = Float(z0 + slope * (d - d0))
        }
    }
}

/// Finds earthwork signatures in a transect.
public nonisolated enum TransectSignatureDetector {

    public static func detect(
        _ samples: [ProfileSample], step: Float, parameters: TransectSignatureParameters
    ) -> [TransectSignature] {
        guard samples.count >= 5, step > 0 else { return [] }
        let rawMounds = platformMounds(samples, step: step, parameters)
        let rawPairs = ditchAndBerms(samples, step: step, parameters, excluding: rawMounds)

        let mounds = rawMounds.filter { mound in
            guard parameters.filterSeamArtifacts else { return true }
            return !isNearSeam(mound, samples: samples, margin: parameters.seamArtifactMarginMeters)
        }
        let pairs = rawPairs.filter { pair in
            guard parameters.filterSeamArtifacts else { return true }
            return !isNearSeam(pair, samples: samples, margin: parameters.seamArtifactMarginMeters)
        }

        return (mounds + pairs)
            .sorted { $0.startDistance < $1.startDistance }
            .enumerated()
            .map { i, s in
                let (cutFill, vol, baseRange) = computeMetrics(for: s, samples: samples, step: step)
                return TransectSignature(
                    id: i, kind: s.kind, startDistance: s.startDistance, endDistance: s.endDistance,
                    breakDistances: s.breakDistances, reliefMeters: s.reliefMeters,
                    plateauWidthMeters: s.plateauWidthMeters, flankSlopesDegrees: s.flankSlopesDegrees,
                    cutFillAreaSquareMeters: cutFill,
                    estimatedVolumeCubicMeters: vol,
                    baselineElevationRange: baseRange
                )
            }
    }

    private static func computeMetrics(
        for sig: TransectSignature, samples: [ProfileSample], step: Float
    ) -> (cutFill: (cut: Double, fill: Double), volume: Double, baselineRange: ClosedRange<Double>?) {
        let sub = samples.filter {
            $0.distance >= sig.startDistance && $0.distance <= sig.endDistance
                && !$0.elevation.isNaN && !$0.baselineElevation.isNaN
        }
        guard !sub.isEmpty else {
            return ((0, 0), 0, nil)
        }
        let deltaD = Double(step > 0 ? step : 0.5)
        var cutArea: Double = 0
        var fillArea: Double = 0
        var num: Double = 0
        var den: Double = 0
        let centerD = Double(sig.startDistance + sig.endDistance) * 0.5

        for s in sub {
            let z = Double(s.elevation)
            let zb = Double(s.baselineElevation)
            let diff = z - zb
            if diff > 0 {
                cutArea += diff * deltaD
            } else {
                fillArea += (-diff) * deltaD
            }
            let absDiff = abs(diff)
            let r = abs(Double(s.distance) - centerD)
            num += absDiff * r * deltaD
            den += absDiff * deltaD
        }

        let volume: Double
        if sig.kind == .platformMound {
            let rCentroid = den > 1e-6 ? num / den : (Double(sig.endDistance - sig.startDistance) * 0.25)
            let aNet = max(cutArea, fillArea)
            volume = 2.0 * .pi * rCentroid * aNet
        } else {
            // Linear prism
            let swathWidth: Double = 10.0
            volume = (cutArea + fillArea) * swathWidth
        }

        let baselines = sub.map { Double($0.baselineElevation) }
        let baseRange: ClosedRange<Double>?
        if let minB = baselines.min(), let maxB = baselines.max() {
            baseRange = minB...maxB
        } else {
            baseRange = nil
        }

        return ((cutArea, fillArea), volume, baseRange)
    }

    private static func isNearSeam(_ sig: TransectSignature, samples: [ProfileSample], margin: Float) -> Bool {
        let seamDistances = samples.filter(\.isSeamArtifact).map(\.distance)
        guard !seamDistances.isEmpty else { return false }
        for checkDist in [sig.startDistance, sig.endDistance] + sig.breakDistances {
            if seamDistances.contains(where: { abs($0 - checkDist) <= margin }) {
                return true
            }
        }
        return false
    }

    /// Paired slope breaks steeper than the flank threshold either side of a
    /// flat top 10-40 m wide. Direction-agnostic: whichever end the transect
    /// starts from, a mound rises into its plateau and falls out of it.
    static func platformMounds(
        _ samples: [ProfileSample], step: Float, _ p: TransectSignatureParameters
    ) -> [TransectSignature] {
        let n = samples.count
        let gap = max(Int((p.plateauGapToleranceMeters / step).rounded()), 0)
        var runs: [ClosedRange<Int>] = []
        var runStart = -1, previous = -1
        for i in 0..<n {
            let s = samples[i].slopeDegrees
            guard !s.isNaN, abs(s) <= p.plateauMaximumSlopeDegrees else { continue }
            if runStart < 0 {
                runStart = i
            } else if i - previous > gap + 1 {
                runs.append(runStart...previous)
                runStart = i
            }
            previous = i
        }
        if runStart >= 0 { runs.append(runStart...previous) }

        let search = max(Int((p.flankSearchMeters / step).rounded()), 1)
        let edge = max(Int((2 / step).rounded()), 1)
        var found: [TransectSignature] = []
        for run in runs {
            let width = Float(run.upperBound - run.lowerBound) * step
            guard p.plateauWidthRange.contains(width) else { continue }
            let left = max(run.lowerBound - search, 0)..<run.lowerBound
            let right = (run.upperBound + 1)..<min(run.upperBound + 1 + search, n)
            guard !left.isEmpty, !right.isEmpty else { continue }

            let rise = left.compactMap { samples[$0].slopeDegrees.isNaN ? nil : samples[$0].slopeDegrees }.max() ?? 0
            let fall = right.compactMap { samples[$0].slopeDegrees.isNaN ? nil : samples[$0].slopeDegrees }.min() ?? 0
            guard rise >= p.flankMinimumSlopeDegrees, -fall >= p.flankMinimumSlopeDegrees else { continue }

            let top = run.map { samples[$0].smoothedElevation }.filter { !$0.isNaN }
            let base = (Array(left) + Array(right)).map { samples[$0].smoothedElevation }.filter { !$0.isNaN }
            guard !top.isEmpty, let floor = base.min() else { continue }
            let relief = top.reduce(0, +) / Float(top.count) - floor
            guard relief >= p.minimumReliefMeters else { continue }

            func extreme(in range: ClosedRange<Int>, minimum: Bool) -> Int {
                let clamped = max(range.lowerBound, 0)...min(range.upperBound, n - 1)
                return clamped.filter { !samples[$0].curvature.isNaN }.min {
                    minimum ? samples[$0].curvature < samples[$1].curvature : samples[$0].curvature > samples[$1].curvature
                } ?? clamped.lowerBound
            }
            let leftBreak = extreme(in: (run.lowerBound - edge)...(run.lowerBound + edge), minimum: true)
            let rightBreak = extreme(in: (run.upperBound - edge)...(run.upperBound + edge), minimum: true)
            let leftFoot = extreme(in: left.lowerBound...(left.upperBound - 1), minimum: false)
            let rightFoot = extreme(in: right.lowerBound...(right.upperBound - 1), minimum: false)

            found.append(TransectSignature(
                id: 0, kind: .platformMound,
                startDistance: samples[leftFoot].distance, endDistance: samples[rightFoot].distance,
                breakDistances: [samples[leftBreak].distance, samples[rightBreak].distance],
                reliefMeters: relief, plateauWidthMeters: width, flankSlopesDegrees: [rise, -fall]
            ))
        }
        return found
    }

    /// Adjacent local minima and maxima (a ditch beside its spoil bank),
    /// found by hysteresis so noise below the relief threshold never makes an
    /// extremum. Chains of qualifying pairs (berm-ditch-berm) merge into one.
    static func ditchAndBerms(
        _ samples: [ProfileSample], step: Float, _ p: TransectSignatureParameters,
        excluding mounds: [TransectSignature]
    ) -> [TransectSignature] {
        let z = samples.map(\.smoothedElevation)
        let n = z.count
        let threshold = p.minimumReliefMeters

        struct Extremum { let isMaximum: Bool; let index: Int; let segment: Int }
        var extrema: [Extremum] = []
        var direction = 0
        var high = -1, low = -1, candidate = -1
        var segment = 0
        for i in 0..<n {
            let v = z[i]
            guard !v.isNaN else {
                if high >= 0 { segment += 1 }
                direction = 0
                high = -1; low = -1; candidate = -1
                continue
            }
            if high < 0 {
                high = i; low = i
                continue
            }
            switch direction {
            case 0:
                if v > z[high] { high = i }
                if v < z[low] { low = i }
                if z[high] - z[low] >= threshold {
                    if high > low {
                        extrema.append(Extremum(isMaximum: false, index: low, segment: segment))
                        direction = 1
                        candidate = high
                    } else {
                        extrema.append(Extremum(isMaximum: true, index: high, segment: segment))
                        direction = -1
                        candidate = low
                    }
                }
            case 1:
                if v > z[candidate] {
                    candidate = i
                } else if z[candidate] - v >= threshold {
                    extrema.append(Extremum(isMaximum: true, index: candidate, segment: segment))
                    direction = -1
                    candidate = i
                }
            default:
                if v < z[candidate] {
                    candidate = i
                } else if v - z[candidate] >= threshold {
                    extrema.append(Extremum(isMaximum: false, index: candidate, segment: segment))
                    direction = 1
                    candidate = i
                }
            }
        }

        let boundary = max(Int((1 / step).rounded()), 1)
        func usable(_ e: Extremum) -> Bool {
            e.index >= boundary && e.index < n - boundary
                && !mounds.contains { samples[e.index].distance >= $0.startDistance && samples[e.index].distance <= $0.endDistance }
        }

        var chains: [[Extremum]] = []
        for k in 0..<max(extrema.count - 1, 0) {
            let a = extrema[k], b = extrema[k + 1]
            let spacing = samples[b.index].distance - samples[a.index].distance
            let relief = abs(z[b.index] - z[a.index])
            guard a.isMaximum != b.isMaximum, a.segment == b.segment, usable(a), usable(b),
                  spacing <= p.maximumPairSpacingMeters,
                  relief >= p.minimumReliefMeters, relief <= p.maximumReliefMeters
            else { continue }
            if let last = chains.last?.last, last.index == a.index {
                chains[chains.count - 1].append(b)
            } else {
                chains.append([a, b])
            }
        }

        return chains.map { chain in
            let heights = chain.map { z[$0.index] }
            return TransectSignature(
                id: 0, kind: .ditchAndBerm,
                startDistance: samples[chain.first!.index].distance,
                endDistance: samples[chain.last!.index].distance,
                breakDistances: chain.map { samples[$0.index].distance },
                reliefMeters: (heights.max() ?? 0) - (heights.min() ?? 0),
                plateauWidthMeters: nil, flankSlopesDegrees: []
            )
        }
    }
}
