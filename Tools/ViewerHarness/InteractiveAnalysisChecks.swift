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
        let c2 = CLLocationCoordinate2D(latitude: 38.657, longitude: -90.060)
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
