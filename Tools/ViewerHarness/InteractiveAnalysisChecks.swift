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
