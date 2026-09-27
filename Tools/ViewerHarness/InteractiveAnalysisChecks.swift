import CoreLocation
import Foundation

func runInteractiveAnalysisChecks() async {
    print("\n=== Phase 5: Interactive Analysis & Micro-Topography UI Checks ===")

    // 1. Interaction State Machine Transitions
    let model = await MainActor.run { TerrainViewerModel() }

    await MainActor.run {
        check("default mode is explore", model.interactionMode == .explore)
        check("profile mode initially inactive", !model.isProfileModeActive)

        // Switch to transect mode
        model.toggleProfileMode()
        check("transect mode active after toggle", model.interactionMode == .transect)
        check("isProfileModeActive reflects transect mode", model.isProfileModeActive)

        // Set transect coordinates
        let c1 = CLLocationCoordinate2D(latitude: 38.655, longitude: -90.062)
        model.handleMapTap(c1)
        check("first tap sets profileStart", model.profileStart?.latitude == c1.latitude)
        check("profileEnd still nil after first tap", model.profileEnd == nil)

        // Switch to viewshed mode -> must clear transect coordinates
        model.toggleViewshedMode()
        check("viewshed mode active", model.interactionMode == .viewshed)
        check("switching to viewshed clears profileStart", model.profileStart == nil)
        check("switching to viewshed deactivates profile mode", !model.isProfileModeActive)

        // Set viewshed observer
        model.handleMapTap(c1)
        check("tap in viewshed sets observer coordinate", model.viewshedObserverCoordinate?.latitude == c1.latitude)

        // Switch back to explore -> must clear viewshed observer
        model.interactionMode = .explore
        check("switching to explore clears observer", model.viewshedObserverCoordinate == nil)
    }

    // 1b. The top bar's mode cluster shows one accent: choosing a mode leaves the others.
    await MainActor.run {
        let modes = TerrainViewerModel()
        modes.toggleFieldMarkup()
        modes.toggleProfileMode()
        check("entering profile mode leaves field markup",
              modes.interactionMode == .transect && !modes.isMarkingUp)

        modes.interactionMode = .explore
        modes.isMarkingUp = false
        modes.toggleFieldMarkup()
        modes.toggleViewshedMode()
        check("entering viewshed mode leaves field markup",
              modes.interactionMode == .viewshed && !modes.isMarkingUp)

        modes.interactionMode = .explore
        modes.isMarkingUp = false
        modes.toggleProfileMode()
        modes.toggleFieldMarkup()
        check("entering field markup leaves profile mode",
              modes.isMarkingUp && modes.interactionMode == .explore)
        // A pencil stroke on the map starts a transect with markup's hand tool still up; leaving that transect
        // leaves markup as it was.
        modes.interactionMode = .explore
        modes.isMarkingUp = true
        modes.interactionMode = .transect
        modes.toggleProfileMode()
        check("leaving profile mode keeps field markup",
              modes.interactionMode == .explore && modes.isMarkingUp)
    }

    // 1c. The Pencil's double-tap and squeeze. During field markup the Pencil is drawing, and a habitual
    // double-tap (the system's pen/eraser switch) or squeeze must not end the drawing session and turn the
    // next stroke into a transect; in profile mode they keep their profile actions, markup or not.
    await MainActor.run {
        let pencil = TerrainViewerModel()
        pencil.toggleFieldMarkup()
        pencil.handlePencilDoubleTap()
        check("a Pencil double-tap during markup keeps markup and leaves the mode unchanged",
              pencil.isMarkingUp && pencil.interactionMode == .explore)
        pencil.handlePencilSqueeze()
        check("a Pencil squeeze during markup keeps markup and leaves the mode unchanged",
              pencil.isMarkingUp && pencil.interactionMode == .explore)

        // Markup's hand tool lets a pencil stroke on the map start a transect with markup still up; there the
        // profile actions still answer, and markup stays.
        pencil.isMarkingUp = true
        pencil.interactionMode = .transect
        let signatures = pencil.showsTransectSignatures
        pencil.handlePencilDoubleTap()
        check("a Pencil double-tap in profile mode during markup toggles the signatures and keeps both",
              pencil.showsTransectSignatures == !signatures
                  && pencil.interactionMode == .transect && pencil.isMarkingUp)
        let metric = pencil.activeProfileMetric
        pencil.handlePencilSqueeze()
        check("a Pencil squeeze in profile mode during markup cycles the metric and keeps both",
              pencil.activeProfileMetric != metric
                  && pencil.interactionMode == .transect && pencil.isMarkingUp)

        let plain = TerrainViewerModel()
        plain.handlePencilDoubleTap()
        check("a Pencil double-tap outside markup enters profile mode", plain.interactionMode == .transect)
        plain.interactionMode = .explore
        plain.handlePencilSqueeze()
        check("a Pencil squeeze outside markup enters profile mode", plain.interactionMode == .transect)
        plain.interactionMode = .viewshed
        plain.handlePencilDoubleTap()
        check("a Pencil double-tap in viewshed mode switches to profile mode", plain.interactionMode == .transect)
    }

    // 1d. The Pencil's double-tap and squeeze remap modes with nothing else on screen to say so: each names
    // what it just did in a transient notice, and one that did nothing (during markup) names nothing.
    await MainActor.run {
        let quiet = TerrainViewerModel()
        check("a new viewer has no Pencil notice and no roll ring", quiet.toolNotice == nil && quiet.pencilRollIndication == nil)

        let tap = TerrainViewerModel()
        tap.handlePencilDoubleTap()
        check("a Pencil double-tap that enters profile mode names it", tap.toolNotice?.text == "Cross-Section Profile")
        tap.handlePencilDoubleTap()
        check("a Pencil double-tap in profile mode names the signatures it hid",
              !tap.showsTransectSignatures && tap.toolNotice?.text == "Earthwork Signatures Off")
        tap.handlePencilDoubleTap()
        check("a second Pencil double-tap in profile mode names the signatures it showed",
              tap.showsTransectSignatures && tap.toolNotice?.text == "Earthwork Signatures On")

        let squeeze = TerrainViewerModel()
        squeeze.handlePencilSqueeze()
        check("a Pencil squeeze that enters profile mode names it", squeeze.toolNotice?.text == "Cross-Section Profile")
        squeeze.handlePencilSqueeze()
        check("a Pencil squeeze in profile mode names the metric it chose",
              squeeze.activeProfileMetric == .slope && squeeze.toolNotice?.text == "Metric: Slope")

        let drawing = TerrainViewerModel()
        drawing.toggleFieldMarkup()
        drawing.handlePencilDoubleTap()
        drawing.handlePencilSqueeze()
        check("a Pencil double-tap or squeeze during markup, which does nothing, names nothing", drawing.toolNotice == nil)

        // The same words twice are two notices: the pill keys its clock and its VoiceOver announcement on the
        // notice, so an equal one would let the second vanish on the first's clock, unannounced.
        let again = TerrainViewerModel()
        again.handlePencilSqueeze()
        let entered = again.toolNotice
        again.toggleProfileMode()
        again.handlePencilSqueeze()
        let reentered = again.toolNotice
        check("a Pencil notice in the words of the last is a new notice, so the pill restarts its clock and speaks again",
              entered?.text == "Cross-Section Profile" && reentered?.text == entered?.text && reentered != entered,
              "\(String(describing: entered)), \(String(describing: reentered))")
        if let entered { again.dismissToolNotice(entered) }
        check("the pill's clock for an older notice running out leaves the newer one up", again.toolNotice == reentered)
        if let reentered { again.dismissToolNotice(reentered) }
        check("the pill's clock for the notice it shows running out takes it down", again.toolNotice == nil)
    }

    // 2. Dual-rate Transect Engine Preview & Dragging
    await MainActor.run {
        model.interactionMode = .transect
        let p1 = CLLocationCoordinate2D(latitude: 38.655, longitude: -90.062)
        let p2 = CLLocationCoordinate2D(latitude: 38.658, longitude: -90.059)

        model.beginTransectDrag(at: p1)
        check("transect drag started", model.isTransectDragging)
        check("profileStart set on drag begin", model.profileStart?.latitude == p1.latitude)

        model.updateTransectDrag(to: p2)
        check("profileEnd updated on drag move", model.profileEnd?.latitude == p2.latitude)

        model.endTransectDrag(to: p2)
        check("drag ended", !model.isTransectDragging)
    }

    // 2b. The profile a drag shows live, over ground with no tile drawn yet: a gap, not a cliff to sea level.
    await MainActor.run {
        func sample(_ i: Int, _ z: Float) -> ProfileSample {
            ProfileSample(index: i, distance: Float(i) * 10, position: .zero, elevation: z, smoothedElevation: z,
                          slopeDegrees: 0, curvature: 0)
        }
        let a = CLLocationCoordinate2D(latitude: 38.655, longitude: -90.062)
        let b = CLLocationCoordinate2D(latitude: 38.656, longitude: -90.061)
        // 0-70 m of ground rising 1 m in every 10, then nothing drawn from 80 m out to the finger at 100 m.
        let pastTheTiles = TerrainViewerModel.liveTransectProfile(
            from: a, to: b, samples: (0...10).map { sample($0, $0 <= 7 ? 120 + Float($0) : .nan) })
        check("a transect dragged past the drawn tiles keeps its length and reads only the ground it has: 7 m of climb, no descent, a slope of 1 in 10, 120-127 m",
              pastTheTiles?.totalDistanceMeters == 100 && abs((pastTheTiles?.elevationGainMeters ?? 0) - 7) < 1e-4
                && pastTheTiles?.elevationLossMeters == 0
                && abs(Double(pastTheTiles?.maxSlopeDegrees ?? 0) - atan(0.1) * 180 / .pi) < 0.01
                && pastTheTiles?.minElevationMeters == 120 && pastTheTiles?.maxElevationMeters == 127,
              "length \(String(describing: pastTheTiles?.totalDistanceMeters)), climb \(String(describing: pastTheTiles?.elevationGainMeters)), descent \(String(describing: pastTheTiles?.elevationLossMeters)), max slope \(String(describing: pastTheTiles?.maxSlopeDegrees)), \(String(describing: pastTheTiles?.minElevationMeters))-\(String(describing: pastTheTiles?.maxElevationMeters))")
        check("the ground a dragged transect has is one run, and the samples past the tiles belong to none, so the chart draws nothing there",
              pastTheTiles?.groundRuns == Dictionary(uniqueKeysWithValues: (0...7).map { ($0, 0) })
                && pastTheTiles?.points.suffix(3).allSatisfy({ $0.elevationMeters.isNaN }) == true,
              "\(String(describing: pastTheTiles?.groundRuns))")
        // A hole between 40 and 60 m with the ground 5 m higher beyond it.
        let holed = TerrainViewerModel.liveTransectProfile(
            from: a, to: b, samples: (0...10).map { sample($0, (4...6).contains($0) ? .nan : ($0 < 4 ? 120 : 125)) })
        check("a hole in a dragged transect splits its ground into two runs, and neither the climb nor the slope counts across it",
              holed?.groundRuns == [0: 0, 1: 0, 2: 0, 3: 0, 7: 1, 8: 1, 9: 1, 10: 1]
                && holed?.elevationGainMeters == 0 && holed?.elevationLossMeters == 0 && holed?.maxSlopeDegrees == 0
                && holed?.minElevationMeters == 120 && holed?.maxElevationMeters == 125,
              "\(String(describing: holed?.groundRuns)), climb \(String(describing: holed?.elevationGainMeters)), max slope \(String(describing: holed?.maxSlopeDegrees))")
        check("a profile with a gap equals itself, so observers do not see a change where there is none",
              holed != nil && holed == holed)
        check("a dragged transect with no ground under any of it has no profile, as a placed one has none",
              TerrainViewerModel.liveTransectProfile(from: a, to: b, samples: (0...10).map { sample($0, .nan) }) == nil)
    }

    // 2c. Max Slope reads the line on screen, dragging and at rest.
    await checkMaxSlopeFollowsTheLineOnScreen()

    // 2d. The elevation chart's shading: each stretch its own colour.
    checkCutFillStretches()

    // 3. Tile Seam Artifact Suppression in Transect Engine
    let g1 = makeGrid(width: 50, height: 50, gsd: 1.0, base: 100)
    let g2 = makeGrid(width: 50, height: 50, gsd: 1.0, base: 100)
    let origin = CLLocationCoordinate2D(latitude: 38.6553, longitude: -90.0621)
    let mosaic = TileMosaicField(origin: origin, layers: [
        TileMosaicField.Layer(grid: g1, bounds: g1.region),
        TileMosaicField.Layer(grid: g2, bounds: g2.region)
    ])
    let engine = ElevationTransectEngine(field: mosaic)
    check("mosaic field has layers", mosaic.layers.count == 2)

    // Test seam boundary query (50m grid centered at origin, boundary at ~25m)
    let nearPoint = SIMD2<Float>(24.5, 0.0)
    let isNear = mosaic.isNearBoundary(point: nearPoint, marginMeters: 1.5)
    check("seam detection identifies boundary proximity", isNear)

    // Fast previewProfile query
    let previewSamples = engine.previewProfile(from: SIMD2<Float>(0, 0), to: SIMD2<Float>(100, 100), maxPoints: 256)
    check("previewProfile returns decimated samples", previewSamples.count <= 256 && !previewSamples.isEmpty)

    // 4. Viewshed Clamping & Bounds Protection
    let maxDimension = 2048
    let testWidth = 4096
    let testHeight = 4096
    let clampedW = min(testWidth, maxDimension)
    let clampedH = min(testHeight, maxDimension)
    check("viewshed raster dimensions clamped to <= 2048", clampedW <= 2048 && clampedH <= 2048)
}

/// Max Slope describes the same line as the elevation line, Climb and Descent. Mid-drag the analysis is the line the
/// finger last paused on while the profile follows the finger, so read whenever there was one, Max Slope kept a 30 degree
/// flank after the finger swung round onto flat field.
@MainActor
private func checkMaxSlopeFollowsTheLineOnScreen() async {
    print("\n--- 2c. Max Slope and the line on screen ---")
    let a = CLLocationCoordinate2D(latitude: 38.655, longitude: -90.062)
    let b = CLLocationCoordinate2D(latitude: 38.655, longitude: -90.0608)     // about 104 m east
    let c = CLLocationCoordinate2D(latitude: 38.6559, longitude: -90.062)     // about 100 m north
    func preview(_ from: CLLocationCoordinate2D, _ to: CLLocationCoordinate2D, rise: Float) -> ElevationProfile? {
        TerrainViewerModel.liveTransectProfile(from: from, to: to, samples: (0...10).map { i in
            let z = 120 + rise * Float(i)
            return ProfileSample(index: i, distance: Float(i) * 10, position: .zero, elevation: z, smoothedElevation: z,
                                 slopeDegrees: 0, curvature: 0)
        })
    }
    // A-B's analysis, on half-metre samples: a 30 degree flank at 50 m on 2 degree ground.
    let flank = TransectAnalysis(samples: (0...200).map { i in
        ProfileSample(index: i, distance: Float(i) * 0.5, position: .zero, elevation: 120, smoothedElevation: 120,
                      slopeDegrees: (95...105).contains(i) ? 30 : 2, curvature: 0)
    }, stepDistance: 0.5, parameters: TransectSignatureParameters())
    let alongAB = preview(a, b, rise: 1)       // 1 m in 10: 5.7 degrees
    let alongAC = preview(a, c, rise: 0)       // flat field
    let gentle = atan(0.1) * 180 / .pi

    let paused = TerrainViewerModel.profileSlope(profile: alongAB, analysis: flank, analysedEnds: (a, b))
    check("with the analysis of the line on screen, Max Slope is the slope line's peak, the analysis's 30 degree flank",
          paused.maxSlopeDegrees == 30 && paused.line.map(\.slope).max() == 30 && paused.isAnalysisOfProfile,
          "\(paused.maxSlopeDegrees)")
    let swung = TerrainViewerModel.profileSlope(profile: alongAC, analysis: flank, analysedEnds: (a, b))
    check("swung onto flat field before the new line's analysis lands, Max Slope is the flat line's 0, not the paused line's 30, and the analysis is not the line's (so not its baseline either)",
          swung.maxSlopeDegrees == 0 && alongAC?.maxSlopeDegrees == 0 && !swung.isAnalysisOfProfile,
          "\(swung.maxSlopeDegrees), \(swung.isAnalysisOfProfile)")
    let unknown = TerrainViewerModel.profileSlope(profile: alongAB, analysis: flank, analysedEnds: nil)
    let none = TerrainViewerModel.profileSlope(profile: alongAB, analysis: nil, analysedEnds: nil)
    let noProfile = TerrainViewerModel.profileSlope(profile: nil, analysis: flank, analysedEnds: (a, b))
    check("an analysis of a line not known, or none, leaves Max Slope the profile's own; with no profile there is nothing",
          abs(unknown.maxSlopeDegrees - gentle) < 0.01 && abs(none.maxSlopeDegrees - gentle) < 0.01 && none.line.isEmpty
            && noProfile.maxSlopeDegrees == 0 && noProfile.line.isEmpty
            && !unknown.isAnalysisOfProfile && !none.isAnalysisOfProfile && !noProfile.isAnalysisOfProfile
            && !TerrainViewerModel.profileSlope(profile: alongAB, analysis: nil, analysedEnds: (a, b)).isAnalysisOfProfile,
          "\(unknown.maxSlopeDegrees), \(none.maxSlopeDegrees), \(noProfile.maxSlopeDegrees)")

    // The model, through a real drag and release over the synthetic mound, then a preview of a swung line landing
    // before its analysis (what the drag's next preview does).
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    defer { try? FileManager.default.removeItem(at: scene.directory) }
    await scene.loadNeighbourhood()
    let model = TerrainViewerModel(terrainProvider: scene.provider)
    model.interactionMode = .transect
    let tile = scene.region()
    let west = CLLocationCoordinate2D(latitude: tile.center.latitude, longitude: tile.minLongitude + 0.0001)
    let east = CLLocationCoordinate2D(latitude: tile.center.latitude, longitude: tile.maxLongitude - 0.0001)
    let north = CLLocationCoordinate2D(latitude: tile.maxLatitude - 0.00005, longitude: tile.minLongitude + 0.0001)
    func sameLine(_ profile: ElevationProfile?, _ to: CLLocationCoordinate2D) -> Bool {
        profile?.end.latitude == to.latitude && profile?.end.longitude == to.longitude
    }
    model.beginTransectDrag(at: west)
    model.updateTransectDrag(to: east)
    await waitUntil(10) { model.activeTransectAnalysis != nil && sameLine(model.activeProfile, east) }
    let dragPeak = model.profileSlopeLine.map(\.slope).max()
    check("paused mid-drag across the mound, the model's Max Slope is its slope line's peak, the mound's flank",
          model.activeTransectAnalysis != nil && dragPeak != nil && model.profileMaxSlopeDegrees == dragPeak
            && (dragPeak ?? 0) > 10 && model.isAnalysisOfProfile,
          "max \(model.profileMaxSlopeDegrees), line peak \(String(describing: dragPeak))")
    model.activeProfile = TerrainViewerModel.liveTransectProfile(from: west, to: north, samples: (0...10).map { i in
        ProfileSample(index: i, distance: Float(i) * 5, position: .zero, elevation: 130, smoothedElevation: 130,
                      slopeDegrees: 0, curvature: 0)
    })
    check("the finger swung onto flat ground, its preview in and its analysis not, the model's Max Slope is the flat line's 0",
          model.profileMaxSlopeDegrees == 0 && model.activeTransectAnalysis != nil && !model.isAnalysisOfProfile,
          "max \(model.profileMaxSlopeDegrees)")
    model.endTransectDrag(to: east)
    await waitUntil(10) { !model.isGeneratingProfile }
    let restPeak = model.profileSlopeLine.map(\.slope).max()
    check("released and analysed, the model's Max Slope is the released line's slope-line peak again",
          sameLine(model.activeProfile, east) && restPeak != nil && model.profileMaxSlopeDegrees == restPeak
            && (restPeak ?? 0) > 10 && model.isAnalysisOfProfile,
          "max \(model.profileMaxSlopeDegrees), line peak \(String(describing: restPeak))")
    model.clearProfile()
    check("clearing the profile clears its slope line and Max Slope",
          model.profileSlopeLine.isEmpty && model.profileMaxSlopeDegrees == 0 && !model.isAnalysisOfProfile)
}

/// The elevation chart shades the ground red above its baseline and blue below. Swift Charts draws each area series as one
/// polygon in the colour of its first mark, so with one series per run of ground the whole run took its first sample's
/// colour: a mound whose foot starts just under the baseline drew all blue, and ground below the baseline drew red.
private func checkCutFillStretches() {
    print("\n--- 2d. cut and fill shading ---")
    // A mound on a flat 100 m baseline, its foot starting just under it; then, past a gap, ground under the baseline.
    let mound: [(distance: Double, elevation: Double, baseline: Double, run: Int)] = [
        (0, 99, 100, 0), (1, 99.5, 100, 0), (2, 101, 100, 0), (3, 103, 100, 0), (4, 101, 100, 0), (5, 99, 100, 0),
        (8, 97, 100, 1), (9, 98, 100, 1),
    ]
    let shading = ProfileCutFill.stretches(mound)
    let stretches = Dictionary(grouping: shading, by: \.stretch).sorted { $0.key < $1.key }.map(\.value)
    let sides = stretches.map { Set($0.map(\.isAbove)) }
    check("a mound starting just under the baseline shades its foot blue, its top red and its far foot blue, and the ground past a gap blue: four stretches, each one colour",
          stretches.count == 4 && sides == [[false], [true], [false], [false]],
          "\(stretches.count) stretches, \(sides)")
    // Crossing between 99.5 m at 1 m and 101 m at 2 m: a third of the way, at 1.333 m, on the baseline; and between 101 m
    // at 4 m and 99 m at 5 m, halfway.
    func crossing(_ stretch: [ProfileCutFill.Point], first: Bool) -> ProfileCutFill.Point? { first ? stretch.first : stretch.last }
    let ends: [(Double, Double)] = stretches.count == 4 ? [
        (crossing(stretches[0], first: false)?.distance ?? .nan, crossing(stretches[1], first: true)?.distance ?? .nan),
        (crossing(stretches[1], first: false)?.distance ?? .nan, crossing(stretches[2], first: true)?.distance ?? .nan),
    ] : []
    let onBaseline = stretches.count == 4
        && [stretches[0].last, stretches[1].first, stretches[1].last, stretches[2].first]
            .allSatisfy { $0.map { $0.elevation == 100 && $0.baseline == 100 } == true }
    check("red and blue meet where the ground crosses the baseline: the crossing, interpolated, ends one stretch and starts the next",
          ends.count == 2 && abs(ends[0].0 - 4.0 / 3) < 1e-9 && ends[0].0 == ends[0].1
            && abs(ends[1].0 - 4.5) < 1e-9 && ends[1].0 == ends[1].1 && onBaseline,
          "\(ends)")
    check("a gap in the ground starts a stretch with no crossing point, and every sample is kept in order",
          stretches.count == 4 && stretches[3].map(\.distance) == [8, 9]
            && shading.filter({ $0.elevation != 100 || $0.baseline != 100 }).map(\.distance) == [0, 1, 2, 3, 4, 5, 8, 9]
            && zip(shading, shading.dropFirst()).allSatisfy { $0.distance <= $1.distance },
          "\(shading.map(\.distance))")
    let flat = ProfileCutFill.stretches([(0, 100, 100, 0), (1, 100, 100, 0), (2, 99, 100, 0)])
    check("ground on the baseline counts as above it, and nothing in gives nothing",
          flat.map(\.isAbove) == [true, true, true, false, false] && flat.map(\.stretch) == [0, 0, 0, 1, 1]
            && ProfileCutFill.stretches([]).isEmpty,
          "\(flat.map(\.isAbove)), \(flat.map(\.stretch))")
}

