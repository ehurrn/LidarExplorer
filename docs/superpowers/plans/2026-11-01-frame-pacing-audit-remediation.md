# Frame-Pacing Audit Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Status (2026-11-01):** complete, executed inline in the session that wrote it, on branch
> `claude/frame-pacing-audit-2026-11-01`, stacked on `claude/magical-bardeen-pjwbyj` at bb8d767 (draft PR #58, which
> this plan leaves as it is), one commit per task from 63b914d (Task 2) to 4cfa839 (Task 11 and this record).
> Harness 1796 to 1869 PASS / 0 FAIL, ALL CHECKS PASSED; Debug and Release Simulator builds and the signed
> device Debug build: see Verification. The owner pasted an audit (2 blockers, 6 majors, 5 minors; "120 Hz ProMotion frame pacing,
> cartographic quality, interactive smoothness") with no words of their own. Every claim was located in the code at
> bb8d767 before any task was written; the verdicts are in the table below. Each task's code is written red-first in
> the session and recorded under "Where the code differs from this text" as it lands, so the task steps here name the
> check and the change rather than carrying the code twice.

**Goal:** Take the audit's confirmed findings out of the app: one raster plane per cached tile, a relight that reuses
the stitched raster and the sun-invariant base, overlay syncs that leave MapKit's renderers alone, a renderer that knows
its viewport from the first frame, a 3D drape with no bare tiles and a far clip that fits the mesh, Pencil taps that
answer at once, a dial detent that does not buzz on a tremor, a preview Max Slope that agrees with the settled one, a
glass shadow cast by the shape alone, and a lease pool with a byte ceiling.

**Architecture:** Nothing is restructured beyond `ElevationGrid`, which gains a storage class so one page-aligned
region serves the CPU readers and `makeBuffer(bytesNoCopy:)` alike (Task 9). Every other task is local: a comparison
before an overlay is replaced, a rect seeded at construction, a smoothing pass before a derivative, a cache of two
leases on `CachedTile`, two policy rules in `MapTouchPolicy`, a tracker struct beside `AzimuthDetents`, a modifier
order in `GlassSurface`, a byte count in a pool.

**Tech Stack:** Swift 6 (`-strict-concurrency=complete -default-isolation MainActor`, `NonisolatedNonsendingByDefault`,
`InferIsolatedConformances`), Metal, MapKit, SwiftUI. Verification: `Tools/run-harness.sh` (host-compiled; `HARNESS_ONLY=`
for a section) and the Simulator `xcodebuild` in `STATUS.md` for every UIKit/SwiftUI file.

---

## The audit's claims against bb8d767

| # | Claim | Verdict at bb8d767 | Task |
|---|---|---|---|
| B1 | A cached tile holds its raster twice: `grid.samples` on the heap plus `AlignedSamples` (the cache file's mapping for a disk tile; a `COGMappedStorage` copy at a network tile's second shade), both counted by `byteCount` | **Confirmed** in structure (`CachedTile`, `diskTile`, `alignedForShading`). Impact smaller than claimed: a disk tile's mapping is clean file-backed memory the kernel can drop, so only a re-shaded network tile holds two dirty planes; and 256 MB holds about 80 such tiles against about 35 on screen. The counter-proposal (unify the storage) is the right fix and is taken. | 9 |
| B2 | A sun step on a micro-topography blend re-stitches and re-runs every pass for every visible tile | **Confirmed**: `update(_:)` drops every bitmap on any settings change; `microPipelineImage` rebuilds the analysis raster and `renderComposite` encodes base and layer from scratch each time. The 3.2-6.3 ms per-tile figure is the audit's, not measured here. | 8 |
| M1 | `syncProfile`, `syncThalweg`, `syncMarkup` remove and re-add their polylines on every `updateUIView` | **Confirmed for the profile and the thalweg** (unconditional remove + add when a line is shown; `terrainVersion` changes with the azimuth, so it runs per dial step). **Stale for markup**: `syncMarkup` returns early unless `markupVersion` changed. | 2 |
| M2 | Before the first region change the renderer reports no visible tiles, so View in 3D and the exports right after launch read back nothing | **Confirmed**; it is the "last read-back hole" in STATUS's Known issues and item 3 of the handoff's queue. `visibleRect` is set only by `cullTiles(outsideVisible:)`. | 3 |
| M3a | 3D vertices sit at sample centres while UVs span the tile edges: a half-cell texture shift | **Wrong**: `activeGrid(covering:)` builds a node-registered grid whose edge samples lie on the region's edges, the mesh lattice spans sample 0 to width-1, and the composite is drawn over the same `grid.region`; the residual is half a composite texel (1/4096 of the view), not half a cell. | none |
| M3b | Bare grey (0.92) where neither the renderer nor the provider holds a bitmap | **Confirmed**; STATUS lists it and the handoff queues "shading on demand in `shadedComposite`". | 5 |
| M3c | `SCNCamera.zFar` is a fixed 100 km | **Confirmed**: `camera.zFar = 100_000`; the camera orbits at 1.4 to 7 times the mesh extent, so a view wider than about 14 km clips when zoomed out. | 5 |
| M4a | A profile tap waits 350-510 ms for MapKit's zoom recognizers, Pencil included | **Confirmed** (the code's own figures: 0.36 s, 0.52 s with a line shown). A Pencil exemption alone would bring back D5 for the Pencil, since MapKit's double-tap zoom receives Pencil taps too; the task pairs the exemption with keeping the Pencil out of that zoom while the profile tool is lit. | 6 |
| M4b | The dial's 1° deadband is under half a point on the small dial, so tremor re-shades at 20 Hz | **Stale**: `SunDialCommit.minimumTurn(forDiameter:)` scales the deadband by the sun's orbit (1.8° on the 56 pt dial), and `SunDialControl` passes its diameter. | none |
| M4c | `AzimuthDetents` ticks again on every re-entry of a window's edge | **Confirmed**: a tick is for arriving; leaving is silent; a tremor across the 1.5° edge ticks on each re-entry. | 6 |
| M5 | Preview Max Slope is the raw step-to-step difference; the settled analysis is smoothed | **Confirmed** (`ElevationProfile.init`, `TerrainViewerModel.profileSlope`). The direction varies: the model's own comment notes the 5 m preview reads under the half-metre analysis on long lines; on short lines the unsmoothed difference reads over. | 4 |
| M6a | `GlassSurface` shadows the whole content, so children cast halos | **Confirmed**; STATUS's UI polish follow-ups measured the halo under the 3D Done capsule. | 7 |
| M6b | `SynchronousBufferPool` has no byte cap and no purge | **Confirmed** (STATUS D7). | 7 |
| m1 | The Pencil ring's sun and the dock's ring ignore the map's heading | **Confirmed** (STATUS, finding 3 of the pre-device audit). | 10 |
| m2 | `lrmRobustTukey` off by default; sky-view multiply crushes floors | **Declined**: the Tukey default is a product choice the owner left as a Settings toggle (2abca21) with its device cost unmeasured; the composite multiplies by the sky-view factor itself, which is 0 only for a fully enclosed cell, and the look was tuned against reference imagery. Noted, not changed. | none |
| m3 | Terrarium z6-15 skirts are replicated, flattening Horn normals at the border | **Confirmed, deferred**: the fix needs the standard styles to take the stale-neighbour re-shade the micro products have, or a second fetch per tile; a follow-up of its own. | follow-up |
| m4 | Basemap overzoom crops and re-encodes on the CPU | **Declined** as the 2026-10-26 plan did: a custom basemap renderer is a feature of its own; the encode is a few ms off the main actor at z17+. | none |
| m5 | The notebook is rewritten whole on every save | **Confirmed, deferred** (STATUS's item D from the 2026-09-21 audit): saves already coalesce behind a window; a journal format with compaction is a change to user data, taken on its own. | follow-up |
| N6 | Run the on-device Metal System Trace (E3) | Owner only: `HUMAN_DO_THIS.md` "Open (deferred): E3". | HUMAN_DO_THIS |

## Verification constraints

- `./Tools/run-harness.sh` must end `ALL CHECKS PASSED` after every task; `HARNESS_ONLY=<codes>` while iterating.
- A Simulator build (the command in `STATUS.md`, Xcode-beta, `-derivedDataPath build-review/DerivedData`) after Tasks 2, 3,
  5, 6, 7 and 10, which touch UIKit or SwiftUI files, and at the end.
- A new check is written and seen red before its fix.
- One `agent-checkpoint:` commit per task, staged by file name (`HUMAN_DO_THIS.md` is never staged).

## File structure

- `LidarExplorer/MapLayer/OverlaySyncPolicy.swift` (new, host-compiled): whether a polyline's coordinates changed.
- `LidarExplorer/MapLayer/TerrainMapView.swift`: `syncProfile`, `syncThalweg` gated; the renderer seeded in `rendererFor`;
  the Pencil kept out of MapKit's double-tap zoom in profile mode; the heading handed to the model.
- `LidarExplorer/MapLayer/TerrainTileOverlay.swift`: `seedVisibleRect(_:)`; `shadedComposite` shading on demand;
  `CachedTile` with one plane and the relight caches; `byteCount`; the budget and the memory warning.
- `LidarExplorer/Core/Geometry/ElevationGrid.swift`: `ElevationSampleStorage`, `withSamples`, `isPageAligned`.
- `LidarExplorer/Core/Raster/MetalTerrainPipelineActor.swift`: `renderComposite` taking and returning the base display.
- `LidarExplorer/Core/Raster/RasterCompute.swift`: the lease pool's byte ceiling and `purgeIdlePools()`.
- `LidarExplorer/Domain/ElevationProfile.swift`: the smoothed slope.
- `LidarExplorer/Presentation/Terrain3DScene.swift`, `Terrain3DOrbitView.swift`: `farClip(forExtent:)`.
- `LidarExplorer/Presentation/MapTouchPolicy.swift`: `tapWaitsForDoubleTap(in:by:)`, `doubleTapZoomReceivesPencil(in:)`.
- `LidarExplorer/Presentation/HapticDetents.swift`, `HapticFeedbackManager.swift`: `AzimuthDetentTracker`.
- `LidarExplorer/Presentation/GlassSurface.swift`: the shadow on the shape.
- `LidarExplorer/Presentation/DialGeometry.swift`, `PencilAzimuthRing.swift`, `ShadingDockView.swift`,
  `TerrainViewerModel.swift`: the map heading on the rings.
- `Tools/ViewerHarness/`: new subsections in `MapTouchPolicyChecks` (R6), `HapticChecks` (V1 extended),
  `TransectChecks` (profile slope), `Terrain3DChecks` (U5, U6), `TileLoadingChecks` (T16, T17, T18),
  `RasterStorageChecks` (N6), `DialGeometryChecks`; `OverlaySyncPolicy` checks in `MapTouchPolicyChecks` (R7).

---

### Task 1: Plan, branch, baseline

- [x] Branch `claude/frame-pacing-audit-2026-11-01` off bb8d767.
- [x] Baseline: `./Tools/run-harness.sh` ALL CHECKS PASSED, 1796 checks (`build-review/harness-baseline-2026-11-01.log`).
- [x] This document.

### Task 2: Overlay syncs leave an unchanged polyline alone

**Files:** create `LidarExplorer/MapLayer/OverlaySyncPolicy.swift` (+ `SOURCES=`); modify `TerrainMapView.swift`
(`syncProfile`, `syncThalweg`); test `Tools/ViewerHarness/MapTouchPolicyChecks.swift` (R7).

- [x] R7, red: `OverlaySyncPolicy.polylineChanged(from:to:)` is false for equal coordinates (same count, same lat/lon),
  true for a moved point, a different count, an empty-to-nonempty change; NaN never equals.
- [x] `syncProfile`: keep `profileCoordinates: [CLLocationCoordinate2D]` on the coordinator; replace the polyline only
  when `polylineChanged`. `syncThalweg`: the same with `thalwegCoordinates`.
- [x] Harness green; Simulator build.

### Task 3: The renderer knows its viewport from the frame it is made in

**Files:** `TerrainTileOverlay.swift` (`TerrainTileOverlayRenderer.seedVisibleRect(_:)`), `TerrainMapView.swift`
(`rendererFor`, `applyTerrain`); test `TileLoadingChecks.swift` (T16).

- [x] T16, red: a fresh renderer with a drawn tile reports no `visibleTileKeys()`, `currentView()` nil and no
  `drawnTiles()`; after `seedVisibleRect(rect)` with no region change it reports the tile and the view; a later
  `cullTiles(outsideVisible:)` still wins (the seed does not override a cull's rect).
- [x] `seedVisibleRect` sets `visibleRect` only while it is nil, and registers the sources. `rendererFor` calls it with
  `mapView.visibleMapRect` as the renderer is made.
- [x] Harness green; Simulator build.

### Task 4: The preview's Max Slope is measured on the smoothed line

**Files:** `LidarExplorer/Domain/ElevationProfile.swift`; test `TransectChecks.swift`.

- [x] Red: a profile over `moundProfile` at half-metre spacing with ±0.15 m alternating noise reads a Max Slope within
  2° of the transect analysis's peak slope, where the raw difference reads over 10° higher.
- [x] `ElevationProfile.init` smooths the elevations with `TransectMath.smoothed(sigmaSamples: smoothingMeters / step)`
  using `ElevationTransect.Parameters().smoothingMeters` and the median step, then takes the steepest smoothed pair;
  gain, loss, min and max stay raw.
- [x] Harness green.

### Task 5: The 3D view's far clip fits the mesh, and the drape shades bare tiles on demand

**Files:** `Terrain3DScene.swift` (`farClip(forExtent:)`), `Terrain3DOrbitView.swift`; `TerrainTileOverlay.swift`
(`shadedComposite` async, shading cached tiles with no bitmap); `TerrainViewerModel.swift`,
`GeoreferencedExportService.swift` callers; tests `Terrain3DChecks.swift` (U5, U6).

- [x] U5, red: `Terrain3DScene.farClip(forExtent:)` is 100 km for a small mesh and at least 8 × the extent (the orbit's
  farthest camera at 5 × 1.4 plus the mesh's own depth) for a 60 km one; finite for a NaN extent.
- [x] U6, red: a provider holding a tile's raster but no bitmap (the bitmap shed) composes a view over it with the tile
  shaded, not the 0.92 grey; a tile with no raster stays grey; `shadedCoverage` counts the shaded tile.
- [x] `shadedComposite` awaits `tileImage` for cached entries (readouts only, not stand-ins) that touch the region and
  hold no bitmap, up to `renderedLimit`, before composing.
- [x] Harness green; Simulator build.

### Task 6: Pencil taps answer at once; detents arm again only past twice the window

**Files:** `MapTouchPolicy.swift`, `TerrainMapView.swift`; `HapticDetents.swift`, `HapticFeedbackManager.swift`;
tests `MapTouchPolicyChecks.swift` (R6), `HapticChecks.swift` (V1).

- [x] R6, red: `tapWaitsForDoubleTap(in: .profile, by: .pencil)` is false, `.finger` and `.pointer` true;
  `doubleTapZoomReceivesPencil(in:)` is false in profile and true elsewhere.
- [x] V1, red: `AzimuthDetentTracker` ticks once for `[44, 45, 46.7, 45.4, 46.7, 45.4]` (tremor across the edge) and
  twice for `[44, 45, 50, 45.5]` (left past 3°), and matches `AzimuthDetents.detent` on every existing V1 sequence.
- [x] The coordinator records the kind of the touch the tap recognizer last received and answers
  `shouldRequireFailureOf` for the double-tap from it; `updateUIView` sets MapKit's double-tap recognizer's
  `allowedTouchTypes` from `doubleTapZoomReceivesPencil(in:)`.
- [x] Harness green; Simulator build; a device-pass step in HUMAN_DO_THIS.md.

### Task 7: The glass shadow is the shape's; the lease pool has a ceiling and a purge

**Files:** `GlassSurface.swift`; `RasterCompute.swift`; `TerrainTileOverlay.swift` (`handleMemoryPressure`);
test `RasterStorageChecks.swift` (N6).

- [x] N6, red: `RasterCompute.leasePoolIdleBytes` never exceeds `RasterCompute.leasePoolByteCeiling` (64 MB) after
  recycling more than that; `purgeIdlePools()` leaves it at 0; a lease obtained after the purge still renders.
- [x] `GlassSurface`: `.background(shape.fill(.regularMaterial).shadow(...))`, the rim overlay unchanged.
- [x] Harness green; Simulator build.

### Task 8: One page-aligned plane per cached tile *(ordered after Task 9 in execution; numbered as the audit's B1)*

See Task 9.

### Task 9: `ElevationGrid` owns one storage; `CachedTile.aligned` goes

**Files:** `ElevationGrid.swift`, `TerrainTileOverlay.swift`, `ElevationGridCoder.swift`, every hot `.samples` loop in
`MetalTerrainPipelineActor`, `AnalysisRasterBuilder`, `TerrainDerivatives`, `TerrainMeshBuilder`, `ElevationTransect`,
`TransectExporter`, `ElevationService`, `LocalGeoTIFFProvider`, `TerrainViewerModel`, `ElevationProfileView`;
tests `TileLoadingChecks.swift` (T9 rewritten, T17), `RasterStorageChecks.swift` (N2 extended).

- [x] T17, red: a disk tile's entry weighs one plane plus its bitmap, and its samples are read from the mapping (the
  grid is page-aligned and `samples(at:)` agrees with the file); a network tile re-shaded weighs one plane after its
  second shade, page-aligned, and the heap array is gone.
- [x] `ElevationSampleStorage` (final class, `@unchecked Sendable`, immutable): `.heap([Float])` or
  `.pages(base, length, offset, owner)`; `ElevationGrid.samples` stays for readers (a copy for a paged grid),
  `withSamples { UnsafeBufferPointer<Float> }` and `subscript` read in place; `init(width:height:samples:region:)`
  unchanged; `init(width:height:pages:…)` new; `pageAligned()` copies a heap grid into `COGMappedStorage`.
- [x] `CachedTile`: `var grid`; `samples`/`analysisSource` from the grid's storage; `byteCount` one plane.
  `diskTile` builds the grid over the mapping; `alignedForShading` replaces the grid with `grid.pageAligned()` at the
  second shade. The memory warning no longer drops copies.
- [x] Harness green (N1-N5, T9, T17, every `.samples` reader).

### Task 10: A relight reuses the stitched raster and the sun-invariant base

**Files:** `TerrainTileOverlay.swift` (`CachedTile.relight`, `microPipelineImage`, `update(_:)`, the budget),
`MetalTerrainPipelineActor.swift` (`renderComposite(… base: DisplayBitmap?)`, result `baseDisplay`);
test `TileLoadingChecks.swift` (T18).

- [x] T18, red: shading a tile under `.localRelief` blended with `.rakingLight`, then again with the azimuth turned,
  rebuilds no analysis raster and encodes no local-relief pass (the pipeline's pass counter), and the pixels equal a
  from-scratch render at the new azimuth; a change of LRM radius, blend layer or a neighbour's arrival invalidates
  the cache; the budget sheds the cache of a tile off screen.
- [x] `CachedTile.relight: RelightCache?` holds the analysis lease, its window and plan key, and the base display
  lease; `update(_:)` keeps it when only the sun fields differ (`TerrainStyleSettings.sunInvariant` equal).
- [x] Harness green.

### Task 11: The dial rings follow the map's heading

**Files:** `DialGeometry.swift` (`screenAngle(azimuth:mapHeading:)`), `PencilAzimuthRing.swift`, `ShadingDockView.swift`,
`TerrainViewerModel.swift` (`mapHeading`), `TerrainMapView.swift` (`regionDidChange`); test `DialGeometryChecks.swift`.

- [x] Red: `screenAngle(azimuth: 315, mapHeading: 45)` is 270; heading NaN leaves the azimuth; wraps into 0..<360.
- [x] The coordinator writes `map.camera.heading` to the model after each region change; both rings rotate their
  compass content by `-mapHeading`.
- [x] Harness green; Simulator build.

### Task 12: Full gates and the record

- [x] `./Tools/run-harness.sh` ALL CHECKS PASSED; Simulator Debug build, no Swift warnings.
- [x] STATUS.md (build rows, Known issues narrowed, a TODO section), this plan's record, `.agent/HANDOFF.json`,
  `HUMAN_DO_THIS.md` (the Pencil device step; E3 still the owner's).

## Where the code differs from this text

- Task 2 (63b914d): as written. `syncMarkup` was already gated by `markupVersion` and is untouched.
- Task 3 (10ea898): `seedVisibleRect(_:)` is called from `mapView(_:rendererFor:)` alone, not from `applyTerrain`: the
  renderer is made by MapKit after the overlay is added, so the seed lands in the frame the renderer first exists.
- Task 4 (789ebd3): the sigma in samples is `smoothingMeters / median step`, the median taken over the points' positive
  spacings, so a profile with one gap is smoothed at its true spacing. The check's noisy mound reads 42.0° raw against
  the analysis's 25.6°; smoothed, 25.7°.
- Task 5 (2a13b83): `farClip(forExtent:)` is `max(100 km, 10 × extent)`. `shadedCoverage` shades on demand too, so an
  export's coverage notice agrees with its picture; both are `async` now (every caller already awaited the actor).
  The on-demand pass skips a coarser tile that pictured finer tiles cover (`finerTiles`), and shades at the raster's
  own width minus the skirt, so `observedTilePixels` is not moved.
- Task 6 (f166ae1): `tapWaitsForDoubleTap(in:)` stays and is the finger's; `tapWaitsForDoubleTap(in:by:)` is the rule.
  MapKit's double-tap recognizer is found by walking the map's subviews four levels down for a one-touch, two-tap
  `UITapGestureRecognizer`, and otherwise captured in `shouldRequireFailureOf`; its original `allowedTouchTypes` are
  kept and restored outside profile mode. `AzimuthDetentTracker` wraps `AzimuthDetents.detent(from:to:)` rather than
  changing it, so every V1 sequence still holds; `AzimuthDetents.distance(from:toHeading:)` is new.
- Task 7 (bdab590): the ceiling is on free buffers' own `length`; `purgeIdlePools()` also drops the bundle pool
  (`bufferPool`). N6 reads the lease's slope at the grid's true centre (column 512): the kernel leaves the border NaN
  and a flat plane's slope is NaN too, so the check uses a ramp.
- Task 9 (356bd0c), the audit's B1: `ElevationSampleStorage` is a final class with `.heap([Float])` or `.pages(base,
  mappedLength, sampleOffset, owner)`; `ElevationGrid.samples` is computed (the array itself, or a copy of the
  pages); `withUnsafeSamples` and the subscripts read in place; `init(width:height:storage:region:)` and
  `replacingStorage(_:)` are new; `ElevationGridCoder.decode(mapped:)` builds the grid over a `LEG2` mapping. The
  page-aligned copy at a network tile's second shade is made in the provider (`pageAligned(_:)`,
  `COGMappedStorage` being a Services type) and replaces the heap array. `AlignedSamples`, the budget's copy-shedding
  stage and the memory warning's copy drop are gone. `Equatable` is written by hand with `[Float]`'s semantics. The
  harness's own grids stay heap-backed and read `.samples` as before.
- Task 10 (T18): `RelightCache` keeps the analysis raster and a `PreparedBase` (display and scalar) on the entry;
  `TerrainStyleSettings.relightPlan`, `relightsMicroTopography` and `blendsSunInvariantBase` decide; `update(_:)` drops
  every cache when the plan changes or the style stops relighting; the budget sheds caches after bitmaps and before
  planes; the memory warning drops the caches of tiles off screen. The pipeline's `renderComposite` takes
  `preparedBase:` and `keepBase:`, binds a prepared base's leases as read-only textures over their own buffers (declined
  back to a full encode when the rows cannot back a linear texture, as in the Simulator's blit mode for the scalar),
  and `MicroTopographyResult.baseDisplay` carries a kept base; a prepared base comes back as the result's `scalar` and
  `baseDisplay` (the same leases). Counters `relightCounters()`, `relightCachedKeys()`, `relightCacheBytes()`.
- Task 11: the Pencil ring alone follows the heading. The dock's dial and the profile panel's stay north-up: their
  drag maps a touch angle to a bearing (`DialGeometry.bearing`), and turning the face without the drag would mismatch;
  the owner's finding 3 named the Pencil ring.

## Verification

| Gate | Result |
|---|---|
| `./Tools/run-harness.sh` | 1869 PASS / 0 FAIL, ALL CHECKS PASSED at 4cfa839 (`build-review/harness-final-2026-11-01.log`); 1796 at bb8d767 (`harness-baseline-2026-11-01.log`). Per task: 1815 (Task 4), 1837 (Tasks 5-6), 1842 (Task 7), 1851 (Task 9), 1864 (Task 10) |
| Simulator build, Debug | `xcodebuild` Debug, iPad Pro 11-inch (M5), at 4cfa839: BUILD SUCCEEDED, no Swift warnings (`build-review/sim-final-2026-11-01.log`); the same after Tasks 2, 3, 5-6, 7, 9 and 10 (`sim-task*.log`) |
| Simulator build, Release | `-configuration Release`, same destination: BUILD SUCCEEDED, no Swift warnings (`build-review/sim-release-2026-11-01.log`) |
| Device build, Debug | `-configuration Debug -destination generic/platform=iOS -allowProvisioningUpdates`: BUILD SUCCEEDED, no Swift warnings (`build-review/device-debug-2026-11-01.log`) |
| Red first | Every new check was run before its fix: R7, T16, the Max Slope check, U6, U7, R6, V1's tracker checks, N6, T9 (rewritten) and T17, T18 and X9 each failed (a compile error where the member did not yet exist) and then passed |

## Unverified

- Nothing has run on a device. The Pencil's profile tap answering at once and the Pencil kept out of MapKit's
  double-tap zoom in profile mode (Task 6) are pinned by the policy checks and the bridge's source; whether MapKit's
  recognizer is found among the map's subviews is seen only on the iPad (`HUMAN_DO_THIS.md`, 2026-11-01).
- The relight's saving (Task 10) is shown by the harness's counters (one stitch, then reuse) and by the pixels; it has
  not been timed on a device under a dial drag. The harness's Metal is the Mac's, in linear surface mode; in the
  Simulator's blit mode a prepared base's scalar rows may not back a linear texture, in which case the base is
  produced again (the raster is still reused).
- The one-plane tile (Task 9) and the glass shadow (Task 7) are compiled for the Simulator and checked on the Mac;
  memory on a device and the Done capsule's halo are not re-measured.
- The far clip (Task 5) is checked by its arithmetic; no regional mesh was opened in the Simulator.
- Xcode Cloud's nightly has not been seen on this branch.

## Follow-ups (not done)

- m3, Terrarium skirt seams at z6-15: give the standard styles the stale-neighbour re-shade, or fetch the four edge
  rows from the neighbours' tiles.
- m5, the notebook journal.
- E3, the device Metal System Trace (owner).
