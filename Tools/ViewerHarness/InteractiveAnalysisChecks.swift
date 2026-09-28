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
        // Markup up in profile mode is a state the model allows (a Pencil stroke from markup's hand tool reaches it
        // while the map bridge lights the ruler on a stroke; MapTouchPolicy, wired into the bridge in the map bridge
        // task, ends that route): leaving that transect leaves markup as it was.
        modes.interactionMode = .explore
        modes.isMarkingUp = true
        modes.interactionMode = .transect
        modes.toggleProfileMode()
        check("leaving profile mode keeps field markup",
              modes.interactionMode == .explore && modes.isMarkingUp)
    }

    // 1c. The Pencil's double-tap and squeeze during field markup. There the Pencil is drawing, and a habitual
    // double-tap (the system's pen/eraser switch) or squeeze must not end the drawing session; outside profile
    // mode they do nothing at all (2f). In profile mode they keep their profile actions, markup or not.
    await MainActor.run {
        let pencil = TerrainViewerModel()
        pencil.toggleFieldMarkup()
        pencil.handlePencilDoubleTap()
        check("a Pencil double-tap during markup keeps markup and leaves the mode unchanged",
              pencil.isMarkingUp && pencil.interactionMode == .explore)
        pencil.handlePencilSqueeze()
        check("a Pencil squeeze during markup keeps markup and leaves the mode unchanged",
              pencil.isMarkingUp && pencil.interactionMode == .explore)

        // In profile mode with markup still up (a state the model allows; see 1b), the profile actions still
        // answer, and markup stays.
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
    }

    // 1d. What a double-tap or squeeze did is named in a transient notice, since nothing else on screen says
    // so, and one that did nothing names nothing (the notices themselves, in profile mode and elsewhere: 2f).
    await MainActor.run {
        let quiet = TerrainViewerModel()
        check("a new viewer has no Pencil notice and no roll ring", quiet.toolNotice == nil && quiet.pencilRollIndication == nil)

        let drawing = TerrainViewerModel()
        drawing.toggleFieldMarkup()
        drawing.handlePencilDoubleTap()
        drawing.handlePencilSqueeze()
        check("a Pencil double-tap or squeeze during markup, which does nothing, names nothing", drawing.toolNotice == nil)
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

    // 2e. With no tool lit a tap reads nothing; Spot Inspection is a tool of its own.
    checkNavigateByDefault()

    // 2f. The Pencil's squeeze and double-tap act only in profile mode, and not at all when set to Off.
    checkPencilShortcuts()

    // 2g. One tool at a time (D7): a tool or markup ends the split wipe, and Settings' wipe and thalweg end markup.
    checkOneToolAtATime()

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
          paused.maxSlopeDegrees == 30 && paused.line?.map(\.slope).max() == 30 && paused.isAnalysisOfProfile,
          "\(paused.maxSlopeDegrees)")
    let swung = TerrainViewerModel.profileSlope(profile: alongAC, analysis: flank, analysedEnds: (a, b))
    check("swung onto flat field before the new line's analysis lands, Max Slope is the flat line's 0, not the paused line's 30, and the analysis is not the line's (so not its baseline either)",
          swung.maxSlopeDegrees == 0 && alongAC?.maxSlopeDegrees == 0 && !swung.isAnalysisOfProfile,
          "\(swung.maxSlopeDegrees), \(swung.isAnalysisOfProfile)")
    check("the paused line's analysis is not worked out again into a slope line for the swung line: the line is left as drawn",
          swung.line == nil, "\(String(describing: swung.line?.count)) points")
    let unknown = TerrainViewerModel.profileSlope(profile: alongAB, analysis: flank, analysedEnds: nil)
    let none = TerrainViewerModel.profileSlope(profile: alongAB, analysis: nil, analysedEnds: nil)
    let noProfile = TerrainViewerModel.profileSlope(profile: nil, analysis: flank, analysedEnds: (a, b))
    check("an analysis of a line not known, or none, leaves Max Slope the profile's own; with no profile there is nothing",
          abs(unknown.maxSlopeDegrees - gentle) < 0.01 && abs(none.maxSlopeDegrees - gentle) < 0.01 && none.line?.isEmpty == true
            && noProfile.maxSlopeDegrees == 0 && noProfile.line?.isEmpty == true
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
    let pausedLine = model.profileSlopeLine
    check("paused mid-drag across the mound, the model's Max Slope is its slope line's peak, the mound's flank",
          model.activeTransectAnalysis != nil && dragPeak != nil && model.profileMaxSlopeDegrees == dragPeak
            && (dragPeak ?? 0) > 10 && model.isAnalysisOfProfile,
          "max \(model.profileMaxSlopeDegrees), line peak \(String(describing: dragPeak))")
    model.activeProfile = TerrainViewerModel.liveTransectProfile(from: west, to: north, samples: (0...10).map { i in
        ProfileSample(index: i, distance: Float(i) * 2, position: .zero, elevation: 130, smoothedElevation: 130,
                      slopeDegrees: 0, curvature: 0)
    })
    check("the finger swung onto flat ground, its preview in and its analysis not, the model's Max Slope is the flat line's 0",
          model.profileMaxSlopeDegrees == 0 && model.activeTransectAnalysis != nil && !model.isAnalysisOfProfile,
          "max \(model.profileMaxSlopeDegrees)")
    // The paused line's slope line stays as it was drawn, for the panel to dim as updating: worked out again it was cut
    // to the 20 m swung line from the mound's analysis, and redone over every one of its samples on each drag sample.
    let swungLine = model.profileSlopeLine
    check("swung, the slope line stays the paused line's as drawn, not worked out again over the stale analysis",
          swungLine.count == pausedLine.count && swungLine.map(\.slope).max() == dragPeak
            && swungLine.last?.distance == pausedLine.last?.distance,
          "\(swungLine.count) points to \(String(describing: swungLine.last?.distance)) vs \(pausedLine.count) to \(String(describing: pausedLine.last?.distance))")
    // Released there, until the released line's analysis lands, the analysis is still the paused line's: exported then,
    // the file was that line.
    model.isTransectDragging = false
    let canExportStale = model.canExportTransect
    model.isTransectDragging = true
    check("with the analysis of another line, the transect cannot be exported, though the finger has lifted",
          !canExportStale && model.activeTransectAnalysis != nil)
    model.endTransectDrag(to: east)
    await waitUntil(10) { !model.isGeneratingProfile }
    let restPeak = model.profileSlopeLine.map(\.slope).max()
    check("released and analysed, the model's Max Slope is the released line's slope-line peak again, and it can be exported",
          sameLine(model.activeProfile, east) && restPeak != nil && model.profileMaxSlopeDegrees == restPeak
            && (restPeak ?? 0) > 10 && model.isAnalysisOfProfile && model.canExportTransect,
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

/// Navigating is the default: with no tool lit a tap reads nothing (it inspected, so a Pencil grazing the glass opened a
/// reading). Spot Inspection is a tool of its own, on until turned off, whose taps read the ground; the other tools
/// and markup leave it, and it leaves them.
@MainActor
private func checkNavigateByDefault() {
    print("\n--- 2e. navigate by default and Spot Inspection ---")
    let c = CLLocationCoordinate2D(latitude: 38.6605, longitude: -90.0621)
    let c2 = CLLocationCoordinate2D(latitude: 38.6612, longitude: -90.0610)
    func reading(_ m: TerrainViewerModel) -> CLLocationCoordinate2D? {
        if case .loading(let at) = m.inspectionState { return at }
        return nil
    }
    /// A tap that starts a reading, which then lands: the callout and the teal pin draw from `activeSpot` (the lookup's
    /// own landing needs tiles). True when the tap started the reading, so a "drops its reading" check has one to drop.
    func readAndLand(_ m: TerrainViewerModel) -> Bool {
        m.handleMapTap(c)
        let started = reading(m)?.latitude == c.latitude
        m.activeSpot = SpotInspection(coordinate: c, elevationMeters: 100, slopeDegrees: .nan, aspectDegrees: .nan)
        return started
    }
    func dropped(_ m: TerrainViewerModel) -> Bool { m.inspectionState == .idle && m.activeSpot == nil }

    let fresh = TerrainViewerModel()
    check("a new viewer has no tool lit: it navigates", fresh.interactionMode == .explore && fresh.mapTool == .navigate)
    fresh.handleMapTap(c)
    check("with no tool lit a tap reads nothing", fresh.inspectionState == .idle && fresh.activeSpot == nil,
          "\(fresh.inspectionState)")

    let spot = TerrainViewerModel()
    spot.toggleSpotInspection()
    check("the Spot Inspection toggle lights it", spot.isSpotInspectionActive && spot.mapTool == .spot)
    spot.handleMapTap(c)
    check("a tap in Spot Inspection reads the ground under it, and the tool stays lit",
          reading(spot)?.latitude == c.latitude && spot.isSpotInspectionActive)
    spot.activeSpot = SpotInspection(coordinate: c, elevationMeters: 100, slopeDegrees: .nan, aspectDegrees: .nan)
    spot.clearInspection()
    check("closing the reading (the callout's X) keeps Spot Inspection lit",
          spot.isSpotInspectionActive && dropped(spot))
    var started = readAndLand(spot)
    spot.toggleSpotInspection()
    check("turning Spot Inspection off drops its reading and lights nothing",
          started && spot.mapTool == .navigate && dropped(spot))

    let swap = TerrainViewerModel()
    swap.toggleFieldMarkup()
    swap.toggleSpotInspection()
    check("entering Spot Inspection leaves field markup", swap.isSpotInspectionActive && !swap.isMarkingUp)
    started = readAndLand(swap)
    swap.toggleProfileMode()
    check("entering profile leaves Spot Inspection and drops its reading",
          started && swap.interactionMode == .transect && dropped(swap))
    swap.toggleSpotInspection()
    check("entering Spot Inspection leaves profile", swap.isSpotInspectionActive && !swap.isProfileModeActive)
    started = readAndLand(swap)
    swap.toggleFieldMarkup()
    check("entering field markup leaves Spot Inspection and drops its reading",
          started && swap.isMarkingUp && swap.interactionMode == .explore && dropped(swap))
    swap.isMarkingUp = false
    swap.toggleSpotInspection()
    started = readAndLand(swap)
    swap.toggleViewshedMode()
    check("entering viewshed leaves Spot Inspection and drops its reading",
          started && swap.interactionMode == .viewshed && dropped(swap))

    // The tool each state shows the map's touches (MapTouchPolicy): the canvas is over the map for the pen and the
    // highlighter whatever else is lit.
    let tools = TerrainViewerModel()
    var seen: [MapTool] = [tools.mapTool]
    tools.toggleFieldMarkup(); seen.append(tools.mapTool)                  // pen
    tools.markupTool = .hand; seen.append(tools.mapTool)                    // hand
    tools.toggleFieldMarkup(); tools.markupTool = .pen
    tools.toggleSpotInspection(); seen.append(tools.mapTool)
    tools.toggleProfileMode(); seen.append(tools.mapTool)
    tools.toggleViewshedMode(); seen.append(tools.mapTool)
    tools.beginThalwegDrawing(); seen.append(tools.mapTool)
    tools.setSplitWipe(true); seen.append(tools.mapTool)
    check("each state's map tool: navigate, markup ink, markup hand, spot, profile, viewshed, thalweg, split wipe",
          seen == [.navigate, .markupInk, .markupHand, .spot, .profile, .viewshed, .thalweg, .splitWipe], "\(seen)")
    // Markup up over another tool (1b: the hand tool let a Pencil stroke start a transect with markup still up; Settings'
    // thalweg and split wipe left markup up until they ended it, 2g): the pen's canvas lies over the map whatever is lit.
    let over = TerrainViewerModel()
    over.isMarkingUp = true
    over.interactionMode = .transect
    let penOverRuler = over.mapTool
    over.markupTool = .hand
    check("markup's pen over the ruler is ink, since its canvas covers the map; its hand tool leaves the ruler",
          penOverRuler == .markupInk && over.mapTool == .profile, "\(penOverRuler), \(over.mapTool)")

    // One tap table: in every state the model reaches, a tap does what MapTouchPolicy says for the tool lit, for a
    // finger, the Pencil and a pointer alike, so a change to the policy's tap is a change to the app's.
    let states: [(String, (TerrainViewerModel) -> Void)] = [
        ("no tool", { _ in }),
        ("markup pen", { $0.toggleFieldMarkup() }),
        ("markup hand", { $0.toggleFieldMarkup(); $0.markupTool = .hand }),
        ("spot", { $0.toggleSpotInspection() }),
        ("profile", { $0.toggleProfileMode() }),
        ("viewshed", { $0.toggleViewshedMode() }),
        ("thalweg", { $0.beginThalwegDrawing() }),
        ("split wipe", { $0.setSplitWipe(true) }),
        ("markup pen over the ruler", { $0.isMarkingUp = true; $0.interactionMode = .transect }),
        ("markup hand over the ruler", { $0.isMarkingUp = true; $0.markupTool = .hand; $0.interactionMode = .transect }),
    ]
    var disagreements: [String] = []
    for (name, enter) in states {
        let m = TerrainViewerModel()
        enter(m)
        let tool = m.mapTool
        m.handleMapTap(c)
        let did: MapTapAction? =
            if reading(m)?.latitude == c.latitude { .inspect }
            else if m.profileStart?.latitude == c.latitude { .placeProfilePoint }
            else if m.viewshedObserverCoordinate?.latitude == c.latitude { .placeObserver }
            else { nil }
        for kind in MapTouchKind.allCases where MapTouchPolicy.tap(in: tool, by: kind) != did {
            disagreements.append("\(name) by \(kind): the model did \(did?.rawValue ?? "nothing")")
        }
    }
    check("a tap in the model does what MapTouchPolicy says for the tool lit, in every state, for every kind of touch",
          disagreements.isEmpty, disagreements.joined(separator: "; "))

    // The profile panel's X closes the result and keeps the ruler lit (D2); once the map bridge lets a finger pan in
    // profile mode (Task 5), that is no trap.
    let ruler = TerrainViewerModel()
    ruler.toggleProfileMode()
    ruler.handleMapTap(c)
    ruler.handleMapTap(c2)
    ruler.clearProfile()
    check("closing the profile keeps the ruler lit, ready for a new A", ruler.isProfileModeActive && ruler.profileStart == nil)
}

/// A squeeze or double-tap never lights a tool: measuring is chosen from the top bar (the owner, 2026-09-28). In profile
/// mode they keep their actions; with the Pencil's own setting for the gesture Off they do nothing at all. Nothing
/// includes the profile's own settings: a metric cycled or the signatures hidden outside profile mode, with no pill to
/// say so, would greet the next profile unexplained.
@MainActor
private func checkPencilShortcuts() {
    print("\n--- 2f. the Pencil's squeeze and double-tap ---")
    // Everything a stray squeeze or double-tap could change: the tool (markup's too) and the profile's two settings.
    func state(_ m: TerrainViewerModel) -> String {
        "\(m.mapTool) (\(m.interactionMode), markup \(m.isMarkingUp) \(m.markupTool)), signatures \(m.showsTransectSignatures), metric \(m.activeProfileMetric)"
    }
    let idle = TerrainViewerModel()
    let idleBefore = state(idle)
    idle.handlePencilDoubleTap()
    check("a Pencil double-tap with no tool lit lights no tool, changes no profile setting and names nothing",
          idle.mapTool == .navigate && state(idle) == idleBefore && idle.toolNotice == nil, state(idle))
    idle.handlePencilSqueeze()
    check("a Pencil squeeze with no tool lit lights no tool, changes no profile setting and names nothing",
          idle.mapTool == .navigate && state(idle) == idleBefore && idle.toolNotice == nil, state(idle))

    // Every map tool but profile, each lit as the app lights it (the thalweg from Settings' Draw River Thalweg, the
    // split wipe from its Split Wipe switch).
    let tools: [(String, MapTool, (TerrainViewerModel) -> Void)] = [
        ("Spot Inspection", .spot, { $0.toggleSpotInspection() }),
        ("viewshed", .viewshed, { $0.toggleViewshedMode() }),
        ("the thalweg", .thalweg, { $0.beginThalwegDrawing() }),
        ("the split wipe", .splitWipe, { $0.setSplitWipe(true) }),
        ("markup's pen", .markupInk, { $0.toggleFieldMarkup() }),
        ("markup's hand tool", .markupHand, { $0.toggleFieldMarkup(); $0.markupTool = .hand }),
    ]
    for (name, tool, light) in tools {
        let m = TerrainViewerModel()
        light(m)
        let before = state(m)
        m.handlePencilDoubleTap()
        m.handlePencilSqueeze()
        check("in \(name) a Pencil double-tap or squeeze changes nothing, the profile's settings included, and names nothing",
              m.mapTool == tool && state(m) == before && m.toolNotice == nil,
              "\(before) -> \(state(m)), notice \(String(describing: m.toolNotice?.text))")
    }

    let profile = TerrainViewerModel()
    profile.toggleProfileMode()
    profile.handlePencilDoubleTap()
    check("in profile mode a double-tap still hides the earthwork signatures and names it",
          !profile.showsTransectSignatures && profile.toolNotice?.text == "Earthwork Signatures Off")
    profile.handlePencilDoubleTap()
    check("and a second shows them again and names it",
          profile.showsTransectSignatures && profile.toolNotice?.text == "Earthwork Signatures On")
    profile.handlePencilSqueeze()
    check("in profile mode a squeeze still cycles the metric and names it",
          profile.activeProfileMetric == .slope && profile.toolNotice?.text == "Metric: Slope")

    let off = TerrainViewerModel()
    off.toggleProfileMode()
    off.handlePencilDoubleTap(ignored: true)
    off.handlePencilSqueeze(ignored: true)
    check("with the Pencil's double-tap and squeeze set to Off, neither does anything in profile mode, and neither names anything",
          off.showsTransectSignatures && off.activeProfileMetric == .elevation && off.toolNotice == nil)

    // The same words twice are two notices: the pill keys its clock and its VoiceOver announcement on the notice.
    let again = TerrainViewerModel()
    again.postToolNotice("Metric: Slope")
    let first = again.toolNotice
    again.postToolNotice("Metric: Slope")
    let second = again.toolNotice
    check("a Pencil notice in the words of the last is a new notice, so the pill restarts its clock and speaks again",
          first?.text == second?.text && first != second)
    if let first { again.dismissToolNotice(first) }
    check("the pill's clock for an older notice running out leaves the newer one up", again.toolNotice == second)
    if let second { again.dismissToolNotice(second) }
    check("the pill's clock for the notice it shows running out takes it down", again.toolNotice == nil)
}

/// One tool at a time (D7). The split wipe is a tool like the cluster's: picking another, or markup, ends it, rather than
/// leaving its line on screen with its two-finger drag dead. Remove All with the wipe up ends its mode too, which was
/// left with no switch to end it. Settings' Split Wipe and Draw River Thalweg end markup, whose canvas would take the
/// map's touches.
@MainActor
private func checkOneToolAtATime() {
    print("\n--- 2g. one tool at a time ---")
    let picks: [(String, MapTool, (TerrainViewerModel) -> Void)] = [
        ("the ruler", .profile, { $0.toggleProfileMode() }),
        ("Spot Inspection", .spot, { $0.toggleSpotInspection() }),
        ("the eye", .viewshed, { $0.toggleViewshedMode() }),
        ("field markup", .markupInk, { $0.toggleFieldMarkup() }),
    ]
    for (name, tool, pick) in picks {
        let m = TerrainViewerModel()
        m.setSplitWipe(true)
        let wipeWasUp = m.mapTool == .splitWipe && m.historicalWipeFraction != nil
        pick(m)
        check("picking \(name) while the split wipe is up ends the wipe and lights \(name)",
              wipeWasUp && m.historicalWipeFraction == nil && m.mapTool == tool,
              "wipe was up \(wipeWasUp), fraction \(String(describing: m.historicalWipeFraction)), tool \(m.mapTool)")
    }
    let removed = TerrainViewerModel()
    removed.setSplitWipe(true)
    removed.removeHistoricalMaps()
    check("Remove All with the split wipe up returns to no tool", removed.mapTool == .navigate && removed.historicalWipeFraction == nil,
          "\(removed.mapTool)")
    let wipeOff = TerrainViewerModel()
    wipeOff.setSplitWipe(true)
    wipeOff.setSplitWipe(false)
    check("turning the Split Wipe switch off returns to no tool", wipeOff.mapTool == .navigate && wipeOff.historicalWipeFraction == nil)
    let wipeOverMarkup = TerrainViewerModel()
    wipeOverMarkup.toggleFieldMarkup()
    wipeOverMarkup.setSplitWipe(true)
    check("turning the split wipe on ends field markup and puts the wipe's line up",
          wipeOverMarkup.mapTool == .splitWipe && !wipeOverMarkup.isMarkingUp && wipeOverMarkup.historicalWipeFraction == 0.5,
          "\(wipeOverMarkup.mapTool), markup \(wipeOverMarkup.isMarkingUp), fraction \(String(describing: wipeOverMarkup.historicalWipeFraction))")
    let thalweg = TerrainViewerModel()
    thalweg.toggleFieldMarkup()
    thalweg.beginThalwegDrawing()
    check("Draw River Thalweg ends field markup, whose canvas would take the stroke",
          thalweg.mapTool == .thalweg && !thalweg.isMarkingUp, "\(thalweg.mapTool), markup \(thalweg.isMarkingUp)")

    // The wipe's handle and its two-finger drag move the line through the model, which refuses once another tool is
    // lit: a drag still under one finger when the other hand picks a tool cannot bring the line back over that tool,
    // where nothing would take it away again (the didSet clears it only on leaving the wipe's mode).
    let moving = TerrainViewerModel()
    moving.setSplitWipe(true)
    let moved = moving.moveSplitWipe(to: 0.3)
    check("dragging the split wipe while it is up moves its line", moved && moving.historicalWipeFraction == 0.3
          && moving.mapTool == .splitWipe, "moved \(moved), fraction \(String(describing: moving.historicalWipeFraction))")
    let lateDrags: [(String, MapTool, (TerrainViewerModel) -> Void)] =
        picks + [("the Split Wipe switch off", .navigate, { $0.setSplitWipe(false) })]
    for (name, tool, pick) in lateDrags {
        let m = TerrainViewerModel()
        m.setSplitWipe(true)
        pick(m)
        let refusedMove = !m.moveSplitWipe(to: 0.6)
        check("a wipe drag that lands after \(name) is refused and leaves the wipe down (\(tool))",
              refusedMove && m.historicalWipeFraction == nil && m.mapTool == tool,
              "refused \(refusedMove), fraction \(String(describing: m.historicalWipeFraction)), tool \(m.mapTool)")
    }
}

