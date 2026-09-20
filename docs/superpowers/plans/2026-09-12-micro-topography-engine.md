# Micro-Topography & Terrain Analysis Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the brief's micro-topography engine in the iPadOS app — GPU LRM/RRIM/SVF/raking/REM/habitation products on the map, real-time transects with earthwork signatures, a draggable viewshed, historical-map wipe and SSURGO soil hatching — within the brief's GPU, frame-rate and memory budgets.

**Architecture:** Metal compute kernels in `TerrainKernels.metal` dispatched by `actor MetalTerrainPipelineActor` over zero-copy R32F textures; `actor ElevationTileCoordinator` streams 3DEP 1 m COGs into page-aligned memory; `TerrainTileProvider` stitches cached neighbours into analysis rasters for the micro styles; transects run on a Sendable `ElevationField`; SwiftUI + MapKit surface the tools.

**Tech Stack:** Swift 6 (strict concurrency, default `MainActor` isolation), Metal 3 (compute + render), MapKit (`MKTileOverlay`, custom renderers), SwiftUI + Swift Charts, shell-compiled regression harness (not XCTest).

---

## How to use this document (Claude Code or Antigravity)

- **Authoritative:** this file (execution) and `STATUS.md` (current state). Keep both updated when a task lands.
- **Rationale only:** `specs/2026-09-12-micro-topography-engine-design.md` (design + calibration),
  `specs/…-design-reviewed.md` and `plans/…-engine-reviewed.md` (Antigravity's devil's-advocate audit; read their
  calibration notes first), `plans/…-progress-checkpoint.md` (historical; overstated).
- Work top to bottom: **Part B (defects) before Part C (features)**. Tick checkboxes as steps complete.
- After each task: run the harness; after UI tasks also run `xcodebuild`. Record numbers in `STATUS.md`.
- Blocker protocol (from `/Users/herren/dev/CLAUDE.md`): if a step needs a human (login, device unlock, signing),
  write it to `/Users/herren/dev/HUMAN_DO_THIS.md` and move to the next task.

## Background the engineer needs

**Commands**
```bash
./Tools/run-harness.sh /tmp/lidar-renders
```
Offline suite (~1–2 min). Prints `PASS`/`FAIL` lines and ends with `ALL CHECKS PASSED`. Writes sample PNGs (`micro_*.png`) to the directory given.
```bash
./Tools/run-live-check.sh
```
Network suite (TNM API, S3 COGs, 3DEP ImageServer). The ImageServer can take > 30 s for a cold extent.
```bash
xcodebuild -project LidarExplorer.xcodeproj -scheme LidarExplorer -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' -configuration Debug build
```
The only check that compiles the SwiftUI/MapKit views (`TerrainMapView`, `ElevationProfileView`, settings, dock, top bar).

**Harness conventions**
- Not XCTest: `Tools/ViewerHarness/main.swift` plus `*Checks.swift` files, compiled with an **explicit file list** in
  `Tools/run-harness.sh` (and a second list in `Tools/run-live-check.sh`). A new source file must be added to the
  list(s); the Xcode target uses synchronized folders and needs no `pbxproj` edit.
- Assertions use the global `check(_ name: String, _ ok: Bool, _ detail: String = "")`. Shared helpers:
  `makeGrid(width:height:gsd:base:slope:mounds:voids:)` (main.swift), `sceneGrid(width:height:gsd:_:)`,
  `planeMismatch`, `hashNoise`, `platformScene`, `mesaScene` (MicroTopographyChecks.swift), `profileStrip`,
  `moundProfile` (TransectChecks.swift), `rgbaBytes(_:)`, `writePNG(_:to:)` (main.swift).
- A referenced-but-undefined symbol is a compile error that aborts the whole harness; the expected "red" for a new
  symbol is therefore a compile error, stated in each task.

**Swift/Metal gotchas already paid for**
- Default isolation is `MainActor` (Xcode `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, harness
  `-default-isolation MainActor`): every new value type used off the main actor must be declared `nonisolated`.
- Passing a non-`Sendable` value (e.g. `MTLCommandBuffer`) from an actor to a `nonisolated async` function is a
  "sending" error — keep such helpers actor-isolated.
- **Metal compiles with fast math.** `atan2(y, -x)` where `x` can be `+0` returns the wrong half-plane. Write
  offsets as differences that are exactly `+0` and guard the zero case (see `compute_viewshed`).
- Linear textures need `bytesPerRow % minimumLinearTextureAlignment == 0` (16 on M-series): keep analysis-raster
  widths multiples of 4 to stay zero-copy. The iOS Simulator raises on linear textures; the pipeline actor switches
  to private textures + GPU blits there automatically (`SurfaceMode.blit`).
- The 3DEP ImageServer forces square pixels: a non-square Mercator bbox comes back wider than requested. Compare
  rasters only over square footprints (real map tiles are square).

**Data facts**
- 1 m DEM COGs: `https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/1m/Projects/<project>/TIFF/*.tif`,
  discovered via `https://tnmaccess.nationalmap.gov/api/v1/products?datasets=Digital%20Elevation%20Model%20(DEM)%201%20meter&bbox=minLon,minLat,maxLon,maxLat&prodFormats=GeoTIFF&outputFormat=JSON`.
  Projects overlap; prefer those containing the region, then newest `publicationDate`. UTM zones per project.
- Map tiles: 256 pt @2x = 512 px, fetched with a 4 px skirt (`TerrainTileProvider.marginPixels`); z18+ from 3DEP
  (≈ 0.23 m/px at z18@2x, 0.117 m at z19 — oversampled from 1 m), z ≤ 17 from Terrarium.

**Commit policy**
- Nothing since `5d106b9` is committed. Commit in reviewable slices only once `xcodebuild` succeeds, each message
  ending with the repo's co-author trailer. In Claude Code sessions, commit only when the user asks.

## Document map of what exists

| Path | Responsibility | State |
|---|---|---|
| `LidarExplorer/Core/Raster/Shaders/TerrainKernels.metal` | All kernels (legacy + 13 micro compute + composite render) | ✅ verified |
| `LidarExplorer/Core/Raster/MetalTerrainPipelineActor.swift` | Pipelines, surface pool, zero-copy binding, `render(_:raster:window:options:thalweg:overlays:outputScale:)`, `viewshed(…)`, `normalizeNoDataInPlace(_:)` | ✅ verified |
| `LidarExplorer/Core/Raster/MicroTopographyReference.swift` | `MicroTopographyOptions`, `RasterGeometry`, `DestinationWindow`, `ThalwegVertex`, `RayTable`, CPU references, REM palette | ✅ verified |
| `LidarExplorer/Services/Elevation/ElevationTileCoordinator.swift` | TNM discovery, COG tiles, resampling, `FallbackElevationProvider` | ✅ verified (not yet used by the app) |
| `LidarExplorer/Services/Elevation/COGByteReader.swift`, `Services/Decoding/TIFFLZWDecoder.swift` | Ranged reads, in-place LZW + predictor | ✅ verified |
| `LidarExplorer/Domain/ElevationTransect.swift` | Fields, sampling, preview, derivatives, signatures, seam flag/filter | ✅ verified (seam filter default is a defect) |
| `LidarExplorer/MapLayer/TerrainTileOverlay.swift` | Provider routing, micro render path, memory budget, stale-tile refresh, transect/viewshed provider APIs, renderer + `TileImageStore` | ✅ B2–B9 fixed; viewshed still 3×3 stitch (C4) |
| `LidarExplorer/MapLayer/AnalysisRasterBuilder.swift` | Neighbour stitching + native-resolution decimation into zero-copy storage | ✅ verified |
| `LidarExplorer/MapLayer/ViewshedOverlay.swift` | Viewshed mask overlay + renderer | ✅ compiles; Simulator walk-through in E2 |
| `LidarExplorer/Presentation/TerrainViewerModel.swift` | Interaction modes, drag pipeline, viewshed state + overlay snapshot, micro options | ⚠️ partial (C1, C3, C5) |
| `LidarExplorer/MapLayer/TerrainMapView.swift` | Transect pan recognizer, observer pin (tracked while dragging), radius circle, viewshed mask | ⚠️ partial (C3, C5) |
| `LidarExplorer/Presentation/ElevationProfileView.swift` | Profile chart, signature pills, scrub ruler | ✅ compiles; resizable panel + min-max decimation in C3 |
| `LidarExplorer/Presentation/ViewerSettingsSheetView.swift`, `ViewerTopBarView.swift`, `ViewerBottomDockView.swift` | Micro sliders, viewshed toggle, dock labels | ⚠️ partial |
| `Tools/ViewerHarness/{MicroTopography,Coordinator,Transect,InteractiveAnalysis,ProviderMicro}Checks.swift` | Offline checks | ✅ 464 PASS |

---

## Part A — Completed (verified 2026-09-12)

- [x] **A1. Kernels + CPU reference.** 13 compute kernels + composite render pass; GPU matches CPU (LRM < 2 mm, openness < 0.02°, SVF < 1e-4, raking < 1e-4, REM < 1 mm, habitation JFA exact on mesa and ≤ 0.1% on anisotropic scenes, viewshed ≤ 0.1%).
- [x] **A2. `MetalTerrainPipelineActor`.** Zero-copy binding proven (GPU nodata rewrote CPU-visible COG memory), Simulator blit path bit-identical, pool leases recycle, budget: LRM 1.4–3.3 ms, RRIM 3.3–4.4 ms over 1024².
- [x] **A3. Viewshed kernels.** 720-ray sweep + per-cell lookup; wall occlusion; 5 km over 2048² in 2.3 ms; fast-math `atan2` signed-zero bug fixed.
- [x] **A4. COG decode path.** LZW decodes into page-aligned storage byte-identical to the array path; predictor in place.
- [x] **A5. `ElevationTileCoordinator`.** TNM ranking, block-interpolated UTM resampling (< 1 mm), GPU nodata at ingest, LRU caps + negative cache (Antigravity), live: cold 0.74–1.95 s, warm < 100 ms, zero-copy tile bind.
- [x] **A6. Transect engine.** 0.5 m sampling, slope/curvature, platform-mound and ditch-and-berm detection; 5 km / 10,001 samples analysed in 0.3 ms; `previewProfile` (Antigravity).
- [x] **A7. Style/contour plumbing.** Four new `ReliefStyle` cases with `microTopographyProduct`; fine contour intervals (0.25–5 m) with `indexIntervalMeters`; dock labels; harness loops exclude micro styles.
- [x] **A8. Partial integration (Antigravity).** Provider routes LRM/SVF/raking/REM through a 3×3 stitch; interaction-mode state machine; drag preview + debounced analysis; observer pin + radius circle; settings sliders. Defects listed in Part B.

---

## Part B — Defects found during calibration (do these first)

> **Done 2026-09-12.** Harness 464 PASS / 0 FAIL, live check 67 / 0, `xcodebuild` BUILD SUCCEEDED. Commit steps are
> still open (nothing committed). Where the code differs from the text below:
> - **B3 step 6** — the observer pin is tracked with a 30 Hz `Timer` started on drag `.starting/.dragging` (reading
>   `viewshedAnnotation.coordinate` inside `MainActor.assumeIsolated`) instead of KVO, which avoids non-Sendable
>   captures; `setViewshedObserver` still runs on drag end.
> - **B5 step 1** — `path(forKey:)` is checked with `.map { $0.x == 1 && $0.y == 2 && $0.z == 19 } ?? false`
>   (an optional tuple is not `Equatable`).
> - **B6 step 4** — neighbours are gathered into `var collected` and copied to `let neighbours` before
>   `Task.detached` (Swift 6 rejects capturing a `var` in a `@Sendable` closure).

### Task B0: Shared provider test scene

Several Part B checks need a real `TerrainTileProvider` with continuous synthetic terrain across tiles.

**Files:**
- Create: `Tools/ViewerHarness/ProviderMicroChecks.swift`
- Modify: `Tools/run-harness.sh` (add the file before `Tools/ViewerHarness/main.swift`)
- Modify: `Tools/ViewerHarness/main.swift` (call `await runProviderMicroChecks()` after `await runInteractiveAnalysisChecks()`)

- [x] **Step 1: Create the helper file**

```swift
//
//  ProviderMicroChecks.swift
//  ViewerHarness
//
//  Provider-level checks for the micro-topography integration, on synthetic
//  terrain that is continuous across tile edges.
//

import CoreGraphics
import CoreLocation
import Foundation
import MapKit
import simd

/// Flat ground at 120 m with an optional platform mound: 20 m flat top, 2.8 m
/// high, 25 degree flanks. Elevation is a function of Web Mercator position, so
/// neighbouring tiles agree exactly where they meet.
nonisolated struct SyntheticTerrainStub: ElevationProviding {
    let moundCenterMercator: SIMD2<Double>?
    let groundMetersPerMercatorMeter: Double

    func elevation(for region: GeoRegion, targetSamples count: Int) async -> Evidence<ElevationGrid> {
        let m = region.mercatorBounds
        var samples = [Float](repeating: 120, count: count * count)
        if let c = moundCenterMercator {
            let run = 2.8 / tan(25 * Double.pi / 180)
            for y in 0..<count {
                let my = m.maxY - (Double(y) + 0.5) * (m.maxY - m.minY) / Double(count)
                for x in 0..<count {
                    let mx = m.minX + (Double(x) + 0.5) * (m.maxX - m.minX) / Double(count)
                    let gx: Double = (mx - c.x) * groundMetersPerMercatorMeter
                    let gy: Double = (my - c.y) * groundMetersPerMercatorMeter
                    let r: Double = (gx * gx + gy * gy).squareRoot()
                    if r <= 10 {
                        samples[y * count + x] += 2.8
                    } else if r <= 10 + run {
                        samples[y * count + x] += Float(2.8 - (r - 10) / run * 2.8)
                    }
                }
            }
        }
        return .observed(ElevationGrid(width: count, height: count, samples: samples, region: region),
                         Provenance(source: .usgs3DEP))
    }
}

struct SyntheticTileScene {
    let provider: TerrainTileProvider
    let x: Int
    let y: Int
    let z: Int
    let directory: URL

    func region(dx: Int = 0, dy: Int = 0) -> GeoRegion {
        TerrainTileOverlay.region(for: MKTileOverlayPath(x: x + dx, y: y + dy, z: z, contentScaleFactor: 2))
    }

    /// Mercator x of the centre tile's east edge.
    var seamX: Double { region().mercatorBounds.maxX }
    /// Mercator y of the centre tile's middle row.
    var centerY: Double { (region().mercatorBounds.minY + region().mercatorBounds.maxY) / 2 }

    @discardableResult
    func image(dx: Int = 0, dy: Int = 0) async -> CGImage? {
        await provider.tileImage(x: x + dx, y: y + dy, z: z, region: region(dx: dx, dy: dy), pixels: 512)
    }

    func loadNeighbourhood(rings: Int = 1) async {
        for dy in -rings...rings {
            for dx in -rings...rings { await image(dx: dx, dy: dy) }
        }
    }
}

/// A z19 tile scene over Cahokia; `moundOffsetFromSeamMeters` places the mound
/// centre that many ground metres east of the centre tile's east edge.
@MainActor
func makeSyntheticScene(moundOffsetFromSeamMeters: Double?) -> SyntheticTileScene {
    let latitude = 38.6605, longitude = -90.0621, z = 19
    let n = pow(2.0, Double(z))
    let x = Int((longitude + 180) / 360 * n)
    let y = Int((1 - asinh(tan(latitude * .pi / 180)) / .pi) / 2 * n)
    let region = TerrainTileOverlay.region(for: MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: 2))
    let k = cos(latitude * .pi / 180)
    let center = moundOffsetFromSeamMeters.map {
        SIMD2(region.mercatorBounds.maxX + $0 / k, (region.mercatorBounds.minY + region.mercatorBounds.maxY) / 2)
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("provider-micro-\(UUID().uuidString)")
    let provider = TerrainTileProvider(
        elevation: SyntheticTerrainStub(moundCenterMercator: center, groundMetersPerMercatorMeter: k),
        gridCache: TileDiskCache(directory: directory)
    )
    return SyntheticTileScene(provider: provider, x: x, y: y, z: z, directory: directory)
}

@MainActor
func runProviderMicroChecks() async {
    print("\n=== Provider micro-topography integration ===")
}
```

- [x] **Step 2: Wire it** — add `  Tools/ViewerHarness/ProviderMicroChecks.swift \` to `Tools/run-harness.sh` and `await runProviderMicroChecks()` to `main.swift` after `await runInteractiveAnalysisChecks()`.
- [x] **Step 3: Run** `./Tools/run-harness.sh /tmp/lidar-renders` → Expected: `ALL CHECKS PASSED` and a `=== Provider micro-topography integration ===` header.

### Task B1: Make the app compile

**Files:** Modify `LidarExplorer/Presentation/ElevationProfileView.swift:143`

- [x] **Step 1: Reproduce** — run the `xcodebuild` command from Background. Expected: `ElevationProfileView.swift:143:89: error: value of optional type 'Float?' must be unwrapped`.
- [x] **Step 2: Fix** — replace
```swift
Text(String(format: "Mound: %.0fm top · %.1fm relief", sig.plateauWidthMeters, sig.reliefMeters))
```
with
```swift
Text(String(format: "Mound: %.0f m top · %.1f m relief", sig.plateauWidthMeters ?? 0, sig.reliefMeters))
```
- [x] **Step 3: Verify** — `xcodebuild …` → Expected: `** BUILD SUCCEEDED **`. If further errors surface, fix them here and list them in `STATUS.md`.
- [x] **Step 4: Run the harness** → Expected: `ALL CHECKS PASSED`.
- [x] **Step 5: Update `STATUS.md`** (build row → ✅) and commit when allowed:
```bash
git add LidarExplorer/Presentation/ElevationProfileView.swift STATUS.md
git commit -m "fix(profile): unwrap plateau width before formatting"
```

### Task B2: REM tiles render (flat water-plane fallback + thalweg plumbing)

`MetalTerrainPipelineActor.render` declines `.relativeElevation` without a thalweg, and the provider never passes one.

**Files:**
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift` (`TerrainStyleSettings`; `microPipelineImage`; new static `thalwegVertices`)
- Test: `Tools/ViewerHarness/ProviderMicroChecks.swift`

- [x] **Step 1: Write the failing checks** (append to `ProviderMicroChecks.swift`, call from `runProviderMicroChecks()`)

```swift
@MainActor
func checkRelativeElevationTiles() async {
    print("\n--- B2. REM tiles ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    await scene.loadNeighbourhood()
    var settings = TerrainStyleSettings()
    settings.style = .relativeElevation
    await scene.provider.update(settings)
    check("a REM tile renders with no drawn thalweg (flat water plane)", await scene.image() != nil)

    let r = scene.region()
    settings.thalweg = [
        ThalwegPoint(latitude: r.maxLatitude, longitude: r.minLongitude, waterSurface: 119.5),
        ThalwegPoint(latitude: r.minLatitude, longitude: r.maxLongitude, waterSurface: 119.0),
    ]
    await scene.provider.update(settings)
    check("a REM tile renders against a drawn thalweg", await scene.image() != nil)

    let m = r.mercatorBounds
    let pixel = (m.maxX - m.minX) / 512
    let firstPixel = GeoRegion.fromMercatorMeters(x: m.minX + 0.5 * pixel, y: m.maxY - 0.5 * pixel)
    let vertices = TerrainTileProvider.thalwegVertices(
        [ThalwegPoint(latitude: firstPixel.latitude, longitude: firstPixel.longitude, waterSurface: 5)],
        fallbackSurface: 0, tileBounds: m, destinationPixels: 512, skirt: 16, cellSizeX: 0.1, cellSizeY: 0.1)
    check("a thalweg point on the tile's first pixel centre lands on the skirt origin",
          vertices.count == 1 && abs(vertices[0].x - 1.6) < 1e-3 && abs(vertices[0].y - 1.6) < 1e-3, "\(vertices)")
    check("no thalweg means one flat-plane vertex",
          TerrainTileProvider.thalwegVertices([], fallbackSurface: 42, tileBounds: m, destinationPixels: 512,
                                              skirt: 16, cellSizeX: 0.1, cellSizeY: 0.1).map(\.waterSurface) == [42])
    try? FileManager.default.removeItem(at: scene.directory)
}
```

- [x] **Step 2: Run the harness** → Expected: compile error `cannot find 'ThalwegPoint' in scope`.
- [x] **Step 3: Implement** — in `TerrainTileOverlay.swift`, above `TerrainStyleSettings`:

```swift
/// A thalweg vertex with the water-surface elevation sampled beneath it.
public nonisolated struct ThalwegPoint: Sendable, Equatable, Hashable {
    public var latitude: Double
    public var longitude: Double
    public var waterSurface: Float

    public init(latitude: Double, longitude: Double, waterSurface: Float) {
        self.latitude = latitude
        self.longitude = longitude
        self.waterSurface = waterSurface
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
```

Inside `TerrainStyleSettings` add:

```swift
    /// River centreline for `.relativeElevation`. Empty detrends against a flat
    /// water plane at the visible minimum elevation.
    public var thalweg: [ThalwegPoint] = []
```

In `TerrainTileProvider`, add:

```swift
    /// Thalweg vertices in a stitched analysis raster's frame (x east from column
    /// 0, y south from row 0, metres). With no drawn thalweg, one vertex at
    /// `fallbackSurface` detrends against a flat water plane.
    nonisolated static func thalwegVertices(
        _ points: [ThalwegPoint],
        fallbackSurface: Float,
        tileBounds m: (minX: Double, minY: Double, maxX: Double, maxY: Double),
        destinationPixels: Int,
        skirt: Int,
        cellSizeX: Float,
        cellSizeY: Float
    ) -> [ThalwegVertex] {
        guard !points.isEmpty else {
            return fallbackSurface.isFinite ? [ThalwegVertex(x: 0, y: 0, waterSurface: fallbackSurface)] : []
        }
        let pixelX = (m.maxX - m.minX) / Double(destinationPixels)
        let pixelY = (m.maxY - m.minY) / Double(destinationPixels)
        return points.map { point in
            let p = GeoRegion.toMercatorMeters(point.coordinate)
            let column = (p.x - m.minX) / pixelX + Double(skirt) - 0.5
            let row = (m.maxY - p.y) / pixelY + Double(skirt) - 0.5
            return ThalwegVertex(x: Float(column) * cellSizeX, y: Float(row) * cellSizeY, waterSurface: point.waterSurface)
        }
    }
```

In `microPipelineImage`, replace the `microPipeline.render(...)` call with:

```swift
        let thalweg = product == .relativeElevation
            ? Self.thalwegVertices(
                settings.thalweg,
                fallbackSurface: settings.elevationRange?.lowerBound ?? tile.elevationLow,
                tileBounds: tile.displayRegion.mercatorBounds,
                destinationPixels: tileW, skirt: desiredSkirt,
                cellSizeX: Float(tile.grid.metersPerColumn), cellSizeY: Float(tile.grid.metersPerRow))
            : []
        guard let result = await microPipeline.render(
            product, raster: raster, window: window, options: options, thalweg: thalweg, overlays: overlays
        ) else { return nil }
```

In `TerrainViewerModel`, make the visible range refresh for REM too: in `style`'s `didSet` use
`if style == .elevation || style == .relativeElevation { refreshElevationRange() }`, and in
`refreshElevationRange()` use `guard style == .elevation || style == .relativeElevation else { return }`.

- [x] **Step 4: Run the harness** → Expected: the four B2 checks PASS, `ALL CHECKS PASSED`.
- [x] **Step 5: Commit** — `fix(rem): detrend against a flat water plane until a thalweg is drawn`.

### Task B3: Draw the viewshed mask and follow the pin while dragging

**Files:**
- Create: `LidarExplorer/MapLayer/ViewshedOverlay.swift`
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift` (`viewshed(at:…)` returns a region)
- Modify: `LidarExplorer/Presentation/TerrainViewerModel.swift` (overlay snapshot, version, drag debounce)
- Modify: `LidarExplorer/MapLayer/TerrainMapView.swift` (input, overlay sync, KVO, renderer)
- Modify: `LidarExplorer/Presentation/TerrainViewerView.swift` (pass `viewshedVersion`)
- Test: `Tools/ViewerHarness/ProviderMicroChecks.swift`

- [x] **Step 1: Write the failing check**

```swift
@MainActor
func checkViewshedSnapshot() async {
    print("\n--- B3. viewshed snapshot ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -40)
    await scene.loadNeighbourhood()
    let observer = scene.region().center
    guard let snapshot = await scene.provider.viewshed(at: observer, maxRadiusMeters: 80) else {
        check("provider viewshed renders", false, "nil")
        return
    }
    check("the snapshot region contains the observer", snapshot.region.contains(observer))
    check("the snapshot region matches the mask's pixel grid",
          snapshot.result.mask.width == snapshot.result.display.width && snapshot.result.mask.width > 512)
    check("the observer's own cell is visible", snapshot.result.mask.values().contains(1))
    try? FileManager.default.removeItem(at: scene.directory)
}
```

- [x] **Step 2: Run the harness** → Expected: compile error `value of type 'ViewshedResult' has no member 'region'`.
- [x] **Step 3: Provider returns the stitched raster's region**

```swift
/// A viewshed with the geographic extent of the raster it was computed over.
public nonisolated struct ProviderViewshed: Sendable {
    public let result: ViewshedResult
    public let region: GeoRegion
}
```

Change `viewshed(at:eyeHeight:targetHeight:maxRadiusMeters:)` to return `ProviderViewshed?`, and replace its final
`return await microPipeline.viewshed(...)` with:

```swift
        guard let result = await microPipeline.viewshed(
            raster: elevRaster, observerColumn: observerCol, observerRow: observerRow,
            eyeHeight: eyeHeight, targetHeight: targetHeight, maxRadiusMeters: maxRadiusMeters
        ) else { return nil }
        let m = disp.mercatorBounds
        let padX = (m.maxX - m.minX) / innerW * Double(skirt)
        let padY = (m.maxY - m.minY) / innerH * Double(skirt)
        let sw = GeoRegion.fromMercatorMeters(x: m.minX - padX, y: m.minY - padY)
        let ne = GeoRegion.fromMercatorMeters(x: m.maxX + padX, y: m.maxY + padY)
        return ProviderViewshed(
            result: result,
            region: GeoRegion(minLatitude: sw.latitude, maxLatitude: ne.latitude,
                              minLongitude: sw.longitude, maxLongitude: ne.longitude)
        )
```

- [x] **Step 4: Overlay + renderer** — create `LidarExplorer/MapLayer/ViewshedOverlay.swift`:

```swift
//
//  ViewshedOverlay.swift
//  LidarExplorer
//
//  The visible-ground mask drawn over the map.
//

import CoreGraphics
import MapKit

public nonisolated final class ViewshedOverlay: NSObject, MKOverlay, @unchecked Sendable {
    public let image: CGImage
    public let boundingMapRect: MKMapRect

    public var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
    }

    public init(image: CGImage, region: GeoRegion) {
        self.image = image
        let northWest = MKMapPoint(CLLocationCoordinate2D(latitude: region.maxLatitude, longitude: region.minLongitude))
        let southEast = MKMapPoint(CLLocationCoordinate2D(latitude: region.minLatitude, longitude: region.maxLongitude))
        self.boundingMapRect = MKMapRect(x: northWest.x, y: northWest.y,
                                         width: southEast.x - northWest.x, height: southEast.y - northWest.y)
    }
}

public nonisolated final class ViewshedOverlayRenderer: MKOverlayRenderer {
    public override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let viewshed = overlay as? ViewshedOverlay else { return }
        let rect = self.rect(for: viewshed.boundingMapRect)
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(viewshed.image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}
```

- [x] **Step 5: Model** — in `TerrainViewerModel` add, beside the viewshed state:

```swift
    /// The drawn mask and where it goes; replaced wholesale on every result.
    public struct ViewshedOverlayImage {
        public let image: CGImage
        public let region: GeoRegion
    }
    public private(set) var viewshedOverlay: ViewshedOverlayImage?
    /// Bumped per result so the map view knows to swap its overlay.
    public private(set) var viewshedVersion = 0

    /// Called continuously while the observer pin is dragged; coalesces to one
    /// computation per 60 ms of stillness.
    public func moveViewshedObserver(_ coordinate: CLLocationCoordinate2D) {
        if let current = viewshedObserverCoordinate,
           current.latitude == coordinate.latitude, current.longitude == coordinate.longitude { return }
        viewshedObserverCoordinate = coordinate
        viewshedTask?.cancel()
        viewshedTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            self?.computeViewshed()
        }
    }
```

In `computeViewshed()`, replace `self.viewshedResult = result` with:

```swift
            self.viewshedResult = result?.result
            self.viewshedOverlay = result.flatMap { snapshot in
                snapshot.result.display.makeImage().map { ViewshedOverlayImage(image: $0, region: snapshot.region) }
            }
            self.viewshedVersion &+= 1
```

and in `clearViewshed()` add `viewshedOverlay = nil` and `viewshedVersion &+= 1`. Add `import CoreGraphics` if needed.

- [x] **Step 6: Map view** — in `TerrainMapView` add a stored input `let viewshedVersion: Int` (init parameter with default `0`, passed from `TerrainViewerView` as `viewshedVersion: model.viewshedVersion`). In `Coordinator` add:

```swift
        private var viewshedOverlay: ViewshedOverlay?
        private var drawnViewshedVersion = -1
        private var observerObservation: NSKeyValueObservation?
```

In `syncViewshed(on:)`: in the `needsClear` branch also remove `viewshedOverlay`, set it to `nil`, set
`drawnViewshedVersion = -1`, and set `observerObservation = nil`. Where the annotation is created, add:

```swift
                observerObservation = ann.observe(\.coordinate, options: [.new]) { [weak self] annotation, _ in
                    let coordinate = annotation.coordinate
                    Task { @MainActor in self?.model.moveViewshedObserver(coordinate) }
                }
```

Replace `ann.coordinate = obs` on the existing annotation with
`if ann.coordinate.latitude != obs.latitude || ann.coordinate.longitude != obs.longitude { ann.coordinate = obs }`
(prevents a KVO → recompute → sync loop). At the end of `syncViewshed(on:)`:

```swift
            if model.viewshedVersion != drawnViewshedVersion {
                drawnViewshedVersion = model.viewshedVersion
                if let old = viewshedOverlay {
                    map.removeOverlay(old)
                    viewshedOverlay = nil
                }
                if let snapshot = model.viewshedOverlay {
                    let overlay = ViewshedOverlay(image: snapshot.image, region: snapshot.region)
                    map.addOverlay(overlay, level: .aboveLabels)
                    viewshedOverlay = overlay
                }
            }
```

At the top of `mapView(_:rendererFor:)`:

```swift
            if let viewshed = overlay as? ViewshedOverlay {
                let renderer = ViewshedOverlayRenderer(overlay: viewshed)
                renderer.alpha = 0.85
                return renderer
            }
```

- [x] **Step 7: Verify** — harness → B3 checks PASS; `xcodebuild` → `BUILD SUCCEEDED`; Simulator: viewshed mode, tap, drag the eye pin → green mask follows within ~100 ms.
- [x] **Step 8: Commit** — `feat(viewshed): draw the visibility mask and follow the dragged observer`.

### Task B4: Flag only resolution seams, so real earthworks on tile edges survive

The current filter flags every tile boundary. Same-zoom boundaries are continuous (padded skirts); only a step in
resolution between neighbouring layers can manufacture a slope break.

**Files:**
- Modify: `LidarExplorer/Domain/ElevationTransect.swift` (`TileMosaicField`, `sampleProfile`)
- Test: `Tools/ViewerHarness/ProviderMicroChecks.swift`

- [x] **Step 1: Write the failing checks**

```swift
@MainActor
func checkSeamSemantics() async {
    print("\n--- B4. seam semantics ---")
    func signatures(moundOffset: Double?) async -> [TransectSignature] {
        let scene = makeSyntheticScene(moundOffsetFromSeamMeters: moundOffset)
        await scene.image()
        await scene.image(dx: 1)
        let k = cos(38.6605 * Double.pi / 180)
        let start = GeoRegion.fromMercatorMeters(x: scene.seamX - 45 / k, y: scene.centerY)
        let end = GeoRegion.fromMercatorMeters(x: scene.seamX + 45 / k, y: scene.centerY)
        let analysis = await scene.provider.analyzeTransect(from: start, to: end)
        try? FileManager.default.removeItem(at: scene.directory)
        return analysis?.signatures ?? []
    }
    check("flat ground across a same-zoom seam raises no signature", await signatures(moundOffset: nil).isEmpty)
    check("a platform whose edge sits on a same-zoom seam is still detected",
          await signatures(moundOffset: -10).filter { $0.kind == .platformMound }.count == 1)

    let lat = 38.6553, span = 0.0005
    func grid(_ minLon: Double, _ maxLon: Double, gsd: Double) -> ElevationGrid {
        let region = GeoRegion(minLatitude: lat, maxLatitude: lat + span, minLongitude: minLon, maxLongitude: maxLon)
        let w = Int((region.widthMeters / gsd).rounded()) + 1, h = Int((region.heightMeters / gsd).rounded()) + 1
        return ElevationGrid(width: w, height: h, samples: [Float](repeating: 100, count: w * h), region: region)
    }
    let west = grid(-90.0630, -90.0621, gsd: 0.5)
    let origin = CLLocationCoordinate2D(latitude: lat + span / 2, longitude: -90.0621)
    let mixed = TileMosaicField(origin: origin, layers: [
        .init(grid: west, bounds: west.region), .init(grid: grid(-90.0621, -90.0612, gsd: 2.0), bounds: grid(-90.0621, -90.0612, gsd: 2.0).region),
    ])
    let uniform = TileMosaicField(origin: origin, layers: [
        .init(grid: west, bounds: west.region), .init(grid: grid(-90.0621, -90.0612, gsd: 0.5), bounds: grid(-90.0621, -90.0612, gsd: 0.5).region),
    ])
    check("a 0.5 m / 2 m boundary is a resolution seam", mixed.isResolutionSeam(point: SIMD2(0, 0)))
    check("a 0.5 m / 0.5 m boundary is not", !uniform.isResolutionSeam(point: SIMD2(0, 0)))
}
```

- [x] **Step 2: Run the harness** → Expected: compile error `value of type 'TileMosaicField' has no member 'isResolutionSeam'`.
- [x] **Step 3: Implement** — in `TileMosaicField` add:

```swift
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
```

In `ElevationTransectEngine.sampleProfile`, replace the `isSeam` line with:

```swift
            let isSeam = parameters.filterSeamArtifacts
                && ((field as? TileMosaicField)?.isResolutionSeam(point: position, marginMeters: parameters.seamArtifactMarginMeters) ?? false)
```

Update the doc comment on `filterSeamArtifacts` to "Rejects signatures whose breaks fall within the margin of a resolution seam."

- [x] **Step 4: Run the harness** → Expected: B4 checks PASS; the existing `seam detection identifies boundary proximity` check (geometric `isNearBoundary`) still PASSES.
- [x] **Step 5: Commit** — `fix(transect): suppress only resolution seams, keep earthworks on tile edges`.

### Task B5: Redraw tiles whose neighbours arrive after they were shaded

The provider clears its own bitmap for neighbours, but `TerrainTileOverlayRenderer` keeps drawing its stored image.

**Files:**
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift` (provider `store`, `update`, new `takeStaleTiles`; renderer `Store` → file-scope `TileImageStore`; renderer `request`, new `path(forKey:)`)
- Test: `Tools/ViewerHarness/ProviderMicroChecks.swift`

- [x] **Step 1: Write the failing checks**

```swift
func onePixelImage() -> CGImage {
    let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
}

@MainActor
func checkStaleNeighbourRefresh() async {
    print("\n--- B5. stale neighbour refresh ---")
    let store = TileImageStore()
    let path = MKTileOverlayPath(x: 1, y: 2, z: 19, contentScaleFactor: 2)
    let key = TerrainTileOverlayRenderer.key(path)
    let generation = store.beginLoad(key) ?? -1
    _ = store.finishLoad(key, image: onePixelImage(), generation: generation)
    check("a drawn tile is not re-requested", store.beginLoad(key) == nil)
    check("marking stale reports only drawn tiles", store.markStale([key, "19/9/9"]) == [key])
    check("a stale tile keeps drawing its old image", store.image(for: key) != nil)
    check("a stale tile is requested again", store.partition([path], key: TerrainTileOverlayRenderer.key).missing.count == 1)
    let refresh = store.beginLoad(key)
    check("a stale tile may begin a reload", refresh != nil)
    _ = store.finishLoad(key, image: onePixelImage(), generation: refresh ?? -1)
    check("a finished reload clears staleness", store.beginLoad(key) == nil)
    check("paths round-trip through keys", TerrainTileOverlayRenderer.path(forKey: key).map { ($0.x, $0.y, $0.z) } == (1, 2, 19))

    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: 0)
    var settings = TerrainStyleSettings()
    settings.style = .localRelief
    await scene.provider.update(settings)
    await scene.image()
    _ = await scene.provider.takeStaleTiles()
    await scene.image(dx: 1)
    let stale = await scene.provider.takeStaleTiles()
    check("a neighbour's arrival marks the shaded tile stale", stale.contains("\(scene.z)/\(scene.x)/\(scene.y)"), "\(stale)")
    check("stale tiles drain once", await scene.provider.takeStaleTiles().isEmpty)
    try? FileManager.default.removeItem(at: scene.directory)
}
```

- [x] **Step 2: Run the harness** → Expected: compile error `cannot find 'TileImageStore' in scope`.
- [x] **Step 3: Provider** — add `private var staleTiles: Set<String> = []` and:

```swift
    /// Tiles whose shading read a neighbour that has since arrived; the renderer
    /// redraws these in the background, keeping the old image until then.
    public func takeStaleTiles() -> [String] {
        defer { staleTiles.removeAll() }
        return Array(staleTiles)
    }
```

In `update(_:)`, after `releaseAllBitmaps()`, add `staleTiles.removeAll()`. In `store(_:for:)`, replace the
"Invalidate pre-rendered neighbor bitmaps" loop with:

```swift
        // Only neighbourhood styles read across tile edges.
        guard settings.style.microTopographyProduct != nil else { return }
        let parts = key.split(separator: "/")
        guard parts.count == 3, let z = Int(parts[0]), let x = Int(parts[1]), let y = Int(parts[2]) else { return }
        for dx in -1...1 {
            for dy in -1...1 where !(dx == 0 && dy == 0) {
                let neighbourKey = "\(z)/\(x + dx)/\(y + dy)"
                guard cache[neighbourKey] != nil else { continue }
                cache[neighbourKey]?.rendered = nil
                renderedOrder.removeAll { $0 == neighbourKey }
                staleTiles.insert(neighbourKey)
            }
        }
```

- [x] **Step 4: Renderer store** — move the private nested `Store` class out of `TerrainTileOverlayRenderer` to file
scope as `nonisolated final class TileImageStore: @unchecked Sendable`, keep its existing members, and change:

```swift
    private var stale: Set<String> = []

    func partition(
        _ paths: [MKTileOverlayPath], key: (MKTileOverlayPath) -> String
    ) -> (ready: Bool, missing: [MKTileOverlayPath]) {
        lock.lock()
        defer { lock.unlock() }
        var ready = false
        var missing: [MKTileOverlayPath] = []
        for path in paths {
            let k = key(path)
            if images[k] != nil { ready = true }
            if images[k] == nil || stale.contains(k) { missing.append(path) }
        }
        return (ready, missing)
    }

    func beginLoad(_ key: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard images[key] == nil || stale.contains(key), !inFlight.contains(key) else { return nil }
        inFlight.insert(key)
        return generation
    }

    func finishLoad(_ key: String, image: CGImage?, generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        inFlight.remove(key)
        guard let image, generation == self.generation else { return false }
        images[key] = image
        stale.remove(key)
        return true
    }

    /// Marks drawn tiles for a background redraw; returns the keys that were drawn.
    func markStale(_ keys: [String]) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let drawn = keys.filter { images[$0] != nil }
        stale.formUnion(drawn)
        return drawn
    }
```

and in `invalidate()` add `stale.removeAll()`. In the renderer: `private let store = TileImageStore()`, make
`key(_:)` internal (`nonisolated static func key`), and add:

```swift
    nonisolated static func path(forKey key: String) -> MKTileOverlayPath? {
        let parts = key.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return MKTileOverlayPath(x: parts[1], y: parts[2], z: parts[0], contentScaleFactor: 1)
    }
```

In `request(_:zoomScale:)`, after the existing `setNeedsDisplay` inside the task:

```swift
            let stale = await provider.takeStaleTiles()
            for staleKey in store.markStale(stale) {
                if let stalePath = TerrainTileOverlayRenderer.path(forKey: staleKey) {
                    handle.renderer?.setNeedsDisplay(TerrainTileOverlay.mapRect(for: stalePath))
                }
            }
```

- [x] **Step 5: Run the harness** → Expected: B5 checks PASS, `ALL CHECKS PASSED`; `xcodebuild` → `BUILD SUCCEEDED`.
- [x] **Step 6: Commit** — `fix(tiles): redraw micro-style tiles when a neighbour arrives, without flashing`.

### Task B6: Per-product skirt, native-resolution decimation, off-actor zero-copy stitching

Today every micro style stitches a ≥ 25–30 m skirt (the largest radius of all products) per pixel on the provider
actor, at the oversampled tile resolution (0.117 m at z19). Measured: LRM 10–21 ms, SVF 9 ms, raking 4 ms per tile.

**Files:**
- Create: `LidarExplorer/MapLayer/AnalysisRasterBuilder.swift`
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift` (`microPipelineImage`, `thalwegVertices`, two new statics)
- Modify: `Tools/run-harness.sh`, `Tools/run-live-check.sh` (add the new file after `TerrainTileOverlay.swift`'s dependencies, e.g. before `LidarExplorer/MapLayer/HillshadeTileOverlay.swift`)
- Test: `Tools/ViewerHarness/ProviderMicroChecks.swift`

- [x] **Step 1: Write the failing checks**

```swift
@MainActor
func checkAnalysisRasterBuilder() async {
    print("\n--- B6. analysis raster builder ---")
    let dest = 8, margin = 2, padded = dest + 2 * margin
    /// Global value encodes tile offset and local destination pixel, so a wrong source shows up as a wrong number.
    func tile(_ tx: Int, _ ty: Int) -> AnalysisTileSource {
        var s = [Float](repeating: 0, count: padded * padded)
        for py in 0..<padded { for px in 0..<padded {
            let gx = tx * dest + px - margin, gy = ty * dest + py - margin
            s[py * padded + px] = Float(gy * 1000 + gx)
        } }
        return AnalysisTileSource(samples: s, paddedWidth: padded, margin: margin)
    }
    var all: [SIMD2<Int32>: AnalysisTileSource] = [:]
    for dy in -1...1 { for dx in -1...1 where !(dx == 0 && dy == 0) { all[SIMD2(Int32(dx), Int32(dy))] = tile(dx, dy) } }

    if let full = AnalysisRasterBuilder.build(center: tile(0, 0), skirt: 4, decimation: 1, cellSizeX: 1, cellSizeY: 1, neighbours: all) {
        let values = full.storage.pointer.assumingMemoryBound(to: Float.self)
        var wrong = 0
        for oy in 0..<16 { for ox in 0..<16 where values[oy * 16 + ox] != Float((oy - 4) * 1000 + (ox - 4)) { wrong += 1 } }
        check("stitching reads every skirt pixel from the right neighbour", wrong == 0, "\(wrong) wrong")
        check("the destination window sits at the skirt", full.window == DestinationWindow(originX: 4, originY: 4, width: 8, height: 8))
        check("a full neighbourhood reports nothing missing", full.missingNeighbours.isEmpty)
    }
    if let half = AnalysisRasterBuilder.build(center: tile(0, 0), skirt: 4, decimation: 2, cellSizeX: 1, cellSizeY: 1, neighbours: all) {
        let v = half.storage.pointer.assumingMemoryBound(to: Float.self)
        let expected: Float = (Float(-4 * 1000 - 4) + Float(-4 * 1000 - 3) + Float(-3 * 1000 - 4) + Float(-3 * 1000 - 3)) / 4
        check("decimation box-averages source pixels", half.geometry.width == 8 && abs(v[0] - expected) < 1e-3, "\(v[0])")
        check("decimated cells are proportionally larger", half.geometry.cellSizeX == 2 && half.window.width == 4)
    }
    var withoutEast = all
    withoutEast[SIMD2(1, 0)] = nil
    if let gap = AnalysisRasterBuilder.build(center: tile(0, 0), skirt: 4, decimation: 1, cellSizeX: 1, cellSizeY: 1, neighbours: withoutEast) {
        let v = gap.storage.pointer.assumingMemoryBound(to: Float.self)
        check("a missing neighbour is reported", gap.missingNeighbours.contains(SIMD2(1, 0)))
        check("the centre's own skirt still answers next to a missing neighbour", v[4 * 16 + 4 + dest] == Float(0 * 1000 + dest))
        check("beyond the centre's skirt a missing neighbour is a void, not replicated terrain", v[4 * 16 + 4 + dest + margin].isNaN)
    }
    check("z19 oversampled 3DEP decimates 8x to reach 1 m", AnalysisRasterBuilder.decimation(tileGroundSampleDistance: 0.1165, nativeGroundSampleDistance: 1, destinationPixels: 512) == 8)
    check("native tiles are not decimated", AnalysisRasterBuilder.decimation(tileGroundSampleDistance: 1.2, nativeGroundSampleDistance: 1.2, destinationPixels: 256) == 1)
    let skirt = AnalysisRasterBuilder.skirtPixels(radiusMeters: 25, groundSampleDistance: 0.1165, decimation: 8, destinationPixels: 512)
    check("the skirt covers the radius and keeps the decimated width a multiple of 4",
          Double(skirt) * 0.1165 >= 25 && ((512 + 2 * skirt) / 8) % 4 == 0, "\(skirt)")

    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    await scene.loadNeighbourhood()
    var settings = TerrainStyleSettings()
    settings.style = .localRelief
    await scene.provider.update(settings)
    let cold = await scene.image()
    settings.azimuthDegrees += 1
    await scene.provider.update(settings)
    let started = Date()
    _ = await scene.image()
    let warmMs = Date().timeIntervalSince(started) * 1000
    check("an LRM tile at z19 is analysed at native 1 m (64 px)", cold?.width == 64, "\(cold?.width ?? -1)")
    check("an LRM tile renders in under 8 ms warm", warmMs < 8, String(format: "%.1f ms", warmMs))
    settings.contourInterval = .halfMeter
    await scene.provider.update(settings)
    check("with contours the composite returns to display resolution", await scene.image()?.width == 512)
    try? FileManager.default.removeItem(at: scene.directory)
}
```

- [x] **Step 2: Run the harness** → Expected: compile error `cannot find 'AnalysisTileSource' in scope`.
- [x] **Step 3: Create `LidarExplorer/MapLayer/AnalysisRasterBuilder.swift`**

```swift
//
//  AnalysisRasterBuilder.swift
//  LidarExplorer
//
//  Stitches a map tile and its cached neighbours into one analysis raster.
//

import Foundation
import simd

/// One cached tile's padded raster.
public nonisolated struct AnalysisTileSource: Sendable {
    public let samples: [Float]
    public let paddedWidth: Int
    public let margin: Int

    public init(samples: [Float], paddedWidth: Int, margin: Int) {
        self.samples = samples
        self.paddedWidth = paddedWidth
        self.margin = margin
    }

    var destinationWidth: Int { paddedWidth - 2 * margin }
    var isSquare: Bool { samples.count == paddedWidth * paddedWidth }
}

/// A stitched, decimated raster in page-aligned storage the GPU adopts without a copy.
public nonisolated struct AnalysisRaster: Sendable {
    public let storage: COGMappedStorage
    public let geometry: RasterGeometry
    public let window: DestinationWindow
    public let decimation: Int
    /// Skirt width in tile pixels.
    public let skirt: Int
    /// Neighbour offsets the skirt needed but the cache lacked.
    public let missingNeighbours: [SIMD2<Int32>]

    public var raster: ElevationRaster {
        ElevationRaster(
            samples: .mapped(base: storage.pointer, mappedLength: storage.length, sampleOffset: 0, owner: storage),
            geometry: geometry
        )
    }
}

public nonisolated enum AnalysisRasterBuilder {

    /// The largest power-of-two box that keeps analysis cells no finer than the
    /// source's native spacing, while the decimated tile stays a multiple of 4
    /// pixels wide (linear-texture alignment).
    public static func decimation(
        tileGroundSampleDistance mpp: Double, nativeGroundSampleDistance native: Double, destinationPixels dest: Int
    ) -> Int {
        var factor = 1
        while Double(factor * 2) * mpp <= native * 1.05, dest % (factor * 8) == 0 { factor *= 2 }
        return factor
    }

    /// Tile pixels of skirt covering `radiusMeters` plus a Horn window, rounded up
    /// to a multiple of `2 * decimation` and capped at one tile.
    public static func skirtPixels(
        radiusMeters: Float, groundSampleDistance mpp: Double, decimation f: Int, destinationPixels dest: Int
    ) -> Int {
        let unit = 2 * f
        let needed = Int((Double(radiusMeters) / mpp).rounded(.up)) + unit
        return min((needed + unit - 1) / unit * unit, dest / unit * unit)
    }

    /// The centre tile plus up to eight neighbours, box-decimated by `decimation`.
    ///
    /// Where a neighbour is missing, the centre tile's own padded skirt still
    /// answers its first `margin` pixels; beyond that the value is NaN, which every
    /// kernel treats as a void rather than as terrain.
    public static func build(
        center: AnalysisTileSource,
        skirt: Int,
        decimation f: Int,
        cellSizeX: Float,
        cellSizeY: Float,
        neighbours: [SIMD2<Int32>: AnalysisTileSource]
    ) -> AnalysisRaster? {
        let dest = center.destinationWidth
        let full = dest + 2 * skirt
        guard dest > 0, f > 0, skirt >= 0, skirt <= dest, full % f == 0, center.isSquare else { return nil }
        let outWidth = full / f
        guard let storage = COGMappedStorage(length: outWidth * outWidth * 4) else { return nil }
        let out = storage.pointer.bindMemory(to: Float.self, capacity: outWidth * outWidth)

        var tiles = [AnalysisTileSource?](repeating: nil, count: 9)
        tiles[4] = center
        var missing: [SIMD2<Int32>] = []
        if skirt > center.margin {
            for dy in -1...1 {
                for dx in -1...1 where !(dx == 0 && dy == 0) {
                    let offset = SIMD2(Int32(dx), Int32(dy))
                    if let t = neighbours[offset], t.paddedWidth == center.paddedWidth, t.margin == center.margin, t.isSquare {
                        tiles[(dy + 1) * 3 + dx + 1] = t
                    } else {
                        missing.append(offset)
                    }
                }
            }
        }

        func sample(_ gx: Int, _ gy: Int) -> Float {
            let tx = gx < 0 ? -1 : (gx >= dest ? 1 : 0)
            let ty = gy < 0 ? -1 : (gy >= dest ? 1 : 0)
            if let t = tiles[(ty + 1) * 3 + tx + 1] {
                let lx = gx - tx * dest + t.margin, ly = gy - ty * dest + t.margin
                if lx >= 0, ly >= 0, lx < t.paddedWidth, ly < t.paddedWidth { return t.samples[ly * t.paddedWidth + lx] }
            }
            let m = center.margin
            guard gx >= -m, gy >= -m, gx < dest + m, gy < dest + m else { return .nan }
            return center.samples[(gy + m) * center.paddedWidth + gx + m]
        }

        for oy in 0..<outWidth {
            for ox in 0..<outWidth {
                var sum: Float = 0
                var count = 0
                for j in 0..<f {
                    for i in 0..<f {
                        let v = sample(ox * f + i - skirt, oy * f + j - skirt)
                        if !v.isNaN { sum += v; count += 1 }
                    }
                }
                out[oy * outWidth + ox] = count > 0 ? sum / Float(count) : .nan
            }
        }

        return AnalysisRaster(
            storage: storage,
            geometry: RasterGeometry(width: outWidth, height: outWidth,
                                     cellSizeX: cellSizeX * Float(f), cellSizeY: cellSizeY * Float(f)),
            window: DestinationWindow(originX: skirt / f, originY: skirt / f, width: dest / f, height: dest / f),
            decimation: f, skirt: skirt, missingNeighbours: missing
        )
    }
}
```

- [x] **Step 4: Provider** — add to `TerrainTileProvider`:

```swift
    nonisolated static func neighbourhoodRadius(
        product: MicroTopographyProduct, options: MicroTopographyOptions, overlays: CompositeOverlays
    ) -> Float {
        var radius: Float
        switch product {
        case .localRelief: radius = options.lrmRadiusMeters
        case .redRelief: radius = options.opennessRadiusMeters
        case .skyView: radius = options.svfRadiusMeters
        case .habitation: radius = options.habitationRadiusMeters
        case .rakingLight, .relativeElevation: radius = 0
        }
        if overlays.habitationOpacity > 0 { radius = max(radius, options.habitationRadiusMeters) }
        if overlays.skyViewStrength > 0 { radius = max(radius, options.svfRadiusMeters) }
        return radius
    }

    /// 3DEP map tiles are resampled from 1 m lidar; everything else is native.
    nonisolated static func nativeGroundSampleDistance(source: String, gridSpacing: Double) -> Double {
        source.hasPrefix("3DEP") && !source.contains("fallback") ? max(gridSpacing, 1.0) : gridSpacing
    }
```

Add a `decimation: Int = 1` parameter to `thalwegVertices` and subtract `Double(decimation - 1) / 2` from both
`column` and `row` (decimated cell centres sit half a box in). Replace the body of `microPipelineImage` after the
`overlays`/`options` setup with:

```swift
        let dest = tile.grid.width - tile.margin * 2
        let mpp = tile.grid.groundSampleDistance
        let factor = AnalysisRasterBuilder.decimation(
            tileGroundSampleDistance: mpp,
            nativeGroundSampleDistance: Self.nativeGroundSampleDistance(source: tile.source, gridSpacing: mpp),
            destinationPixels: dest)
        let skirt = AnalysisRasterBuilder.skirtPixels(
            radiusMeters: Self.neighbourhoodRadius(product: product, options: options, overlays: overlays),
            groundSampleDistance: mpp, decimation: factor, destinationPixels: dest)
        var neighbours: [SIMD2<Int32>: AnalysisTileSource] = [:]
        for dy in -1...1 {
            for dx in -1...1 where !(dx == 0 && dy == 0) {
                if let n = cache["\(z)/\(x + dx)/\(y + dy)"] {
                    neighbours[SIMD2(Int32(dx), Int32(dy))] = AnalysisTileSource(samples: n.grid.samples, paddedWidth: n.grid.width, margin: n.margin)
                }
            }
        }
        let center = AnalysisTileSource(samples: tile.grid.samples, paddedWidth: tile.grid.width, margin: tile.margin)
        let cellX = Float(tile.grid.metersPerColumn), cellY = Float(tile.grid.metersPerRow)
        // Built off the provider actor: tile fetches and other tiles keep flowing meanwhile.
        guard let analysis = await Task.detached(priority: .userInitiated, operation: {
            AnalysisRasterBuilder.build(center: center, skirt: skirt, decimation: factor,
                                        cellSizeX: cellX, cellSizeY: cellY, neighbours: neighbours)
        }).value else { return nil }

        let thalweg = product == .relativeElevation
            ? Self.thalwegVertices(
                settings.thalweg, fallbackSurface: settings.elevationRange?.lowerBound ?? tile.elevationLow,
                tileBounds: tile.displayRegion.mercatorBounds, destinationPixels: dest, skirt: skirt,
                cellSizeX: cellX, cellSizeY: cellY, decimation: factor)
            : []
        guard let result = await microPipeline.render(
            product, raster: analysis.raster, window: analysis.window, options: options,
            thalweg: thalweg, overlays: overlays, outputScale: overlays.isEmpty ? 1 : factor
        ) else { return nil }
        return result.display.makeImage()
```

Leave `stitchedRaster` in place for `viewshed(at:)` until Task C4 replaces it.

- [x] **Step 5: Run the harness** → Expected: all B6 checks PASS (if the warm-render check fails, print the per-stage timings and record them in `STATUS.md` rather than loosening the threshold).
- [x] **Step 6: Commit** — `perf(tiles): per-product skirts, native-resolution analysis, off-actor zero-copy stitching`.

### Task B7: Serve z18+ tiles from the COG coordinator, ImageServer as fallback

**Files:**
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift` (`init` default elevation source)
- Test: `Tools/ViewerHarness/ProviderMicroChecks.swift` (offline fallback semantics), `Tools/LiveCheck/main.swift` (live)

- [x] **Step 1: Write the failing offline check**

```swift
nonisolated final class RecordingElevationStub: ElevationProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let answers: Bool
    init(answers: Bool) { self.answers = answers }
    var callCount: Int { lock.withLock { calls } }
    func elevation(for region: GeoRegion, targetSamples: Int) async -> Evidence<ElevationGrid> {
        lock.withLock { calls += 1 }
        guard answers else { return .unavailable(.noCoverage(.usgs3DEP)) }
        return .observed(ElevationGrid(width: 2, height: 2, samples: [1, 2, 3, 4], region: region), Provenance(source: .usgs3DEP))
    }
}

@MainActor
func checkElevationFallback() async {
    print("\n--- B7. COG-first elevation ---")
    let region = GeoRegion(minLatitude: 38.66, maxLatitude: 38.661, minLongitude: -90.06, maxLongitude: -90.059)
    let cog = RecordingElevationStub(answers: true), server = RecordingElevationStub(answers: true)
    _ = await FallbackElevationProvider(primary: cog, fallback: server).elevation(for: region, targetSamples: 2)
    check("the COG source answers first and the ImageServer is not asked", cog.callCount == 1 && server.callCount == 0)
    let empty = RecordingElevationStub(answers: false), backup = RecordingElevationStub(answers: true)
    let served = await FallbackElevationProvider(primary: empty, fallback: backup).elevation(for: region, targetSamples: 2)
    check("the ImageServer answers where no COG covers", served.value != nil && backup.callCount == 1)
    check("the provider's default source is COG-first", TerrainTileProvider.defaultElevationSourceDescription == "COG → ImageServer")
}
```

- [x] **Step 2: Run the harness** → Expected: compile error `type 'TerrainTileProvider' has no member 'defaultElevationSourceDescription'`.
- [x] **Step 3: Implement** — in `TerrainTileProvider`:

```swift
    public nonisolated static let defaultElevationSourceDescription = "COG → ImageServer"
```

and in `init` replace `self.elevation = elevation ?? USGS3DEPService()` with:

```swift
        // Native 1 m COGs first (a few ranged GETs, ~1 s cold); the ImageServer's
        // seamless mosaic answers wherever no single COG covers the tile.
        self.elevation = elevation ?? FallbackElevationProvider(
            primary: ElevationTileCoordinator.shared, fallback: USGS3DEPService())
```

- [x] **Step 4: Live check** — in `Tools/LiveCheck/main.swift` `runCoordinatorCheck()`, append:

```swift
    let started2 = Date()
    let path = tilePath(lat: 38.66040, lon: -90.06205, z: 19)
    let liveProvider = TerrainTileProvider()
    let tile = await liveProvider.tileImage(x: path.x, y: path.y, z: 19, region: TerrainTileOverlay.region(for: path), pixels: 512)
    let seconds = Date().timeIntervalSince(started2)
    check("a cold z19 tile streams through the COG-first default in < 8 s", tile != nil && seconds < 8, String(format: "%.2f s", seconds))
```

- [x] **Step 5: Run** harness (B7 PASS) and `./Tools/run-live-check.sh` (new check PASS).
- [x] **Step 6: Commit** — `feat(elevation): stream z18+ tiles from 3DEP COGs, ImageServer as fallback`.

### Task B8: Real memory budget — lazy derivative planes, bitmaps counted, 256 MB cap

**Files:**
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift` (`CachedTile`, `loadTile`, `shade`, `shadeToImage`, `tileImage`, `inspectSpot`, `store`, `evictUnderPressure`, `memoryCacheSize`)
- Modify: `Tools/ViewerHarness/main.swift` (replace the tautological budget check)
- Test: `Tools/ViewerHarness/ProviderMicroChecks.swift`

- [x] **Step 1: Write the failing checks**

```swift
@MainActor
func checkProviderMemory() async {
    print("\n--- B8. provider memory ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: 0)
    await scene.loadNeighbourhood()
    let megabytes = await scene.provider.memoryCacheSize() / 1_048_576
    check("9 shaded 512 px tiles hold < 25 MB (no eager derivative planes)", megabytes < 25, "\(megabytes) MB")
    let spot = await scene.provider.inspectSpot(at: scene.region().center)
    check("spot inspection still reports slope without cached derivatives", spot.map { !$0.slopeDegrees.isNaN } ?? false)
    check("the tile cache budget leaves room under the 500 MB app ceiling",
          TerrainTileProvider.maxMemoryCacheBytes <= 256 * 1024 * 1024)
    try? FileManager.default.removeItem(at: scene.directory)
}
```

and in `main.swift` delete `check("provider memory cache budget is 500 MB", …)`.

- [x] **Step 2: Run the harness** → Expected: FAIL `9 shaded 512 px tiles hold < 25 MB` (≈ 64 MB today) and FAIL on the budget check.
- [x] **Step 3: Implement**
  - `CachedTile.products` becomes `var products: ReliefProducts?` (init parameter default `nil`).
  - `byteCount` counts what is actually held:
```swift
        var byteCount: Int {
            let plane = grid.samples.count * MemoryLayout<Float>.stride
            let planes = 1 + (products.map { 3 + ($0.normalX == nil ? 0 : 3) } ?? 0)
            return plane * planes + (rendered.map { $0.bytesPerRow * $0.height } ?? 0)
        }
```
  - Delete `private var cachedBytes` and its bookkeeping; set `public nonisolated static let maxMemoryCacheBytes: Int = 256 * 1024 * 1024`; replace `memoryCacheSize()` and add eviction:
```swift
    public func memoryCacheSize() -> Int {
        cache.values.reduce(0) { $0 + $1.byteCount }
    }

    private func enforceMemoryBudget() {
        var total = memoryCacheSize()
        while (total > Self.maxMemoryCacheBytes || cacheOrder.count > cacheLimit), cacheOrder.count > 1 {
            let oldest = cacheOrder.removeFirst()
            renderedOrder.removeAll { $0 == oldest }
            if let evicted = cache.removeValue(forKey: oldest) { total -= evicted.byteCount }
        }
    }
```
    Call `enforceMemoryBudget()` at the end of `store(_:for:)` (replacing its eviction loop) and after `cache[key]?.rendered = image` in `tileImage`.
  - In `loadTile` (disk path) and `shade(_:margin:)`, remove `await raster.reliefProducts(for:)` and pass no `products`.
  - Derivatives on demand, for the CPU fallback only:
```swift
    private func ensureProducts(for key: String) async -> ReliefProducts? {
        guard let tile = cache[key] else { return nil }
        if let existing = tile.products { return existing }
        let computed = await raster.reliefProducts(for: tile.grid)
        cache[key]?.products = computed
        enforceMemoryBudget()
        return computed
    }
```
    In `shadeToImage`, before `return Self.cpuRender(...)`: `guard let products = await ensureProducts(for: "\(z)/\(x)/\(y)") else { return nil }` and pass `products`.
  - In `tileImage`'s two `report?(TileEvent(…))` calls use `backend: cached.products?.backend ?? .gpu`.
  - `inspectSpot` computes slope/aspect locally:
```swift
    /// Horn slope and aspect at one cell -- the arithmetic of `horn_slope_aspect`.
    nonisolated static func hornSlopeAspect(_ grid: ElevationGrid, x: Int, y: Int) -> (slope: Float, aspect: Float) {
        guard x >= 1, y >= 1, x + 1 < grid.width, y + 1 < grid.height else { return (.nan, .nan) }
        let w = grid.width, z = grid.samples
        let a = z[(y - 1) * w + x - 1], b = z[(y - 1) * w + x], c = z[(y - 1) * w + x + 1]
        let d = z[y * w + x - 1], e = z[y * w + x], f = z[y * w + x + 1]
        let g = z[(y + 1) * w + x - 1], h = z[(y + 1) * w + x], i = z[(y + 1) * w + x + 1]
        guard ![a, b, c, d, e, f, g, h, i].contains(where: \.isNaN) else { return (.nan, .nan) }
        let dzdx = ((c + 2 * f + i) - (a + 2 * d + g)) / Float(8 * grid.metersPerColumn)
        let dzdy = ((g + 2 * h + i) - (a + 2 * b + c)) / Float(8 * grid.metersPerRow)
        let slope = atan((dzdx * dzdx + dzdy * dzdy).squareRoot()) * 180 / .pi
        guard dzdx != 0 || dzdy != 0 else { return (slope, 0) }
        var aspect = 90 - atan2(dzdy, -dzdx) * 180 / .pi
        if aspect < 0 { aspect += 360 }
        if aspect >= 360 { aspect -= 360 }
        return (slope, aspect)
    }
```
    and in `inspectSpot` replace the `products` index lookup with `let (slope, aspect) = Self.hornSlopeAspect(entry.grid, x: c, y: r)`.
  - In `evictUnderPressure`, drop the `cachedBytes` lines (plain `cache.removeValue`).
- [x] **Step 4: Run** harness → B8 PASS and the existing spot-inspection checks still PASS; `xcodebuild` → `BUILD SUCCEEDED`.
- [x] **Step 5: Commit** — `perf(cache): compute derivative planes on demand and budget what tiles really hold`.

### Task B9: Route `.rrim` through `compute_rrim`

`.rrim` still uses the legacy two-stage path (8 fixed directions, radius in cells), so the openness-radius slider does nothing.

**Files:** Modify `LidarExplorer/MapLayer/TerrainTileOverlay.swift` (`shadeToImage`); Test: `ProviderMicroChecks.swift`

- [x] **Step 1: Failing check**

```swift
@MainActor
func checkRedReliefRouting() async {
    print("\n--- B9. RRIM routing ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    await scene.loadNeighbourhood()
    var settings = TerrainStyleSettings()
    settings.style = .rrim
    await scene.provider.update(settings)
    check("RRIM tiles come from the micro pipeline at native resolution (64 px at z19)", await scene.image()?.width == 64)
    try? FileManager.default.removeItem(at: scene.directory)
}
```

- [x] **Step 2: Run** → Expected: FAIL (legacy path returns 512 px).
- [x] **Step 3: Implement** — in `shadeToImage` replace the two style cases with:

```swift
        case .rrim, .localRelief, .skyView, .rakingLight, .relativeElevation:
            if let image = await microPipelineImage(for: tile, x: x, y: y, z: z, settings: settings) { return image }
            // Only RRIM has an older route when the micro pipeline is unavailable.
            return settings.style == .rrim ? await rrimImage(for: tile) : nil
```

- [x] **Step 4: Run** → B9 PASS. **Step 5: Commit** — `fix(rrim): shade Red Relief tiles with compute_rrim`.

---

## Part C — Complete Phases 4–5

### Task C1: Habitation mask, sky-view shading, grazing raking light, REM controls

**Files:**
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift` (`TerrainStyleSettings`, `microPipelineImage` overlays/options, new `currentSettings()`)
- Modify: `LidarExplorer/Presentation/TerrainViewerModel.swift` (properties, `pushSettings`, `resetShading`, `hasCustomShading`)
- Modify: `LidarExplorer/Presentation/ViewerSettingsSheetView.swift` (new section)
- Test: `Tools/ViewerHarness/ProviderMicroChecks.swift`

- [x] **Step 1: Failing checks**

```swift
@MainActor
func checkMicroOverlaySettings() async {
    print("\n--- C1. overlays and grazing light ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    let model = TerrainViewerModel(terrainProvider: scene.provider)
    model.style = .rakingLight
    model.rakingAltitude = 7
    model.showsHabitationMask = true
    model.skyViewShading = 0.5
    try? await Task.sleep(for: .milliseconds(80))
    let settings = await scene.provider.currentSettings()
    check("grazing altitude reaches the provider", settings.rakingAltitudeDegrees == 7)
    check("overlay toggles reach the provider", settings.showsHabitationMask && settings.skyViewShading == 0.5)
    check("custom overlays count as custom shading", model.hasCustomShading)
    await scene.loadNeighbourhood()
    check("a tile with the habitation overlay composites at display resolution", await scene.image()?.width == 512)
    model.resetShading()
    check("reset restores overlay defaults",
          model.rakingAltitude == TerrainViewerModel.Defaults.rakingAltitude && !model.showsHabitationMask && model.skyViewShading == 0)
    try? FileManager.default.removeItem(at: scene.directory)
}
```

- [x] **Step 2: Run** → Expected: compile error `value of type 'TerrainViewerModel' has no member 'rakingAltitude'`.
- [x] **Step 3: Settings + provider** — in `TerrainStyleSettings` add:

```swift
    /// Sun altitude for `.rakingLight`, degrees; grazing light sits at 5–15.
    public var rakingAltitudeDegrees: Double = 10
    public var showsHabitationMask = false
    /// 0...1 strength of sky-view ambient occlusion over micro styles.
    public var skyViewShading: Float = 0
```

In `TerrainTileProvider` add `public func currentSettings() -> TerrainStyleSettings { settings }`. In
`microPipelineImage`, after the contour overlay lines add
`overlays.habitationOpacity = settings.showsHabitationMask ? 0.75 : 0` and
`overlays.skyViewStrength = settings.skyViewShading`, and change the raking branch to
`options.sunAltitudeDegrees = Float(settings.rakingAltitudeDegrees)`.

- [x] **Step 4: Model** — in `TerrainViewerModel.Defaults` add `public static let rakingAltitude: Double = 10`; add:

```swift
    public var rakingAltitude: Double = Defaults.rakingAltitude {
        didSet { if rakingAltitude != oldValue, style == .rakingLight { pushSettings() } }
    }
    public var showsHabitationMask = false {
        didSet { if showsHabitationMask != oldValue { pushSettings() } }
    }
    public var skyViewShading: Double = 0 {
        didSet { if skyViewShading != oldValue { pushSettings() } }
    }
```

In `pushSettings()` add `settings.rakingAltitudeDegrees = rakingAltitude`, `settings.showsHabitationMask = showsHabitationMask`,
`settings.skyViewShading = Float(skyViewShading)`. In `resetShading()` add `rakingAltitude = Defaults.rakingAltitude`,
`showsHabitationMask = false`, `skyViewShading = 0`. In `hasCustomShading` add
`|| rakingAltitude != Defaults.rakingAltitude || showsHabitationMask || skyViewShading != 0`.

- [x] **Step 5: Settings UI** — in `ViewerSettingsSheetView.terrainSection`, before the reset button:

```swift
                if model.style.microTopographyProduct != nil {
                    Toggle("Habitation Potential Mask", isOn: $model.showsHabitationMask)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Sky-View Shading")
                            Spacer()
                            Text(String(format: "%.0f%%", model.skyViewShading * 100)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: $model.skyViewShading, in: 0...1)
                    }
                }
                if model.style == .rakingLight {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Grazing Sun Altitude")
                            Spacer()
                            Text(String(format: "%.0f°", model.rakingAltitude)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: $model.rakingAltitude, in: 5...15, step: 1)
                    }
                }
                if model.style == .relativeElevation {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Band Width")
                            Spacer()
                            Text(String(format: "%.2f m", model.microTopographyOptions.remBandMeters)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: $model.microTopographyOptions.remBandMeters, in: 0...1, step: 0.25)
                    }
                }
```

- [x] **Step 6: Verify** — harness (C1 PASS); `xcodebuild` (BUILD SUCCEEDED); Simulator: LRM + mask shows amber benches.
- [x] **Step 7: Commit** — `feat(micro): habitation mask, sky-view shading and grazing-light controls on tiles`.

### Task C2: Scrollable style chips instead of a 10-segment picker

**Files:** Modify `LidarExplorer/Presentation/ViewerBottomDockView.swift` (`modeRow`)

- [x] **Step 1: Replace `modeRow`**

```swift
    private var modeRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ReliefStyle.allCases) { style in
                    let selected = model.style == style
                    Button {
                        model.style = style
                    } label: {
                        Text(style.dockLabel)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.25)) : AnyShapeStyle(.thinMaterial),
                                        in: Capsule())
                            .overlay(Capsule().strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 1)
        }
        .onChange(of: model.style) { _, _ in selectionFeedback.selectionChanged() }
    }
```

- [x] **Step 2: Verify** — `xcodebuild` → BUILD SUCCEEDED; Simulator screenshot of the dock at iPad portrait width shows all ten labels reachable by scrolling.
- [x] **Step 3: Commit** — `feat(dock): scrollable style chips for ten shading styles`.

### Task C3: Transects — off-actor analysis, true min-max decimation, floating resizable panel, Pencil in any mode

**Files:**
- Create: `LidarExplorer/Domain/ProfileDecimation.swift` (add to `Tools/run-harness.sh` after `ElevationTransect.swift`)
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift` (`transectMosaic` filters by bounds)
- Modify: `LidarExplorer/Presentation/TerrainViewerModel.swift` (`updateTransectDrag`, `generateProfile`, `transectParameters`)
- Modify: `LidarExplorer/Presentation/ElevationProfileView.swift` (decimation call, metric picker, resizable height)
- Modify: `LidarExplorer/MapLayer/TerrainMapView.swift` (Pencil begins a transect from any mode)
- Test: `Tools/ViewerHarness/ProviderMicroChecks.swift`

- [x] **Step 1: Failing checks**

```swift
@MainActor
func checkTransectPipeline() async {
    print("\n--- C3. transect pipeline ---")
    var points: [ElevationProfilePoint] = (0..<2_000).map {
        ElevationProfilePoint(id: $0, distanceMeters: Double($0) * 0.5, elevationMeters: 100,
                              coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0))
    }
    points[1_234] = ElevationProfilePoint(id: 1_234, distanceMeters: 617, elevationMeters: 98.8,
                                          coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0))
    let decimated = ProfileDecimation.minMax(points, maxCount: 384)
    check("min-max decimation respects the point budget", decimated.count <= 384, "\(decimated.count)")
    check("a one-sample ditch survives decimation", decimated.contains { $0.elevationMeters == 98.8 })
    check("decimation keeps distance order", zip(decimated, decimated.dropFirst()).allSatisfy { $0.distanceMeters <= $1.distanceMeters })

    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: nil)
    await scene.loadNeighbourhood(rings: 2)
    let r = scene.region()
    let field = await scene.provider.transectMosaic(around: r.center, and: CLLocationCoordinate2D(latitude: r.center.latitude, longitude: r.maxLongitude))
    check("the transect field holds only tiles near the line", field.layers.count <= 6, "\(field.layers.count) of 25")
    try? FileManager.default.removeItem(at: scene.directory)
}
```

- [x] **Step 2: Run** → Expected: compile error `cannot find 'ProfileDecimation' in scope`.
- [x] **Step 3: Decimation** — create `LidarExplorer/Domain/ProfileDecimation.swift`:

```swift
//
//  ProfileDecimation.swift
//  LidarExplorer
//
//  Keeps chart point counts bounded without hiding narrow features.
//

import Foundation

public nonisolated enum ProfileDecimation {
    /// Min-max decimation: each bucket contributes its lowest and highest point, in
    /// distance order, so a one-sample ditch between display points still reaches
    /// the chart. At most `maxCount` points.
    public static func minMax(_ points: [ElevationProfilePoint], maxCount: Int) -> [ElevationProfilePoint] {
        guard points.count > maxCount, maxCount >= 4 else { return points }
        let buckets = maxCount / 2
        let size = Double(points.count) / Double(buckets)
        var out: [ElevationProfilePoint] = []
        out.reserveCapacity(buckets * 2)
        for b in 0..<buckets {
            let lower = Int((Double(b) * size).rounded(.down))
            let upper = min(Int((Double(b + 1) * size).rounded(.down)), points.count)
            guard lower < upper else { continue }
            let slice = points[lower..<upper]
            guard let low = slice.min(by: { $0.elevationMeters < $1.elevationMeters }),
                  let high = slice.max(by: { $0.elevationMeters < $1.elevationMeters }) else { continue }
            if low.id == high.id {
                out.append(low)
            } else {
                out.append(contentsOf: low.distanceMeters <= high.distanceMeters ? [low, high] : [high, low])
            }
        }
        return out
    }
}
```

In `ElevationProfileView.chartSection` replace `decimatePoints(profile.points, maxCount: 384)` with
`ProfileDecimation.minMax(profile.points, maxCount: 384)`, delete `decimatePoints`, and change the `ForEach` id to
`\.offset` over `Array(displayPoints.enumerated())` (min-max can emit two points at one distance).

- [x] **Step 4: Provider field bounded to the line**

```swift
    public func transectMosaic(
        around start: CLLocationCoordinate2D, and end: CLLocationCoordinate2D, paddingMeters: Double = 30
    ) -> TileMosaicField {
        let bounds = GeoRegion(
            minLatitude: min(start.latitude, end.latitude), maxLatitude: max(start.latitude, end.latitude),
            minLongitude: min(start.longitude, end.longitude), maxLongitude: max(start.longitude, end.longitude)
        ).expanded(byMeters: paddingMeters)
        let layers = cache.values.compactMap { entry -> TileMosaicField.Layer? in
            let r = entry.displayRegion
            guard r.minLatitude <= bounds.maxLatitude, r.maxLatitude >= bounds.minLatitude,
                  r.minLongitude <= bounds.maxLongitude, r.maxLongitude >= bounds.minLongitude else { return nil }
            return TileMosaicField.Layer(grid: entry.grid, bounds: r)
        }
        let origin = CLLocationCoordinate2D(latitude: (start.latitude + end.latitude) / 2,
                                            longitude: (start.longitude + end.longitude) / 2)
        return TileMosaicField(origin: origin, layers: layers)
    }
```

- [x] **Step 5: Model analyses off the provider actor** — add `public var transectParameters = TransectSignatureParameters()`,
and in `updateTransectDrag` replace `let analysis = await terrainProvider.analyzeTransect(from: start, to: coordinate)` with:

```swift
            let field = await terrainProvider.transectMosaic(around: start, and: coordinate)
            let parameters = self.transectParameters
            let analysis = await Task.detached(priority: .userInitiated) {
                ElevationTransectEngine(field: field, parameters: parameters).analyze(from: start, to: coordinate)
            }.value
```

Apply the same replacement to the `analysis` half of `generateProfile()` (keep the legacy `profile(from:to:)` call).

- [x] **Step 6: Resizable panel + metric picker** — in `ElevationProfileView` add
`@State private var chartHeight: CGFloat = 140`, `@State private var dragStartHeight: CGFloat?`,
`@State private var metric: Metric = .elevation` with `enum Metric: String, CaseIterable { case elevation = "Elevation", slope = "Slope", curvature = "Curvature" }`.
Put a grab handle at the top of `body`'s `VStack`:

```swift
            Capsule()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 44, height: 5)
                .padding(.bottom, 2)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let start = dragStartHeight ?? chartHeight
                            dragStartHeight = start
                            chartHeight = min(max(start - value.translation.height, 90), 420)
                        }
                        .onEnded { _ in dragStartHeight = nil }
                )
                .accessibilityLabel("Resize profile")
```

After `metricsRow` add `Picker("Metric", selection: $metric) { ForEach(Metric.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)`.
In `chartSection` use `.frame(height: chartHeight)`; when `metric != .elevation`, chart
`model.activeTransectAnalysis?.samples` instead (`LineMark(x: distance, y: slopeDegrees or curvature)` over
`stride(from: 0, to: samples.count, by: max(samples.count / 384, 1))`, skipping NaN), with a
`RuleMark(y: .value("Flank threshold", 20))` for slope.

- [x] **Step 7: Pencil from any mode** — in `TerrainMapView.Coordinator`:

```swift
        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if touch.type == .pencil {
                // Take the stroke before MapKit's own pan can claim it.
                mapView?.isScrollEnabled = false
                return true
            }
            return model.interactionMode == .transect
        }
```

and in `handleTransectPan` `.began`: `if model.interactionMode != .transect { model.interactionMode = .transect }` before
`model.beginTransectDrag(at: coord)`; in `.ended, .cancelled` add
`map.isScrollEnabled = model.interactionMode != .transect`.

- [x] **Step 8: Verify** — harness (C3 PASS); `xcodebuild`; Simulator: drag a transect across a mound, resize the panel, switch to Slope.
- [x] **Step 9: Commit** — `feat(transect): off-actor analysis, min-max chart decimation, resizable metric panel`.

### Task C4: Wide-area viewshed on a tiered Mercator mosaic (≤ 2048²)

The provider viewshed stitches only 3×3 tiles with a 1,024 px cap: at z19 a 2.5 km radius sees ~120 m of real terrain.

**Files:**
- Create: `LidarExplorer/MapLayer/MercatorMosaicBuilder.swift` (add to `Tools/run-harness.sh` and `Tools/run-live-check.sh`)
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift` (`viewshed(at:…)`; delete `stitchedRaster` and `CachedTile.unpaddedSample`, now unused)
- Test: `Tools/ViewerHarness/ProviderMicroChecks.swift`

- [x] **Step 1: Failing checks**

```swift
@MainActor
func checkViewshedMosaic() async {
    print("\n--- C4. viewshed mosaic ---")
    check("resolution tiers: 1 m to 1 km, 2.5 m to 2.5 km, 5 m beyond",
          MercatorMosaicBuilder.tieredCellSize(radiusMeters: 800) == 1
            && MercatorMosaicBuilder.tieredCellSize(radiusMeters: 2_000) == 2.5
            && MercatorMosaicBuilder.tieredCellSize(radiusMeters: 4_000) == 5)
    let coarse = makeGrid(width: 100, height: 100, gsd: 20, base: 50)
    let fine = makeGrid(width: 81, height: 81, gsd: 1, base: 60)
    let layers = [TileMosaicField.Layer(grid: coarse, bounds: coarse.region), TileMosaicField.Layer(grid: fine, bounds: fine.region)]
    if let mosaic = MercatorMosaicBuilder.build(center: fine.region.center, radiusMeters: 5_000, finestGroundSampleDistance: 1, layers: layers) {
        let v = mosaic.storage.pointer.assumingMemoryBound(to: Float.self)
        let c = mosaic.pixel(for: fine.region.center)
        check("a 5 km mosaic stays within 2048² and a multiple of 4", mosaic.size <= 2048 && mosaic.size % 4 == 0, "\(mosaic.size)")
        check("the finest layer wins where it covers", v[Int(c.y) * mosaic.size + Int(c.x)] == 60)
        check("coarser layers fill elsewhere", v[(Int(c.y) + 200) * mosaic.size + Int(c.x)] == 50)
        check("ground outside every layer is a void", v[0].isNaN)
    } else {
        check("viewshed mosaic builds", false)
    }
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -40)
    await scene.loadNeighbourhood(rings: 2)
    if let wide = await scene.provider.viewshed(at: scene.region().center, maxRadiusMeters: 300) {
        let spanMeters = wide.region.widthMeters
        check("a 300 m viewshed covers ~600 m of ground", abs(spanMeters - 600) < 40, String(format: "%.0f m", spanMeters))
        check("the observer sees its own neighbourhood", wide.result.mask.values().filter { $0 > 0.5 }.count > 1_000)
    } else {
        check("provider mosaic viewshed renders", false)
    }
    try? FileManager.default.removeItem(at: scene.directory)
}
```

- [x] **Step 2: Run** → Expected: compile error `cannot find 'MercatorMosaicBuilder' in scope`.
- [x] **Step 3: Create `LidarExplorer/MapLayer/MercatorMosaicBuilder.swift`**

```swift
//
//  MercatorMosaicBuilder.swift
//  LidarExplorer
//
//  Rasterises cached tiles onto one Mercator-aligned grid for wide-area analysis.
//

import CoreLocation
import Foundation
import simd

/// A square, Mercator-aligned elevation grid in page-aligned storage.
public nonisolated struct MercatorMosaic: Sendable {
    public let storage: COGMappedStorage
    public let size: Int
    public let minX: Double
    public let minY: Double
    public let maxX: Double
    public let maxY: Double
    /// Ground metres per cell at the mosaic centre.
    public let cellSizeMeters: Float

    public var region: GeoRegion {
        let sw = GeoRegion.fromMercatorMeters(x: minX, y: minY)
        let ne = GeoRegion.fromMercatorMeters(x: maxX, y: maxY)
        return GeoRegion(minLatitude: sw.latitude, maxLatitude: ne.latitude, minLongitude: sw.longitude, maxLongitude: ne.longitude)
    }

    public var raster: ElevationRaster {
        ElevationRaster(
            samples: .mapped(base: storage.pointer, mappedLength: storage.length, sampleOffset: 0, owner: storage),
            geometry: RasterGeometry(width: size, height: size, cellSizeX: cellSizeMeters, cellSizeY: cellSizeMeters)
        )
    }

    /// Fractional pixel coordinates (centres at integers) of a coordinate.
    public func pixel(for coordinate: CLLocationCoordinate2D) -> SIMD2<Float> {
        let p = GeoRegion.toMercatorMeters(coordinate)
        return SIMD2(Float((p.x - minX) / (maxX - minX) * Double(size) - 0.5),
                     Float((maxY - p.y) / (maxY - minY) * Double(size) - 0.5))
    }
}

public nonisolated enum MercatorMosaicBuilder {
    /// Ground cell for a viewshed radius: 1 m to 1 km, 2.5 m to 2.5 km, 5 m beyond.
    public static func tieredCellSize(radiusMeters: Double) -> Double {
        radiusMeters <= 1_000 ? 1 : (radiusMeters <= 2_500 ? 2.5 : 5)
    }

    /// Layers are drawn coarse to fine, so finer layers overwrite where they answer.
    public static func build(
        center: CLLocationCoordinate2D,
        radiusMeters: Double,
        finestGroundSampleDistance: Double,
        maximumSize: Int = 2048,
        layers: [TileMosaicField.Layer]
    ) -> MercatorMosaic? {
        guard radiusMeters > 0, maximumSize >= 4 else { return nil }
        var cell = max(tieredCellSize(radiusMeters: radiusMeters), finestGroundSampleDistance)
        var size = Int((2 * radiusMeters / cell).rounded(.up))
        size = min(max((size + 3) / 4 * 4, 4), maximumSize / 4 * 4)
        cell = max(cell, 2 * radiusMeters / Double(size))

        let k = cos(center.latitude * .pi / 180)
        let half = Double(size) * cell / 2 / k
        let c = GeoRegion.toMercatorMeters(center)
        let minX = c.x - half, maxX = c.x + half, minY = c.y - half, maxY = c.y + half
        guard let storage = COGMappedStorage(length: size * size * 4) else { return nil }
        let out = storage.pointer.bindMemory(to: Float.self, capacity: size * size)
        out.initialize(repeating: .nan, count: size * size)
        let pixel = (maxX - minX) / Double(size)

        for layer in layers.sorted(by: { $0.grid.groundSampleDistance > $1.grid.groundSampleDistance }) {
            let b = layer.bounds.mercatorBounds
            let x0 = max(Int(((b.minX - minX) / pixel).rounded(.down)), 0)
            let x1 = min(Int(((b.maxX - minX) / pixel).rounded(.up)), size)
            let y0 = max(Int(((maxY - b.maxY) / pixel).rounded(.down)), 0)
            let y1 = min(Int(((maxY - b.minY) / pixel).rounded(.up)), size)
            guard x0 < x1, y0 < y1 else { continue }
            for py in y0..<y1 {
                let my = maxY - (Double(py) + 0.5) * pixel
                for px in x0..<x1 {
                    let coordinate = GeoRegion.fromMercatorMeters(x: minX + (Double(px) + 0.5) * pixel, y: my)
                    guard layer.bounds.contains(coordinate), let v = layer.grid.interpolatedElevation(at: coordinate) else { continue }
                    out[py * size + px] = v
                }
            }
        }
        return MercatorMosaic(storage: storage, size: size, minX: minX, minY: minY, maxX: maxX, maxY: maxY,
                              cellSizeMeters: Float(cell))
    }
}
```

- [x] **Step 4: Provider** — replace `viewshed(at:eyeHeight:targetHeight:maxRadiusMeters:)` with:

```swift
    /// The last mosaic, reused while the observer stays in its inner quarter (a dragged pin).
    private var viewshedMosaicCache: (mosaic: MercatorMosaic, center: CLLocationCoordinate2D, radius: Float)?

    public func viewshed(
        at observer: CLLocationCoordinate2D, eyeHeight: Float = 2.0, targetHeight: Float = 0.5, maxRadiusMeters: Float = 2500
    ) async -> ProviderViewshed? {
        let mosaic: MercatorMosaic
        if let cached = viewshedMosaicCache, cached.radius == maxRadiusMeters,
           Geodesy.distance(from: cached.center, to: observer) < Double(maxRadiusMeters) * 0.25 {
            mosaic = cached.mosaic
        } else {
            let reach = GeoRegion(center: observer, latitudeSpan: 0, longitudeSpan: 0).expanded(byMeters: Double(maxRadiusMeters) * 1.3)
            let layers = cache.values.compactMap { entry -> TileMosaicField.Layer? in
                let r = entry.displayRegion
                guard r.minLatitude <= reach.maxLatitude, r.maxLatitude >= reach.minLatitude,
                      r.minLongitude <= reach.maxLongitude, r.maxLongitude >= reach.minLongitude else { return nil }
                return TileMosaicField.Layer(grid: entry.grid, bounds: r)
            }
            guard let finest = layers.map(\.grid.groundSampleDistance).min() else { return nil }
            let radius = Double(maxRadiusMeters) * 1.25
            guard let built = await Task.detached(priority: .userInitiated, operation: {
                MercatorMosaicBuilder.build(center: observer, radiusMeters: radius, finestGroundSampleDistance: finest, layers: layers)
            }).value else { return nil }
            viewshedMosaicCache = (built, observer, maxRadiusMeters)
            mosaic = built
        }
        let p = mosaic.pixel(for: observer)
        guard let result = await microPipeline.viewshed(
            raster: mosaic.raster, observerColumn: p.x, observerRow: p.y,
            eyeHeight: eyeHeight, targetHeight: targetHeight, maxRadiusMeters: maxRadiusMeters
        ) else { return nil }
        return ProviderViewshed(result: result, region: mosaic.region)
    }
```

Clear `viewshedMosaicCache = nil` in `clear()` and in `store(_:for:)` (new terrain arrived). Delete `stitchedRaster` and `unpaddedSample`.

- [x] **Step 5: Verify** — harness (C4 PASS; B3 checks still PASS — update B3's `> 512` width expectation to `> 0`); `xcodebuild`.
- [x] **Step 6: Commit** — `feat(viewshed): tiered Mercator mosaic up to 5 km, reused while dragging`.

### Task C5: Draw a river thalweg for REM

**Files:**
- Create: `LidarExplorer/MapLayer/ThalwegBuilder.swift` (add to both scripts)
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift` (`thalweg(from:)`)
- Modify: `LidarExplorer/Presentation/TerrainViewerModel.swift` (`InteractionMode.thalweg`, `thalweg`, `thalwegDraft`, drawing entry points)
- Modify: `LidarExplorer/MapLayer/TerrainMapView.swift` (draw in `.thalweg` mode; blue polyline)
- Modify: `LidarExplorer/Presentation/ViewerSettingsSheetView.swift` ("Draw River Thalweg" / "Clear Thalweg")
- Test: `Tools/ViewerHarness/ProviderMicroChecks.swift`

- [x] **Step 1: Failing checks**

```swift
@MainActor
func checkThalwegBuilder() {
    print("\n--- C5. thalweg builder ---")
    var valley = sceneGrid(width: 200, height: 200, gsd: 1.0) { x, y in 100 + 0.2 * Float(abs(x - 100)) - 0.01 * Float(y) }
    var samples = valley.samples
    for y in 90...92 { samples[y * 200 + 100] += 3 }   // a bridge deck over the channel
    valley = ElevationGrid(width: 200, height: 200, samples: samples, region: valley.region)
    let drawn = [valley.coordinate(x: 103, y: 10), valley.coordinate(x: 103, y: 190)]
    let points = ThalwegBuilder.build(drawn: drawn) { valley.interpolatedElevation(at: $0) }
    check("a 180 m line densifies to ~15 m spacing", (12...15).contains(points.count), "\(points.count)")
    let (_, row0) = valley.gridCoordinates(for: points[0].coordinate)
    check("vertices snap to the channel floor, not the bank 3 m away",
          points.allSatisfy { p in
              let (_, row) = valley.gridCoordinates(for: p.coordinate)
              return abs(p.waterSurface - (100 - 0.01 * Float(row))) < 0.25
          }, "row0 \(row0)")
    check("the water surface falls monotonically downstream (bridge removed)",
          zip(points, points.dropFirst()).allSatisfy { $0.waterSurface >= $1.waterSurface })
    check("fewer than two drawn points build nothing", ThalwegBuilder.build(drawn: [drawn[0]]) { _ in 1 }.isEmpty)
}
```

- [x] **Step 2: Run** → Expected: compile error `cannot find 'ThalwegBuilder' in scope`.
- [x] **Step 3: Create `LidarExplorer/MapLayer/ThalwegBuilder.swift`**

```swift
//
//  ThalwegBuilder.swift
//  LidarExplorer
//
//  Turns a hand-drawn river line into a water-surface profile.
//

import CoreLocation
import Foundation

public nonisolated enum ThalwegBuilder {
    /// Densifies `drawn` to `spacingMeters`, takes each vertex's water surface as
    /// the lowest ground within `snapRadiusMeters` (hydro-flattened 3DEP water reads
    /// as the channel floor), then forces the surface to fall monotonically toward
    /// the lower end, which strips bank, bridge and levee hits.
    public static func build(
        drawn: [CLLocationCoordinate2D],
        spacingMeters: Double = 15,
        snapRadiusMeters: Double = 6,
        maximumPoints: Int = 256,
        elevation: (CLLocationCoordinate2D) -> Float?
    ) -> [ThalwegPoint] {
        guard drawn.count >= 2, maximumPoints >= 2 else { return [] }
        var lengths: [Double] = [0]
        for i in 1..<drawn.count { lengths.append(lengths[i - 1] + Geodesy.distance(from: drawn[i - 1], to: drawn[i])) }
        guard let total = lengths.last, total > 0 else { return [] }
        let spacing = max(spacingMeters, total / Double(maximumPoints - 1))

        var vertices: [CLLocationCoordinate2D] = []
        var segment = 0
        for s in stride(from: 0.0, through: total, by: spacing) {
            while segment < drawn.count - 2, lengths[segment + 1] < s { segment += 1 }
            let span = lengths[segment + 1] - lengths[segment]
            let t = span > 0 ? (s - lengths[segment]) / span : 0
            let a = drawn[segment], b = drawn[segment + 1]
            vertices.append(CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                                   longitude: a.longitude + (b.longitude - a.longitude) * t))
        }

        var surfaces: [(CLLocationCoordinate2D, Float)] = []
        for v in vertices {
            let dLat = snapRadiusMeters / GeoRegion.metersPerDegreeLatitude
            let dLon = snapRadiusMeters / (GeoRegion.metersPerDegreeLatitude * cos(v.latitude * .pi / 180))
            var lowest: Float?
            for j in -2...2 {
                for i in -2...2 {
                    let probe = CLLocationCoordinate2D(latitude: v.latitude + dLat * Double(j) / 2,
                                                       longitude: v.longitude + dLon * Double(i) / 2)
                    if let z = elevation(probe) { lowest = min(lowest ?? z, z) }
                }
            }
            if let lowest { surfaces.append((v, lowest)) }
        }
        guard surfaces.count >= 2, let first = surfaces.first?.1, let last = surfaces.last?.1 else { return [] }

        var values = surfaces.map(\.1)
        if first >= last {
            for i in 1..<values.count { values[i] = min(values[i], values[i - 1]) }
        } else {
            for i in stride(from: values.count - 2, through: 0, by: -1) { values[i] = min(values[i], values[i + 1]) }
        }
        return zip(surfaces, values).map { entry, surface in
            ThalwegPoint(latitude: entry.0.latitude, longitude: entry.0.longitude, waterSurface: surface)
        }
    }
}
```

- [x] **Step 4: Provider + model + map + settings**
  - Provider: `public func thalweg(from drawn: [CLLocationCoordinate2D]) -> [ThalwegPoint] { ThalwegBuilder.build(drawn: drawn) { self.elevation(at: $0) } }`.
  - Model: add `case thalweg` to `InteractionMode`; in its `didSet`, `if interactionMode != .thalweg { thalwegDraft = [] }`. Add:
```swift
    public var thalweg: [ThalwegPoint] = [] { didSet { if thalweg != oldValue { pushSettings() } } }
    public private(set) var thalwegDraft: [CLLocationCoordinate2D] = []

    public func extendThalwegDraft(_ coordinate: CLLocationCoordinate2D) { thalwegDraft.append(coordinate) }

    public func commitThalwegDraft() {
        let drawn = thalwegDraft
        thalwegDraft = []
        interactionMode = .explore
        Task { [terrainProvider] in
            let points = await terrainProvider.thalweg(from: drawn)
            self.thalweg = points
        }
    }
```
    and in `pushSettings()` add `settings.thalweg = thalweg`.
  - Map: in `gestureRecognizer(_:shouldReceive:)` also return `true` for `.thalweg`; `updateUIView` sets `map.isScrollEnabled = !(model.interactionMode == .transect || model.interactionMode == .thalweg)`; in `handleTransectPan` when `model.interactionMode == .thalweg`: `.began`/`.changed` → `model.extendThalwegDraft(coord)`, `.ended` → `model.commitThalwegDraft()`; draw `model.thalwegDraft` (while drawing) or `model.thalweg` coordinates as an `MKPolyline` titled `"Thalweg"`, stroked `UIColor.systemBlue` at 3 pt.
  - Settings (inside `if model.style == .relativeElevation`): `Button("Draw River Thalweg") { model.interactionMode = .thalweg; dismiss() }` and `Button("Clear Thalweg", role: .destructive) { model.thalweg = [] }.disabled(model.thalweg.isEmpty)`.
- [x] **Step 5: Verify** — harness (C5 PASS); `xcodebuild`; Simulator: REM → Draw River Thalweg → drag along a channel → tint re-bands against it.
- [x] **Step 6: Commit** — `feat(rem): draw a river thalweg with channel snapping and monotonic water surface`.

### Task C6: Per-zoom render budget table

**Files:** Modify `Tools/ViewerHarness/ProviderMicroChecks.swift` (`makeSyntheticScene` gains `z: Int = 19`), `STATUS.md`

- [x] **Step 1: Add `z` parameter** — change the signature to `makeSyntheticScene(moundOffsetFromSeamMeters: Double?, z: Int = 19)` and use it instead of the constant.
- [x] **Step 2: Add the timing check**

```swift
@MainActor
func checkRenderBudgets() async {
    print("\n--- C6. per-zoom tile render budget (warm, ms) ---")
    for z in [18, 19, 20] {
        let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30, z: z)
        await scene.loadNeighbourhood()
        var row: [String] = []
        var settings = TerrainStyleSettings()
        for style in [ReliefStyle.localRelief, .rrim, .skyView, .rakingLight, .relativeElevation] {
            settings.style = style
            await scene.provider.update(settings)
            _ = await scene.image()
            settings.azimuthDegrees += 1
            await scene.provider.update(settings)
            let started = Date()
            let image = await scene.image()
            let ms = Date().timeIntervalSince(started) * 1000
            row.append("\(style.rawValue) \(String(format: "%.1f", ms))")
            check("z\(z) \(style.rawValue) renders within 16 ms warm", image != nil && ms < 16, String(format: "%.1f ms", ms))
        }
        print("        z\(z): " + row.joined(separator: " · "))
        try? FileManager.default.removeItem(at: scene.directory)
    }
}
```

- [x] **Step 3: Run** → record the printed table in `STATUS.md` under "Build & verification status".
- [x] **Step 4: Commit** — `test(tiles): per-zoom render budget table for micro styles`.

---

## Part D — Phase 6: historical maps and SSURGO soils

Decisions (deviating from the Antigravity reviewed plan, with reasons): historical maps draw through an
`MKOverlayRenderer` with an affine image transform and a clip for the wipe (MapKit already rasterizes overlays off
the main thread; a Metal split-wipe shader would need a custom render path the map does not have). Soil hatching uses
an `MKMultiPolygonRenderer` subclass; the expensive part — SDA/WKT parsing — runs in an actor, so the main thread only
builds `MKPolygon`s. Revisit either only if Task E3 shows frame drops.

Harness file for Part D: create `Tools/ViewerHarness/HistoricalAndSoilChecks.swift` with
`@MainActor func runHistoricalAndSoilChecks() async { print("\n=== Historical maps & SSURGO soils ===") }`, add it to
`Tools/run-harness.sh`, and call it from `main.swift` after `await runProviderMicroChecks()`. Each task appends a
check function and its call.

### Task D1: World files and memory-safe historical image import

**Files:**
- Create: `LidarExplorer/MapLayer/HistoricalMap.swift` (add to `Tools/run-harness.sh`)
- Test: `Tools/ViewerHarness/HistoricalAndSoilChecks.swift`

- [x] **Step 1: Failing checks**

```swift
@MainActor
func checkWorldFiles() {
    print("\n--- D1. world files & import ---")
    let mercator = WorldFile(text: "2.0\n0.0\n0.0\n-2.0\n-10025800.0\n4673300.0\n")
    check("a six-line world file parses", mercator != nil)
    if let w = mercator {
        let corner = w.mapPoint(column: 0, row: 0)
        let expected = MKMapPoint(GeoRegion.fromMercatorMeters(x: -10025800, y: 4673300))
        check("EPSG:3857 world files map pixel centres to Mercator", abs(corner.x - expected.x) < 1e-3 && abs(corner.y - expected.y) < 1e-3)
        check("metre-scale coefficients are read as Web Mercator", w.units == .webMercatorMeters)
    }
    let degrees = WorldFile(text: "0.0001\n0\n0\n-0.0001\n-90.07\n38.67")
    check("degree-scale coefficients are read as geographic", degrees?.units == .degrees)
    let rotated = WorldFile(text: "2\n0.5\n0.5\n-2\n-10025800\n4673300")
    check("rotation terms produce a non-axis-aligned transform", (rotated?.mapTransform(imageWidth: 100, imageHeight: 100).c ?? 0) != 0)
    check("fewer than six numbers is not a world file", WorldFile(text: "1\n2\n3") == nil)

    let candidates = [URL(fileURLWithPath: "/tmp/fisk_1944.jgw"), URL(fileURLWithPath: "/tmp/other.pgw")]
    check("world files pair with images by basename, case-insensitively",
          HistoricalMapImporter.worldFileURL(for: URL(fileURLWithPath: "/tmp/Fisk_1944.JPG"), among: candidates)?.lastPathComponent == "fisk_1944.jgw")

    let big = FileManager.default.temporaryDirectory.appendingPathComponent("historical-\(UUID().uuidString).png")
    let context = CGContext(data: nil, width: 4096, height: 100, bitsPerComponent: 8, bytesPerRow: 4096 * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.6, green: 0.5, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 4096, height: 100))
    _ = writePNG(context.makeImage()!, to: big.path)
    if let w = mercator, let imported = try? HistoricalMapImporter.importMap(imageURL: big, worldFile: w, fallbackRegion: makeGrid(width: 2, height: 2, gsd: 1).region) {
        check("huge scans decode at most 2048 px on the long side", max(imported.image.width, imported.image.height) <= 2048, "\(imported.image.width)x\(imported.image.height)")
        let fullWidthEdge = w.mapTransform(imageWidth: 4096, imageHeight: 100).applied(CGPoint(x: 4096, y: 0))
        let decodedEdge = imported.imageToMap.applied(CGPoint(x: imported.image.width, y: 0))
        check("downsampling rescales the transform so edges stay put", abs(fullWidthEdge.x - decodedEdge.x) < 1e-3)
    } else {
        check("historical image imports", false)
    }
    try? FileManager.default.removeItem(at: big)
}

extension CGAffineTransform {
    func applied(_ p: CGPoint) -> CGPoint { p.applying(self) }
}
```

- [x] **Step 2: Run** → Expected: compile error `cannot find 'WorldFile' in scope`.
- [x] **Step 3: Create `LidarExplorer/MapLayer/HistoricalMap.swift`**

```swift
//
//  HistoricalMap.swift
//  LidarExplorer
//
//  Georeferenced historical rasters: world files and memory-safe import.
//

import CoreGraphics
import Foundation
import ImageIO
import MapKit

/// An ESRI world file: `X = a·column + b·row + c`, `Y = d·column + e·row + f`,
/// evaluated at pixel centres. Line order in the file is a, d, b, e, c, f.
public nonisolated struct WorldFile: Sendable, Equatable {
    public enum Units: Sendable, Equatable { case degrees, webMercatorMeters }

    public let a: Double, d: Double, b: Double, e: Double, c: Double, f: Double

    public init?(text: String) {
        let values = text.split(whereSeparator: \.isNewline)
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count >= 6 else { return nil }
        (a, d, b, e, c, f) = (values[0], values[1], values[2], values[3], values[4], values[5])
        guard a != 0 || b != 0, e != 0 || d != 0 else { return nil }
    }

    /// Degree coefficients are tiny and the origin lies within ±180/±90.
    public var units: Units {
        abs(c) <= 180 && abs(f) <= 90 && abs(a) < 1 && abs(e) < 1 ? .degrees : .webMercatorMeters
    }

    public func mapPoint(column: Double, row: Double) -> MKMapPoint {
        let x = a * column + b * row + c
        let y = d * column + e * row + f
        switch units {
        case .degrees: return MKMapPoint(CLLocationCoordinate2D(latitude: y, longitude: x))
        case .webMercatorMeters: return MKMapPoint(GeoRegion.fromMercatorMeters(x: x, y: y))
        }
    }

    /// Image space (origin at the top-left pixel *edge*, y down) to map points,
    /// fitted through three corners. Exact for EPSG:3857; for degree files the
    /// Mercator nonlinearity across one sheet is far below a pixel.
    public func mapTransform(imageWidth w: Int, imageHeight h: Int) -> CGAffineTransform {
        let tl = mapPoint(column: -0.5, row: -0.5)
        let tr = mapPoint(column: Double(w) - 0.5, row: -0.5)
        let bl = mapPoint(column: -0.5, row: Double(h) - 0.5)
        return CGAffineTransform(a: (tr.x - tl.x) / Double(w), b: (tr.y - tl.y) / Double(w),
                                 c: (bl.x - tl.x) / Double(h), d: (bl.y - tl.y) / Double(h),
                                 tx: tl.x, ty: tl.y)
    }
}

public nonisolated enum HistoricalMapImporter {
    public static let maximumPixelDimension = 2048

    public struct Imported: @unchecked Sendable {
        public let name: String
        public let image: CGImage
        /// Decoded-image space to map points.
        public let imageToMap: CGAffineTransform
        public let boundingMapRect: MKMapRect
    }

    public enum ImportError: Error { case unreadableImage }

    private static let worldFileExtensions: Set<String> = ["pgw", "jgw", "tfw", "wld", "pngw", "jpgw", "tifw", "gfw"]

    public static func worldFileURL(for image: URL, among candidates: [URL]) -> URL? {
        let base = image.deletingPathExtension().lastPathComponent.lowercased()
        return candidates.first {
            $0.deletingPathExtension().lastPathComponent.lowercased() == base
                && worldFileExtensions.contains($0.pathExtension.lowercased())
        }
    }

    /// Decodes at most `maximumPixelDimension` on the long side via ImageIO
    /// thumbnailing (the full scan is never materialised) and rescales the
    /// placement to the decoded size. Without a world file the image is stretched
    /// over `fallbackRegion`.
    public static func importMap(imageURL: URL, worldFile: WorldFile?, fallbackRegion: GeoRegion) throws -> Imported {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let fullWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let fullHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
                  kCGImageSourceCreateThumbnailWithTransform: false,
              ] as CFDictionary)
        else { throw ImportError.unreadableImage }

        let fullToMap: CGAffineTransform
        if let worldFile {
            fullToMap = worldFile.mapTransform(imageWidth: fullWidth, imageHeight: fullHeight)
        } else {
            let tl = MKMapPoint(CLLocationCoordinate2D(latitude: fallbackRegion.maxLatitude, longitude: fallbackRegion.minLongitude))
            let br = MKMapPoint(CLLocationCoordinate2D(latitude: fallbackRegion.minLatitude, longitude: fallbackRegion.maxLongitude))
            fullToMap = CGAffineTransform(a: (br.x - tl.x) / Double(fullWidth), b: 0, c: 0,
                                          d: (br.y - tl.y) / Double(fullHeight), tx: tl.x, ty: tl.y)
        }
        let scale = CGAffineTransform(scaleX: Double(fullWidth) / Double(image.width),
                                      y: Double(fullHeight) / Double(image.height))
        let imageToMap = scale.concatenating(fullToMap)
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: image.width, y: 0),
                       CGPoint(x: 0, y: image.height), CGPoint(x: image.width, y: image.height)].map { $0.applying(imageToMap) }
        let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!
        let minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
        return Imported(name: imageURL.deletingPathExtension().lastPathComponent, image: image, imageToMap: imageToMap,
                        boundingMapRect: MKMapRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }
}
```

- [x] **Step 4: Run** → D1 checks PASS. **Step 5: Commit** — `feat(historical): world-file placement and memory-safe raster import`.

### Task D2: Historical overlay with opacity and split wipe

**Files:**
- Create: `LidarExplorer/MapLayer/HistoricalMapOverlay.swift`
- Modify: `LidarExplorer/Presentation/TerrainViewerModel.swift`, `LidarExplorer/MapLayer/TerrainMapView.swift`,
  `LidarExplorer/Presentation/TerrainViewerView.swift`, `LidarExplorer/Presentation/ViewerSettingsSheetView.swift`

- [x] **Step 1: Overlay + renderer**

```swift
//
//  HistoricalMapOverlay.swift
//  LidarExplorer
//

import CoreGraphics
import MapKit

public nonisolated final class HistoricalMapOverlay: NSObject, MKOverlay, @unchecked Sendable {
    public let imported: HistoricalMapImporter.Imported
    public var boundingMapRect: MKMapRect { imported.boundingMapRect }
    public var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: imported.boundingMapRect.midX, y: imported.boundingMapRect.midY).coordinate
    }

    public init(imported: HistoricalMapImporter.Imported) {
        self.imported = imported
    }
}

/// Draws the scan through its affine placement; west of `wipeMapX` only, when set.
public nonisolated final class HistoricalMapRenderer: MKOverlayRenderer {
    private let lock = NSLock()
    private var wipeMapX: Double?

    public func setWipe(mapX: Double?) {
        lock.withLock { wipeMapX = mapX }
        setNeedsDisplay()
    }

    public override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let historical = overlay as? HistoricalMapOverlay else { return }
        let image = historical.imported.image
        let wipe = lock.withLock { wipeMapX }
        context.saveGState()
        if let wipe {
            let b = historical.boundingMapRect
            context.clip(to: rect(for: MKMapRect(x: b.minX, y: b.minY, width: max(wipe - b.minX, 0), height: b.height)))
        }
        let origin = point(for: MKMapPoint(x: 0, y: 0))
        let unit = point(for: MKMapPoint(x: 1, y: 1))
        let mapToRenderer = CGAffineTransform(a: unit.x - origin.x, b: 0, c: 0, d: unit.y - origin.y, tx: origin.x, ty: origin.y)
        context.concatenate(historical.imported.imageToMap.concatenating(mapToRenderer))
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.restoreGState()
    }
}
```

- [x] **Step 2: Model** — add `case historicalWipe` to `InteractionMode` and:

```swift
    public private(set) var historicalMaps: [HistoricalMapOverlay] = []
    public var historicalOpacity: Double = 0.8
    public var historicalAboveTerrain = true
    /// 0...1 of the screen width drawn with the historical map; nil shows all of it.
    public var historicalWipeFraction: Double?

    public func importHistoricalMaps(from urls: [URL]) {
        let fallback = visibleGeoRegion
        let images = urls.filter { ["png", "jpg", "jpeg", "tif", "tiff"].contains($0.pathExtension.lowercased()) }
        Task {
            for url in images {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let worldURL = HistoricalMapImporter.worldFileURL(for: url, among: urls)
                let world = worldURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.flatMap(WorldFile.init(text:))
                if let imported = try? await Task.detached(priority: .userInitiated, operation: {
                    try HistoricalMapImporter.importMap(imageURL: url, worldFile: world, fallbackRegion: fallback)
                }).value {
                    historicalMaps.append(HistoricalMapOverlay(imported: imported))
                }
            }
        }
    }

    public func removeHistoricalMaps() { historicalMaps = []; historicalWipeFraction = nil }
```

- [x] **Step 3: Map view** — add inputs `historicalCount: Int` (`model.historicalMaps.count`), `historicalOpacity: Double`,
`historicalWipeFraction: Double?`, `historicalAboveTerrain: Bool` (pass from `TerrainViewerView`). In `Coordinator`
keep `private var historicalOverlays: [HistoricalMapOverlay] = []`; `syncHistorical(on:)` adds/removes overlays by
identity (`===`) at `.aboveLabels` when above terrain, else `map.insertOverlay(_:at: 1, level: .aboveRoads)`; sets
each renderer's `alpha`; and calls `applyWipe(on:)`:

```swift
        func applyWipe(on map: MKMapView) {
            let mapX = model.historicalWipeFraction.map { fraction in
                MKMapPoint(map.convert(CGPoint(x: map.bounds.width * fraction, y: map.bounds.midY), toCoordinateFrom: map)).x
            }
            for overlay in historicalOverlays {
                (map.renderer(for: overlay) as? HistoricalMapRenderer)?.setWipe(mapX: mapX)
            }
        }
```

Call `applyWipe(on:)` from `mapViewDidChangeVisibleRegion(_:)` too. In `rendererFor`, return
`HistoricalMapRenderer(overlay:)` for `HistoricalMapOverlay`. Add a two-finger wipe recognizer, active only in
`.historicalWipe` mode (disable `isRotateEnabled`/`isPitchEnabled` in that mode in `updateUIView`):

```swift
        let wipe = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleWipe(_:)))
        wipe.minimumNumberOfTouches = 2
        wipe.maximumNumberOfTouches = 2
        wipe.delegate = context.coordinator
        map.addGestureRecognizer(wipe)
```

```swift
        @objc func handleWipe(_ recognizer: UIPanGestureRecognizer) {
            guard model.interactionMode == .historicalWipe, let map = mapView else { return }
            let x = recognizer.location(in: map).x
            model.historicalWipeFraction = min(max(Double(x / max(map.bounds.width, 1)), 0), 1)
            applyWipe(on: map)
        }
```

(Update `gestureRecognizer(_:shouldReceive:)` to return `model.interactionMode == .historicalWipe` for that recognizer.)

- [x] **Step 4: SwiftUI** — in `TerrainViewerView` add `@State private var showsHistoricalImporter = false` and
`.fileImporter(isPresented: $showsHistoricalImporter, allowedContentTypes: [.image, .data], allowsMultipleSelection: true) { result in if case .success(let urls) = result { model.importHistoricalMaps(from: urls) } }`;
when `model.historicalWipeFraction != nil`, overlay the map with a `GeometryReader` drawing a 2 pt white line at
`fraction × width` and a 28 pt draggable circle whose `DragGesture` sets the fraction. In settings add a
"Historical Maps" section: "Import Map…" (dismiss, then set `showsHistoricalImporter` through a binding),
opacity slider, "Above terrain" toggle, "Split Wipe" toggle (`historicalWipeFraction = on ? 0.5 : nil`), "Remove All".

- [x] **Step 5: Verify** — `xcodebuild`; Simulator: import a PNG + `.pgw` over Cahokia, fade opacity, wipe with the
handle and with two fingers (map must not rotate/tilt in wipe mode).
- [x] **Step 6: Commit** — `feat(historical): georeferenced map overlay with opacity and split wipe`.

### Task D3: SSURGO map units, classification and polygon geometry (pure)

**Files:**
- Create: `LidarExplorer/Domain/SoilSurvey.swift` (add to `Tools/run-harness.sh` and `Tools/run-live-check.sh`)
- Test: `Tools/ViewerHarness/HistoricalAndSoilChecks.swift`

Classification rules (documented in code): texture = longest textural phrase in the map-unit name before its first
comma; **hydric** = `hydclprs ≥ 66` or drainage "poorly drained"/"very poorly drained"; **hydric clay** = hydric and a
clayey texture (clay, silty clay, sandy clay, silty clay loam, clay loam) → backswamps and oxbow plugs;
**well-drained sandy loam** = not hydric, a sandy texture, and drainage well / moderately well / somewhat
excessively / excessively drained → natural levees and point bars; everything else **other**.

- [x] **Step 1: Failing checks**

```swift
@MainActor
func checkSoilModel() {
    print("\n--- D3. soil model ---")
    func unit(_ name: String, _ drainage: String?, _ hydric: Int?) -> SoilClass {
        SoilMapUnit(mukey: "1", name: name, drainageClass: drainage, hydricPercent: hydric).soilClass
    }
    check("Sharkey clay, very poorly drained → hydric clay",
          unit("Sharkey clay, 0 to 1 percent slopes, frequently flooded", "Very poorly drained", 95) == .hydricClay)
    check("Tunica silty clay at 80% hydric → hydric clay", unit("Tunica silty clay, 0 to 1 percent slopes", "Poorly drained", 80) == .hydricClay)
    check("Bosket very fine sandy loam, well drained → sandy levee",
          unit("Bosket very fine sandy loam, 1 to 3 percent slopes", "Well drained", 0) == .wellDrainedSandyLoam)
    check("Crevasse loamy sand, excessively drained → sandy levee", unit("Crevasse loamy sand", "Excessively drained", nil) == .wellDrainedSandyLoam)
    check("somewhat poorly drained silt loam → other", unit("Commerce silt loam, 0 to 1 percent slopes", "Somewhat poorly drained", 30) == .other)
    check("texture is the longest phrase before the comma", SoilClassifier.texture(inName: "Commerce silty clay loam, occasionally flooded") == "silty clay loam")

    let square = "POLYGON ((-90.1 38.6, -90.0 38.6, -90.0 38.7, -90.1 38.7, -90.1 38.6), (-90.06 38.64, -90.04 38.64, -90.04 38.66, -90.06 38.66, -90.06 38.64))"
    let parsed = WKTPolygonParser.polygons(square)
    check("WKT POLYGON parses its exterior and hole", parsed?.count == 1 && parsed?.first?.count == 2 && parsed?.first?.first?.count == 5)
    let multi = WKTPolygonParser.polygons("MULTIPOLYGON (((0 0, 1 0, 1 1, 0 0)), ((2 2, 3 2, 3 3, 2 2)))")
    check("WKT MULTIPOLYGON parses every part", multi?.count == 2)
    check("non-polygon WKT is rejected", WKTPolygonParser.polygons("POINT (1 2)") == nil)

    if let parts = parsed, let polygon = SoilPolygon(unit: SoilMapUnit(mukey: "9", name: "Sharkey clay", drainageClass: "Poorly drained", hydricPercent: 90), parts: parts) {
        check("a point in the ring is inside", polygon.contains(CLLocationCoordinate2D(latitude: 38.62, longitude: -90.08)))
        check("a point in the hole is outside", !polygon.contains(CLLocationCoordinate2D(latitude: 38.65, longitude: -90.05)))
        let survey = SoilSurvey(polygons: [polygon])
        check("the survey answers the map unit under a coordinate", survey.unit(at: CLLocationCoordinate2D(latitude: 38.62, longitude: -90.08))?.mukey == "9")
    }

    let geojson = """
    {"type":"FeatureCollection","features":[{"type":"Feature","properties":{"mukey":"123","muname":"Bosket fine sandy loam","drclassdcd":"Well drained","hydclprs":0},
     "geometry":{"type":"Polygon","coordinates":[[[-90.1,38.6],[-90.0,38.6],[-90.0,38.7],[-90.1,38.6]]]}}]}
    """
    let features = (try? SoilGeoJSON.polygons(from: Data(geojson.utf8))) ?? []
    check("GeoJSON features parse with their SSURGO attributes",
          features.count == 1 && features[0].unit.mukey == "123" && features[0].unit.soilClass == .wellDrainedSandyLoam)
}
```

- [x] **Step 2: Run** → Expected: compile error `cannot find 'SoilMapUnit' in scope`.
- [x] **Step 3: Create `LidarExplorer/Domain/SoilSurvey.swift`**

```swift
//
//  SoilSurvey.swift
//  LidarExplorer
//
//  SSURGO map units, their geomorphic classification, and polygon geometry.
//

import CoreLocation
import Foundation
import simd

public nonisolated enum SoilClass: String, Sendable, CaseIterable {
    /// Poorly drained clays: backswamps, oxbow and clay plugs.
    case hydricClay
    /// Well-drained sands and sandy loams: natural levees, point bars.
    case wellDrainedSandyLoam
    case other
}

public nonisolated struct SoilMapUnit: Sendable, Equatable, Hashable {
    public let mukey: String
    public let name: String
    public let drainageClass: String?
    public let hydricPercent: Int?

    public init(mukey: String, name: String, drainageClass: String?, hydricPercent: Int?) {
        self.mukey = mukey
        self.name = name
        self.drainageClass = drainageClass
        self.hydricPercent = hydricPercent
    }

    public var soilClass: SoilClass {
        SoilClassifier.classify(name: name, drainageClass: drainageClass, hydricPercent: hydricPercent)
    }
}

public nonisolated enum SoilClassifier {
    static let textures = [
        "loamy very fine sand", "very fine sandy loam", "silty clay loam", "sandy clay loam", "loamy fine sand",
        "fine sandy loam", "silty clay", "sandy clay", "loamy sand", "sandy loam", "clay loam", "fine sand",
        "silt loam", "clay", "loam", "sand",
    ].sorted { $0.count > $1.count }
    static let clayey: Set<String> = ["clay", "silty clay", "sandy clay", "silty clay loam", "clay loam"]
    static let wellDrained: Set<String> = ["well drained", "moderately well drained", "somewhat excessively drained", "excessively drained"]
    static let poorlyDrained: Set<String> = ["poorly drained", "very poorly drained"]

    public static func texture(inName name: String) -> String? {
        let head = name.lowercased().split(separator: ",").first.map(String.init) ?? ""
        return textures.first { head.contains($0) }
    }

    public static func classify(name: String, drainageClass: String?, hydricPercent: Int?) -> SoilClass {
        let texture = texture(inName: name)
        let drainage = drainageClass?.lowercased()
        let hydric = (hydricPercent ?? 0) >= 66 || (drainage.map { poorlyDrained.contains($0) } ?? false)
        if hydric, let texture, clayey.contains(texture) { return .hydricClay }
        if !hydric, let texture, texture.contains("sand"), let drainage, wellDrained.contains(drainage) {
            return .wellDrainedSandyLoam
        }
        return .other
    }
}

/// One map unit's geometry: polygons as rings of (longitude, latitude), exterior first.
public nonisolated struct SoilPolygon: Sendable {
    public let unit: SoilMapUnit
    public let parts: [[[SIMD2<Double>]]]
    public let bounds: GeoRegion

    public init?(unit: SoilMapUnit, parts: [[[SIMD2<Double>]]]) {
        let points = parts.flatMap { $0.flatMap { $0 } }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        self.unit = unit
        self.parts = parts
        self.bounds = GeoRegion(minLatitude: minY, maxLatitude: maxY, minLongitude: minX, maxLongitude: maxX)
    }

    public func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard bounds.contains(coordinate) else { return false }
        let p = SIMD2(coordinate.longitude, coordinate.latitude)
        for polygon in parts {
            guard let exterior = polygon.first, Self.ringContains(exterior, p) else { continue }
            if !polygon.dropFirst().contains(where: { Self.ringContains($0, p) }) { return true }
        }
        return false
    }

    /// Even-odd ray casting.
    static func ringContains(_ ring: [SIMD2<Double>], _ p: SIMD2<Double>) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}

public nonisolated struct SoilSurvey: Sendable {
    public let polygons: [SoilPolygon]

    public init(polygons: [SoilPolygon]) {
        self.polygons = polygons
    }

    public func polygons(intersecting region: GeoRegion) -> [SoilPolygon] {
        polygons.filter {
            $0.bounds.minLatitude <= region.maxLatitude && $0.bounds.maxLatitude >= region.minLatitude
                && $0.bounds.minLongitude <= region.maxLongitude && $0.bounds.maxLongitude >= region.minLongitude
        }
    }

    public func unit(at coordinate: CLLocationCoordinate2D) -> SoilMapUnit? {
        polygons.first { $0.contains(coordinate) }?.unit
    }
}

public nonisolated enum WKTPolygonParser {
    /// `POLYGON` / `MULTIPOLYGON` text as polygons of rings of (x, y) = (longitude, latitude). Nil for other types.
    public static func polygons(_ wkt: String) -> [[[SIMD2<Double>]]]? {
        let text = wkt.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = text.uppercased()
        let isMulti = upper.hasPrefix("MULTIPOLYGON")
        guard isMulti || upper.hasPrefix("POLYGON"), let open = text.firstIndex(of: "(") else { return nil }
        let ringDepth = isMulti ? 3 : 2
        var polygons: [[[SIMD2<Double>]]] = []
        var rings: [[SIMD2<Double>]] = []
        var ring: [SIMD2<Double>] = []
        var pair: [Double] = []
        var number = ""
        var depth = 0

        func flushNumber() {
            if let v = Double(number) { pair.append(v) }
            number = ""
        }
        func flushPair() {
            flushNumber()
            if pair.count >= 2 { ring.append(SIMD2(pair[0], pair[1])) }
            pair = []
        }

        for character in text[open...] {
            switch character {
            case "(":
                depth += 1
            case ")":
                if depth == ringDepth {
                    flushPair()
                    if ring.count >= 4 { rings.append(ring) }
                    ring = []
                } else if depth == ringDepth - 1 {
                    if !rings.isEmpty { polygons.append(rings) }
                    rings = []
                }
                depth -= 1
            case ",":
                if depth == ringDepth { flushPair() }
            case " ", "\t", "\n", "\r":
                if depth == ringDepth { flushNumber() }
            default:
                if depth == ringDepth { number.append(character) }
            }
        }
        return polygons.isEmpty ? nil : polygons
    }
}

public nonisolated enum SoilGeoJSON {
    public enum ParseError: Error { case notAFeatureCollection }

    /// Features carrying `mukey`, `muname`, `drclassdcd`, `hydclprs` with Polygon or MultiPolygon geometry.
    public static func polygons(from data: Data) throws -> [SoilPolygon] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]]
        else { throw ParseError.notAFeatureCollection }

        func ring(_ any: Any) -> [SIMD2<Double>]? {
            (any as? [[Double]])?.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
        }
        return features.compactMap { feature -> SoilPolygon? in
            guard let properties = feature["properties"] as? [String: Any],
                  let geometry = feature["geometry"] as? [String: Any],
                  let type = geometry["type"] as? String,
                  let coordinates = geometry["coordinates"] as? [Any]
            else { return nil }
            let hydric = (properties["hydclprs"] as? NSNumber)?.intValue ?? (properties["hydclprs"] as? String).flatMap { Int($0) }
            let unit = SoilMapUnit(
                mukey: (properties["mukey"] as? String) ?? (properties["mukey"] as? NSNumber)?.stringValue ?? "",
                name: properties["muname"] as? String ?? "",
                drainageClass: properties["drclassdcd"] as? String,
                hydricPercent: hydric
            )
            switch type {
            case "Polygon":
                return SoilPolygon(unit: unit, parts: [coordinates.compactMap(ring)])
            case "MultiPolygon":
                return SoilPolygon(unit: unit, parts: coordinates.map { (($0 as? [Any]) ?? []).compactMap(ring) }.filter { !$0.isEmpty })
            default:
                return nil
            }
        }
    }
}
```

- [x] **Step 4: Run** → D3 checks PASS. **Step 5: Commit** — `feat(soils): SSURGO map-unit classification, WKT/GeoJSON geometry and lookup`.

### Task D4: Soil Data Access client with an on-disk SSURGO cache

Verified against the live service on 2026-09-12: `POST https://sdmdataaccess.sc.egov.usda.gov/Tabular/post.rest`
with `{"query": …, "format": "JSON+COLUMNNAME"}` answers in ~0.3 s **when the area lookup goes through
`SDA_Get_Mupolygonkey_from_intersection_with_WktWgs84`**; a direct `mupolygongeo.STIntersects(...)` scan timed out
at 60 s. The response is `{"Table": [[column names], [row values…]]}` with every value as a string (`hydclprs` =
`"90"`); an empty result is `{}`. At Cahokia it returns "Darwin silty clay … Poorly drained, 90" and "Dupo silt loam …
Somewhat poorly drained, 10".

**Files:**
- Create: `LidarExplorer/Services/Soils/SoilDataAccessClient.swift` (add to both scripts)
- Test: `Tools/ViewerHarness/HistoricalAndSoilChecks.swift` (offline), `Tools/LiveCheck/main.swift` (live)

- [x] **Step 1: Failing offline checks**

```swift
@MainActor
func checkSoilDataAccessParsing() async {
    print("\n--- D4. Soil Data Access ---")
    let fixture = """
    {"Table":[["mukey","muname","drclassdcd","hydclprs","wkt"],
    ["198881","Darwin silty clay, 0 to 2 percent slopes, occasionally flooded, long duration","Poorly drained","90","POLYGON ((-90.0575 38.6585, -90.0601 38.6586, -90.0607 38.6601, -90.0575 38.6585))"],
    ["198883","Dupo silt loam, 0 to 2 percent slopes, occasionally flooded","Somewhat poorly drained","10","POLYGON ((-90.0471 38.6698, -90.0483 38.6702, -90.0489 38.6712, -90.0471 38.6698))"]]}
    """
    let survey = SoilDataAccessClient.parse(Data(fixture.utf8))
    check("SDA rows parse into classified polygons",
          survey?.polygons.map(\.unit.soilClass) == [.hydricClay, .other], "\(String(describing: survey?.polygons.map(\.unit.soilClass)))")
    check("string-typed hydric percentages are read", survey?.polygons.first?.unit.hydricPercent == 90)
    check("an empty SDA result is an empty survey, not a failure", SoilDataAccessClient.parse(Data("{}".utf8))?.polygons.isEmpty == true)
    let cell = SoilDataAccessClient.queryCell(for: GeoRegion(minLatitude: 38.659, maxLatitude: 38.662, minLongitude: -90.064, maxLongitude: -90.060))
    let query = SoilDataAccessClient.query(for: cell)
    check("queries use the indexed intersection helper", query.contains("SDA_Get_Mupolygonkey_from_intersection_with_WktWgs84"))
    check("queries snap to a 0.01 degree cell", abs(cell.minLatitude - 38.65) < 1e-9 && abs(cell.maxLongitude + 90.06) < 1e-9, "\(cell)")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ssurgo-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? Data(fixture.utf8).write(to: directory.appendingPathComponent(SoilDataAccessClient.cacheKey(cell) + ".json"))
    let offline = SoilDataAccessClient(transport: HTTPTransport(session: URLSession(configuration: .ephemeral)), directory: directory,
                                       endpoint: URL(string: "https://invalid.invalid/post.rest")!)
    let cached = await offline.survey(covering: GeoRegion(minLatitude: 38.659, maxLatitude: 38.662, minLongitude: -90.064, maxLongitude: -90.060))
    check("a cached cell is served from disk without the network", cached?.polygons.count == 2)
    try? FileManager.default.removeItem(at: directory)
}
```

- [x] **Step 2: Run** → Expected: compile error `cannot find 'SoilDataAccessClient' in scope`.
- [x] **Step 3: Create `LidarExplorer/Services/Soils/SoilDataAccessClient.swift`**

```swift
//
//  SoilDataAccessClient.swift
//  LidarExplorer
//
//  USDA Soil Data Access (SSURGO) map-unit polygons for an area, cached on disk.
//

import Foundation
import os

public actor SoilDataAccessClient {

    public static let shared = SoilDataAccessClient()
    public nonisolated static let defaultEndpoint = URL(string: "https://sdmdataaccess.sc.egov.usda.gov/Tabular/post.rest")!
    private nonisolated static let cellDegrees = 0.01

    private let transport: HTTPTransport
    private let directory: URL
    private let endpoint: URL
    private var memory: [String: SoilSurvey] = [:]
    private var inFlight: [String: Task<SoilSurvey?, Never>] = [:]

    public init(transport: HTTPTransport? = nil, directory: URL? = nil, endpoint: URL = SoilDataAccessClient.defaultEndpoint) {
        let patient = URLSessionConfiguration.default
        patient.timeoutIntervalForRequest = 90
        patient.timeoutIntervalForResource = 120
        self.transport = transport ?? HTTPTransport(session: URLSession(configuration: patient))
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? caches.appendingPathComponent("SSURGO", isDirectory: true)
        self.endpoint = endpoint
    }

    /// Map-unit polygons intersecting `region`'s 0.01° cell: memory, then disk, then SDA.
    public func survey(covering region: GeoRegion) async -> SoilSurvey? {
        let cell = Self.queryCell(for: region)
        let key = Self.cacheKey(cell)
        if let cached = memory[key] { return cached }
        if let running = inFlight[key] { return await running.value }
        let task = Task { [transport, directory, endpoint] in
            await Self.load(cell: cell, key: key, transport: transport, directory: directory, endpoint: endpoint)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result { memory[key] = result }
        return result
    }

    nonisolated static func queryCell(for region: GeoRegion) -> GeoRegion {
        let s = cellDegrees
        return GeoRegion(
            minLatitude: (region.minLatitude / s).rounded(.down) * s, maxLatitude: (region.maxLatitude / s).rounded(.up) * s,
            minLongitude: (region.minLongitude / s).rounded(.down) * s, maxLongitude: (region.maxLongitude / s).rounded(.up) * s
        )
    }

    nonisolated static func cacheKey(_ cell: GeoRegion) -> String {
        let parts = [cell.minLatitude, cell.minLongitude, cell.maxLatitude, cell.maxLongitude].map { Int(($0 * 100).rounded()) }
        return "ssurgo_" + parts.map(String.init).joined(separator: "_")
    }

    /// The indexed intersection helper keeps this sub-second; a direct geometry scan times out.
    nonisolated static func query(for cell: GeoRegion) -> String {
        let ring = [
            (cell.minLongitude, cell.minLatitude), (cell.maxLongitude, cell.minLatitude),
            (cell.maxLongitude, cell.maxLatitude), (cell.minLongitude, cell.maxLatitude), (cell.minLongitude, cell.minLatitude),
        ].map { "\($0.0) \($0.1)" }.joined(separator: ", ")
        return "SELECT P.mukey, M.muname, A.drclassdcd, A.hydclprs, P.mupolygongeo.STAsText() AS wkt "
            + "FROM mupolygon AS P INNER JOIN mapunit AS M ON M.mukey = P.mukey "
            + "LEFT OUTER JOIN muaggatt AS A ON A.mukey = P.mukey "
            + "WHERE P.mupolygonkey IN (SELECT * FROM SDA_Get_Mupolygonkey_from_intersection_with_WktWgs84('POLYGON((\(ring)))'))"
    }

    /// Parses `JSON+COLUMNNAME` (`{"Table": [[names], [values…]]}`, all values strings; `{}` when empty).
    nonisolated static func parse(_ data: Data) -> SoilSurvey? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let table = root["Table"] as? [[Any]], let header = table.first as? [String] else {
            return root.isEmpty ? SoilSurvey(polygons: []) : nil
        }
        guard let mukey = header.firstIndex(of: "mukey"), let muname = header.firstIndex(of: "muname"),
              let drainage = header.firstIndex(of: "drclassdcd"), let hydric = header.firstIndex(of: "hydclprs"),
              let wkt = header.firstIndex(of: "wkt")
        else { return nil }
        let polygons = table.dropFirst().compactMap { row -> SoilPolygon? in
            guard row.count == header.count, let text = row[wkt] as? String, let parts = WKTPolygonParser.polygons(text) else { return nil }
            let unit = SoilMapUnit(mukey: "\(row[mukey])", name: row[muname] as? String ?? "",
                                   drainageClass: row[drainage] as? String,
                                   hydricPercent: (row[hydric] as? String).flatMap { Int($0) })
            return SoilPolygon(unit: unit, parts: parts)
        }
        return SoilSurvey(polygons: polygons)
    }

    private nonisolated static func load(
        cell: GeoRegion, key: String, transport: HTTPTransport, directory: URL, endpoint: URL
    ) async -> SoilSurvey? {
        let file = directory.appendingPathComponent(key + ".json")
        if let data = try? Data(contentsOf: file), let survey = parse(data) { return survey }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query(for: cell), "format": "JSON+COLUMNNAME"])
        switch await transport.data(for: request) {
        case .failure(let error):
            Log.network.error("SDA query failed: \(error.description, privacy: .public)")
            return nil
        case .success(let data):
            guard let survey = parse(data) else { return nil }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return survey
        }
    }
}
```

- [x] **Step 4: Live check** — add to `Tools/LiveCheck/main.swift` and call after `runCoordinatorCheck()`:

```swift
@MainActor
func runSoilCheck() async {
    print("\n=== SSURGO (live Soil Data Access) ===")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ssurgo-live-\(UUID().uuidString)")
    let client = SoilDataAccessClient(directory: directory)
    let started = Date()
    let survey = await client.survey(covering: GeoRegion(minLatitude: 38.659, maxLatitude: 38.662, minLongitude: -90.064, maxLongitude: -90.060))
    print(String(format: "        SDA answered in %.2f s with %d polygons", Date().timeIntervalSince(started), survey?.polygons.count ?? -1))
    check("SDA returns map-unit polygons over Cahokia", (survey?.polygons.count ?? 0) > 0)
    check("Cahokia's backswamp clays classify as hydric clay", survey?.polygons.contains { $0.unit.soilClass == .hydricClay } == true)
    try? FileManager.default.removeItem(at: directory)
}
```

- [x] **Step 5: Run** harness (D4 PASS) and `./Tools/run-live-check.sh` (soil checks PASS).
- [x] **Step 6: Commit** — `feat(soils): Soil Data Access client with indexed area lookup and disk cache`.

### Task D5: Hatched soil overlay, legend and spot readout

**Files:**
- Create: `LidarExplorer/MapLayer/SoilHatchOverlay.swift`
- Modify: `LidarExplorer/Presentation/TerrainViewerModel.swift`, `LidarExplorer/MapLayer/TerrainMapView.swift`,
  `LidarExplorer/Presentation/ViewerSettingsSheetView.swift`, `LidarExplorer/Presentation/SpotInspectionCalloutView.swift`

- [x] **Step 1: Overlay and renderer** (no custom renderer initializer: MapKit renderer subclasses must keep the
inherited `init(overlay:)` path — see the comment on `TerrainTileOverlayRenderer`)

```swift
//
//  SoilHatchOverlay.swift
//  LidarExplorer
//
//  SSURGO classes drawn as hatching: hydric clays diagonal blue, sandy levees cross-hatched tan.
//

import MapKit
import UIKit

public final class SoilMultiPolygon: MKMultiPolygon {
    public var soilClass: SoilClass = .other
}

public enum SoilOverlayFactory {
    /// One multipolygon per mapped class; `.other` is not drawn.
    public static func overlays(from survey: SoilSurvey) -> [SoilMultiPolygon] {
        var grouped: [SoilClass: [MKPolygon]] = [:]
        for polygon in survey.polygons where polygon.unit.soilClass != .other {
            for part in polygon.parts {
                guard let exterior = part.first else { continue }
                let holes = part.dropFirst().map { ring in
                    MKPolygon(coordinates: ring.map { CLLocationCoordinate2D(latitude: $0.y, longitude: $0.x) }, count: ring.count)
                }
                let shape = MKPolygon(coordinates: exterior.map { CLLocationCoordinate2D(latitude: $0.y, longitude: $0.x) },
                                      count: exterior.count, interiorPolygons: Array(holes))
                grouped[polygon.unit.soilClass, default: []].append(shape)
            }
        }
        return grouped.map { soilClass, polygons in
            let multi = SoilMultiPolygon(polygons)
            multi.soilClass = soilClass
            return multi
        }
    }
}

public nonisolated final class SoilHatchRenderer: MKMultiPolygonRenderer {
    public override func fillPath(_ path: CGPath, in context: CGContext) {
        let soilClass = (overlay as? SoilMultiPolygon)?.soilClass ?? .other
        let crosshatch = soilClass == .wellDrainedSandyLoam
        let color = crosshatch ? UIColor(red: 0.78, green: 0.58, blue: 0.28, alpha: 0.85) : UIColor(red: 0.16, green: 0.42, blue: 0.86, alpha: 0.85)
        context.saveGState()
        context.addPath(path)
        context.clip(using: .evenOdd)
        let bounds = path.boundingBoxOfPath
        let spacing = abs(context.convertToUserSpace(CGSize(width: 9, height: 9)).width)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(abs(context.convertToUserSpace(CGSize(width: 1.2, height: 1.2)).width))
        var offset = -bounds.height
        while offset < bounds.width + bounds.height {
            context.move(to: CGPoint(x: bounds.minX + offset, y: bounds.minY))
            context.addLine(to: CGPoint(x: bounds.minX + offset + bounds.height, y: bounds.maxY))
            if crosshatch {
                context.move(to: CGPoint(x: bounds.minX + offset + bounds.height, y: bounds.minY))
                context.addLine(to: CGPoint(x: bounds.minX + offset, y: bounds.maxY))
            }
            offset += spacing * (crosshatch ? 1.6 : 1)
        }
        context.strokePath()
        context.restoreGState()
    }
}
```

- [x] **Step 2: Model**

```swift
    public var showsSoils = false { didSet { if showsSoils { loadSoils() } else { soilSurvey = nil; soilVersion &+= 1 } } }
    public private(set) var soilSurvey: SoilSurvey?
    public private(set) var soilVersion = 0

    public func loadSoils() {
        let region = visibleGeoRegion
        Task {
            let survey = await SoilDataAccessClient.shared.survey(covering: region)
            guard self.showsSoils else { return }
            self.soilSurvey = survey
            self.soilVersion &+= 1
        }
    }

    public func importSoilGeoJSON(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let polygons = try? SoilGeoJSON.polygons(from: data) else { return }
        soilSurvey = SoilSurvey(polygons: polygons)
        showsSoils = true
        soilVersion &+= 1
    }

    public func soilUnit(at coordinate: CLLocationCoordinate2D) -> SoilMapUnit? { soilSurvey?.unit(at: coordinate) }
```

Call `if showsSoils { loadSoils() }` from the existing region-change debounce (next to `refreshElevationRange()`).

- [x] **Step 3: Map view** — input `soilVersion: Int` (from `model.soilVersion`); `Coordinator` keeps
`private var soilOverlays: [SoilMultiPolygon] = []` and `private var drawnSoilVersion = -1`; `syncSoils(on:)` replaces
them when the version changes (`map.addOverlay(_, level: .aboveRoads)`, using
`SoilOverlayFactory.overlays(from: model.soilSurvey)` when present); in `rendererFor`:
`if let soil = overlay as? SoilMultiPolygon { return SoilHatchRenderer(multiPolygon: soil) }`.
- [x] **Step 4: Settings + callout** — "Soils (SSURGO)" section: `Toggle("Show Soil Hatching", isOn: $model.showsSoils)`,
a legend (diagonal blue = hydric clay: backswamps, clay plugs; cross-hatched tan = well-drained sandy loam: levees),
and "Import GeoJSON…". In `SpotInspectionCalloutView`, under the slope/aspect row:
`if let unit = model.soilUnit(at: spot.coordinate) { Text("\(unit.name) · \(unit.drainageClass ?? "—")").font(.caption2).foregroundStyle(.secondary).lineLimit(2) }`.
- [x] **Step 5: Verify** — `xcodebuild`; Simulator over Cahokia: hatching appears in the American Bottom backswamps,
panning loads new cells without main-thread hangs (Instruments Hangs template if in doubt); tapping shows the map unit.
- [x] **Step 6: Commit** — `feat(soils): hatched SSURGO overlay with legend and spot readout`.

---

## Part E — Phase 7: verification, profiling, ship

### Task E1: Release build under strict concurrency

- [x] **Step 1: Build**
```bash
xcodebuild -project LidarExplorer.xcodeproj -scheme LidarExplorer -destination "generic/platform=iOS" -configuration Release SWIFT_STRICT_CONCURRENCY=complete CODE_SIGNING_ALLOWED=NO build
```
Expected: `** BUILD SUCCEEDED **`.
- [x] **Step 2: List warnings introduced by the branch** — pipe the build log through `grep "warning:" | grep -E "MetalTerrainPipelineActor|MicroTopography|ElevationTileCoordinator|ElevationTransect|AnalysisRasterBuilder|MercatorMosaicBuilder|ThalwegBuilder|ViewshedOverlay|TerrainTileOverlay|TerrainMapView|TerrainViewerModel|ElevationProfileView|ViewerSettingsSheetView|ViewerTopBarView|ViewerBottomDockView" | sort -u` and fix each (known candidate: `UITouch.TouchType.stylus` is a deprecated alias of `.pencil`).
- [x] **Step 3: Record** the result in `STATUS.md`.

### Task E2: Simulator smoke run (blit surface path)

- [x] **Step 1: Build for the Simulator** (Background command) with `-derivedDataPath build/DerivedData`.
- [x] **Step 2: Install and launch**
```bash
xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/LidarExplorer.app
```
```bash
xcrun simctl launch booted com.detsom.LidarExplorer
```
- [x] **Step 3: Confirm the pipeline chose blit surfaces**
```bash
xcrun simctl spawn booted log show --last 2m --predicate 'subsystem == "com.detsom.LidarExplorer" AND category == "Shader"'
```
Expected: `Micro-topography pipeline ready (blit surfaces).`
- [x] **Step 4: Walk the tools** — Explore sites → Cahokia; for LRM, RRIM, Sky-View, Raking Light, REM: capture
`xcrun simctl io booted screenshot build/screens/<style>.png`; then a transect across Monks Mound (panel resized,
Slope metric), a viewshed with the pin dragged, habitation mask on. Attach the screenshots to `STATUS.md`.

### Task E3: On-device Metal System Trace and memory

Requires the iPad (`iGonk Pro M5`, UDID `00008142-001604881E2B801C`) unlocked and a signing team. If either blocks,
write the exact step to `/Users/herren/dev/HUMAN_DO_THIS.md` and continue with E4.

> **Status (2026-09-19): open, deferred.** Step 1 is done. Steps 2–4 have not been run: `build/MicroTopography.trace`
> does not exist and `STATUS.md` records no frame-interval or memory result. The 2026-09-09 capture described in
> `HUMAN_DO_THIS.md` (25 s, launch only) recorded GPU activity counts and zero command-buffer errors, not these gates.
> The trace cannot be run at present; it is E3 in `STATUS.md` Part E.

- [x] **Step 1: Build, install**
```bash
xcodebuild -project LidarExplorer.xcodeproj -scheme LidarExplorer -destination 'platform=iOS,name=iGonk Pro M5' -configuration Release -allowProvisioningUpdates -derivedDataPath build/DerivedData build
```
```bash
xcrun devicectl device install app --device 00008142-001604881E2B801C build/DerivedData/Build/Products/Release-iphoneos/LidarExplorer.app
```
- [ ] **Step 2: Record 60 s while panning in LRM with contours, sweeping raking azimuth, dragging a transect**
```bash
xcrun xctrace record --template "Metal System Trace" --device "iGonk Pro M5" --output ./build/MicroTopography.trace --time-limit 60s --launch -- com.detsom.LidarExplorer
```
- [ ] **Step 3: Verify gates** — `xcrun xctrace export --input build/MicroTopography.trace --toc`; in Instruments:
zero command-buffer errors, no CPU thread blocked on GPU completion, display frame intervals ≤ 8.3 ms (ProMotion)
or ≤ 16.7 ms during pan/sweep, `microTopography.*` command buffers < 8 ms.
- [ ] **Step 4: Memory** — repeat with `--template "Allocations"` while panning continuously for 60 s at z18–z20;
peak persistent + transient < 500 MB. Record both results in `STATUS.md`.

### Task E4: Close the open verification items

- [x] **Step 1: COG vs ImageServer on a square footprint** — in `Tools/LiveCheck/main.swift` `runCoordinatorCheck()`,
replace `region` with the z19 tile over Monks Mound:
```swift
    let region = TerrainTileOverlay.region(for: tilePath(lat: 38.66040, lon: -90.06205, z: 19))
```
and tighten the agreement check to `mean < 0.15`. Run `./Tools/run-live-check.sh`; if it fails, run the offset search
from the spec's findings (shift ±6 px, debiased) before changing `COGResampler`'s pixel-centre convention.
- [x] **Step 2: GPU timing sanity** — in `checkBudget` (`MicroTopographyChecks.swift`) wrap one `.rakingLight`
render in `Date()` wall-clock timing and print it beside `gpuMilliseconds`; record both in `STATUS.md`.

### Task E5: Commit and open the PR (with the user's go-ahead in Claude Code sessions)

- [x] **Step 1:** Harness, live check and `xcodebuild` all green; `STATUS.md` updated.
- [x] **Step 2: Commit code and tests**
```bash
git add LidarExplorer Tools
git commit -m "feat(micro-topography): GPU analysis engine, COG streaming, transects, viewshed and map integration"
```
- [x] **Step 3: Commit docs**
```bash
git add STATUS.md docs/superpowers
git commit -m "docs(micro-topography): spec, calibration, authoritative plan and status"
```
- [x] **Step 4: Push and open the PR**
```bash
git push -u origin feat/micro-topography-engine
```
```bash
gh pr create --base main --head feat/micro-topography-engine --title "Micro-topography & terrain analysis engine" --body-file docs/superpowers/plans/2026-09-12-micro-topography-engine.md
```

---

## Coverage check (brief → tasks)

| Brief | Tasks |
|---|---|
| §1 actors, Sendable, UMA zero-copy, GPU nodata | A2, A4, A5, B6 (zero-copy stitched storage), B7 (COG in the app) |
| §2A–G kernels | A1, A3; tile integration B2, B6, B9, C1 |
| §2E fwidth contours | A1; tiles via composite (B6 output scale) |
| §3A transect engine + UI | A6, B1, B4, C3 |
| §3B viewshed | A3, B3, C4 |
| §4.1–4.2 compositor + habitation overlay | A1, C1 |
| §4.3 historical maps | D1, D2 |
| §4.4 SSURGO | D3, D4, D5 |
| §5.1 FPS, §5.4 Instruments | E3 |
| §5.2 < 8 ms | A2 (verified), B6, C6 |
| §5.3 memory | A2 pool, B8, E3 step 4 |
