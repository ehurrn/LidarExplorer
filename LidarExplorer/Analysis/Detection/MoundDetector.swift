//
//  MoundDetector.swift
//  LidarExplorer
//
//  Detects discrete positive-relief landforms (mounds, platforms, tumuli).
//

import CoreLocation
import Foundation

/// A detector proposes candidates from terrain alone.
///
/// Detectors are `nonisolated` pure functions of their inputs: no shared
/// state, no I/O, no isolation. That makes them trivially concurrent across
/// regions and directly unit-testable against synthetic grids — the property
/// the previous engine lacked, which is why its detectors could only be tuned
/// by disabling them.
public nonisolated protocol FeatureDetector: Sendable {
    var kind: FeatureKind { get }
    func detect(
        in grid: ElevationGrid,
        relief: [Float],
        options: DetectionOptions,
        now: Date
    ) -> [DetectedFeature]
}

/// Detects mounds: compact, positive-relief landforms rising from a local
/// background surface.
public nonisolated struct MoundDetector: FeatureDetector {

    public let kind: FeatureKind = .mound

    /// Number of rays cast when measuring a candidate's extent and prominence.
    private static let rayCount = 16

    public init() {}

    public func detect(
        in grid: ElevationGrid,
        relief: [Float],
        options: DetectionOptions,
        now: Date
    ) -> [DetectedFeature] {
        guard grid.width >= 5, grid.height >= 5 else { return [] }

        let gsdX = max(grid.metersPerColumn, 0.01)
        let gsdY = max(grid.metersPerRow, 0.01)

        // Peak search neighbourhood, derived from the physical separation.
        let nx = max(Int((options.minimumSeparationMeters / gsdX).rounded()), 1)
        let ny = max(Int((options.minimumSeparationMeters / gsdY).rounded()), 1)

        var candidates: [Candidate] = []

        for y in ny..<(grid.height - ny) {
            for x in nx..<(grid.width - nx) {
                let value = relief[y * grid.width + x]
                guard !value.isNaN, Double(value) >= options.minimumReliefMeters else { continue }

                // Strict local maximum over the neighbourhood. Ties are broken
                // by index so a plateau yields exactly one candidate rather
                // than one per cell.
                var isPeak = true
                neighbourhood: for dy in -ny...ny {
                    for dx in -nx...nx {
                        if dx == 0 && dy == 0 { continue }
                        let other = relief[(y + dy) * grid.width + (x + dx)]
                        if other.isNaN { continue }
                        if other > value || (other == value && (dy, dx) < (0, 0)) {
                            isPeak = false
                            break neighbourhood
                        }
                    }
                }
                guard isPeak else { continue }

                candidates.append(Candidate(x: x, y: y, relief: Double(value)))
            }
        }

        guard !candidates.isEmpty else { return [] }

        // Strongest first, so non-maximum suppression keeps the best of a cluster.
        candidates.sort { $0.relief > $1.relief }

        var accepted: [DetectedFeature] = []
        var takenPoints: [(x: Int, y: Int)] = []

        for candidate in candidates {
            // Physical-distance suppression against everything already kept.
            let tooClose = takenPoints.contains { taken in
                let dx = Double(taken.x - candidate.x) * gsdX
                let dy = Double(taken.y - candidate.y) * gsdY
                return (dx * dx + dy * dy).squareRoot() < options.minimumSeparationMeters
            }
            if tooClose { continue }

            guard let profile = measure(
                candidate: candidate, relief: relief, grid: grid, options: options
            ) else { continue }

            let score = score(profile: profile, options: options)
            guard score >= options.minimumDetectorScore else { continue }

            takenPoints.append((candidate.x, candidate.y))
            accepted.append(
                DetectedFeature(
                    kind: .mound,
                    coordinate: grid.coordinate(x: candidate.x, y: candidate.y),
                    dimensions: profile.dimensions,
                    detectorScore: score,
                    detectedAt: now,
                    notes: profile.notes
                )
            )
        }

        Log.engine.debug(
            "MoundDetector: \(candidates.count) peaks -> \(accepted.count) candidates"
        )
        return accepted
    }

    // MARK: - Measurement

    private struct Candidate {
        let x: Int
        let y: Int
        let relief: Double
    }

    private struct Profile {
        let dimensions: FeatureDimensions
        /// Peak relief minus the highest surrounding saddle.
        let prominence: Double
        /// Spread of half-max radii; low means radially symmetric.
        let radialVariation: Double
        let notes: [String]
    }

    /// Measures extent and prominence by casting rays outward from the peak.
    private func measure(
        candidate: Candidate,
        relief: [Float],
        grid: ElevationGrid,
        options: DetectionOptions
    ) -> Profile? {
        let gsdX = max(grid.metersPerColumn, 0.01)
        let gsdY = max(grid.metersPerRow, 0.01)
        let stepMeters = min(gsdX, gsdY)
        let maxSteps = max(Int(options.maximumExtentMeters / stepMeters), 3)

        let halfMax = candidate.relief / 2
        var radii: [Double] = []
        var saddles: [Double] = []

        for rayIndex in 0..<Self.rayCount {
            let angle = 2 * Double.pi * Double(rayIndex) / Double(Self.rayCount)
            let ux = cos(angle)
            let uy = sin(angle)

            var halfMaxRadius: Double?
            var minimumAlongRay = candidate.relief

            for step in 1...maxSteps {
                let distance = Double(step) * stepMeters
                let px = candidate.x + Int((ux * distance / gsdX).rounded())
                let py = candidate.y + Int((uy * distance / gsdY).rounded())
                guard px >= 0, px < grid.width, py >= 0, py < grid.height else { break }

                let value = relief[py * grid.width + px]
                if value.isNaN { break }
                let v = Double(value)

                minimumAlongRay = min(minimumAlongRay, v)
                if halfMaxRadius == nil && v < halfMax {
                    halfMaxRadius = distance
                }
                // Stop once terrain climbs back above the peak: beyond that
                // saddle we are measuring a neighbouring landform.
                if v > candidate.relief { break }
            }

            if let radius = halfMaxRadius { radii.append(radius) }
            saddles.append(minimumAlongRay)
        }

        // Require most rays to actually close, otherwise this is a ridge or a
        // slope break rather than a discrete mound.
        guard radii.count >= Self.rayCount / 2 else { return nil }

        let sortedRadii = radii.sorted()
        let minRadius = sortedRadii.first ?? 0
        let maxRadius = sortedRadii.last ?? 0
        let meanRadius = radii.reduce(0, +) / Double(radii.count)
        guard meanRadius > 0 else { return nil }

        let variance = radii.reduce(0) { $0 + ($1 - meanRadius) * ($1 - meanRadius) }
            / Double(radii.count)
        let radialVariation = variance.squareRoot() / meanRadius

        // Key col: the highest saddle around the peak.
        let keyCol = saddles.max() ?? 0
        let prominence = candidate.relief - keyCol

        let dimensions = FeatureDimensions(
            reliefMeters: candidate.relief,
            majorAxisMeters: maxRadius * 2,
            minorAxisMeters: minRadius * 2
        )

        var notes: [String] = []
        notes.append(String(
            format: "Relief %.2f m, prominence %.2f m, extent %.0f x %.0f m",
            candidate.relief, prominence, maxRadius * 2, minRadius * 2
        ))

        return Profile(
            dimensions: dimensions,
            prominence: prominence,
            radialVariation: radialVariation,
            notes: notes
        )
    }

    // MARK: - Scoring

    /// Combines morphology terms into a detector score in `0...1`.
    ///
    /// Multiplicative rather than additive: a candidate that fails badly on
    /// any single term cannot be rescued by scoring well on the others. An
    /// additive score lets a perfectly round, perfectly sized parking island
    /// pass on two strong terms — which is precisely how the previous engine
    /// accumulated false positives before its detectors were disabled.
    private func score(profile: Profile, options: DetectionOptions) -> Double {
        let relief = abs(profile.dimensions.reliefMeters)
        let extent = (profile.dimensions.majorAxisMeters
            + profile.dimensions.minorAxisMeters) / 2

        let reliefTerm = band(
            relief, low: options.minimumReliefMeters, high: options.maximumReliefMeters
        )
        let extentTerm = band(
            extent, low: options.minimumExtentMeters, high: options.maximumExtentMeters
        )

        // Prominence relative to the candidate's own height: a bump on a broad
        // rise is far weaker evidence than the same bump standing alone.
        let prominenceRatio = relief > 0 ? profile.prominence / relief : 0
        let prominenceTerm = prominenceRatio >= options.minimumProminenceRatio
            ? min(1, prominenceRatio)
            : prominenceRatio / max(options.minimumProminenceRatio, 0.001) * 0.5

        // Built mounds are close to radially symmetric. Natural spurs are not.
        let symmetryTerm = max(0, 1 - profile.radialVariation)

        // Constructed mounds occupy a characteristic height-to-width band.
        // Too steep is a spoil heap or a tank; too flat is a gentle rise.
        let aspect = profile.dimensions.aspectRatio
        let aspectTerm = band(aspect, low: 0.02, high: 0.35)

        return max(0, min(1,
            reliefTerm * extentTerm * prominenceTerm * symmetryTerm * aspectTerm
        ))
    }

    /// Trapezoidal membership: 1.0 well inside `low...high`, tapering to 0
    /// outside it, so a value near a boundary degrades smoothly instead of
    /// falling off a cliff.
    private func band(_ value: Double, low: Double, high: Double) -> Double {
        guard high > low else { return 0 }
        let margin = (high - low) * 0.15
        if value < low - margin || value > high + margin { return 0 }
        if value < low { return (value - (low - margin)) / margin }
        if value > high { return ((high + margin) - value) / margin }
        return 1
    }
}
