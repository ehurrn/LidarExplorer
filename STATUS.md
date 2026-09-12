# LidarExplorer — Status & TODOs

_Last updated: 2026-09-12 (plan Part B complete) · branch `feat/micro-topography-engine` · last commit `5d106b9` — **all micro-topography work is uncommitted**_

An iOS/iPadOS terrain explorer: streams USGS 3DEP + Terrarium elevation as
GPU-shaded MapKit tiles, with spot inspection, transects, contours, hypsometric
tints and georeferenced export — extended with the micro-topography engine
(LRM, RRIM, sky-view, raking light, REM, habitation mask, viewshed).

Authoritative plan: [`docs/superpowers/plans/2026-09-12-micro-topography-engine.md`](docs/superpowers/plans/2026-09-12-micro-topography-engine.md)
Design + calibration: [`docs/superpowers/specs/2026-09-12-micro-topography-engine-design.md`](docs/superpowers/specs/2026-09-12-micro-topography-engine-design.md)

## Build & verification status — ✅ green

Verified 2026-09-12 on the working tree (M5 Pro Mac):

| Check | Command | State |
|---|---|---|
| Offline regression harness | `./Tools/run-harness.sh <render-dir>` | ✅ 464 PASS / 0 FAIL |
| Live network check | `./Tools/run-live-check.sh` | ✅ 67 PASS / 0 FAIL — COG footprint cold 0.73 s; cold z19 map tile through the provider default 0.94 s |
| App build (Simulator) | `xcodebuild -project LidarExplorer.xcodeproj -scheme LidarExplorer -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build` | ✅ BUILD SUCCEEDED (no warnings from files touched by this work) |
| GPU budget, 1024² at 1 m | harness `checkBudget` | ✅ LRM 1.4–3.3 ms · RRIM 3.3–4.4 ms · SVF 2.4 · habitation 0.7 · full composite 3.3 (brief: < 8 ms) |
| Tile render via provider (z19, 512 px, warm) | harness `checkAnalysisRasterBuilder` | ✅ LRM 3.2 ms (was 10–21 ms), analysed at native 1 m (64 px), composited back to 512 px when overlays are on |
| Provider memory | harness `checkProviderMemory` | ✅ 9 shaded 512 px tiles < 25 MB (was 64 MB); budget 256 MB counting rasters, derivative planes and bitmaps |
| On-device Metal System Trace / FPS / memory | plan Task E3 | ⏳ pending — last capture (2026-09-09) predates this work |

The harness does not compile the SwiftUI/MapKit views; only `xcodebuild` catches errors there.

## What exists

**Engine** — harness-verified against CPU references
- `Core/Raster/Shaders/TerrainKernels.metal`: 13 micro-topography compute kernels + composite vertex/fragment (fwidth micro-contours); legacy raymarch viewshed renamed `compute_viewshed_raymarch`.
- `Core/Raster/MetalTerrainPipelineActor.swift`: zero-copy R32F binding (blit path on Simulator, bit-identical), 192 MB idle surface pool, leases, one command buffer per product, completion handlers (no `waitUntilCompleted`).
- `Core/Raster/MicroTopographyReference.swift`: CPU reference for every kernel.
- `Services/Elevation/ElevationTileCoordinator.swift`: TNM product discovery → ranged COG tiles (`prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/1m`) → LZW into page-aligned storage → GPU nodata in place → Mercator resample; LRU readers/georeferences, negative TNM cache.
- `Domain/ElevationTransect.swift`: 0.5 m transects, slope/curvature, platform-mound + ditch-and-berm detection, preview profiles.

**Map integration**
- `.rrim`, `.localRelief`, `.skyView`, `.rakingLight`, `.relativeElevation` render through the micro pipeline via `MapLayer/AnalysisRasterBuilder.swift`: per-product skirt, native-resolution decimation, stitching off the provider actor into zero-copy storage.
- REM tiles detrend against a flat water plane at the visible minimum until a thalweg is set (`TerrainStyleSettings.thalweg` is plumbed; drawing UI is Task C5).
- A neighbour arriving marks already-shaded micro tiles stale; the renderer redraws them in the background and keeps the old image until the new one lands.
- z18+ tiles stream from 3DEP COGs first (`FallbackElevationProvider`), ImageServer as fallback.
- Derivative planes are computed only for the CPU fallback; spot slope/aspect come from a local Horn window.
- Transect seam filter flags only resolution seams — a platform edge on a same-zoom tile seam is kept.
- Viewshed: the mask is drawn as a map overlay (`MapLayer/ViewshedOverlay.swift`) and follows the observer pin while it is dragged.
- UI (Antigravity, now compiling): interaction modes, drag preview + debounced analysis, signature pills, chart scrub ruler, viewshed toggle, micro settings sliders.

## Known issues (open)

- Viewshed still stitches only 3×3 tiles (≈ 120 m of real terrain at z19) — Task C4 (tiered Mercator mosaic, 5 km).
- Transect analysis during drags runs on the provider actor; chart decimation is uniform stride; panel is collapsible, not resizable — Task C3.
- Habitation mask / sky-view shading not exposed in the UI; raking light uses the classic altitude slider; style picker is a 10-segment control — Tasks C1, C2.
- COG vs ImageServer agreement on a square footprint still unverified (ImageServer > 30 s cold) — Task E4.

## TODOs

### Micro-topography engine (plan)
- Part C: C1 overlays & grazing light · C2 style chips · C3 transect panel · C4 viewshed mosaic · C5 thalweg drawing · C6 per-zoom budget table
- Part D: D1–D2 historical maps (world files, opacity, split wipe) · D3–D5 SSURGO soils (classification, Soil Data Access client, hatched overlay)
- Part E: release build · Simulator smoke run · device Metal System Trace + memory · open verification items · commit and PR

### Test-coverage hardening (carried over from 2026-09-10)
- [ ] GeoTIFF harness: decode and assert the geotransform **values** (tiepoint = `(minX, maxY)`, pixel scale = `span/(n−1)`, GeoKey RasterType=2, CS=3857), not just tag presence.
- [ ] GPU/lease harness: run one **non-square** grid (e.g. 200×120) through both `leasedReliefProducts` and `reliefProducts`.
- [ ] Lease harness: force **pool-reuse-while-reading** (hold a lease, snapshot, churn other computations, assert unchanged).
- [ ] `GeoTileKey`: pole/antimeridian boundary inputs (lat ±90, lon ±180) and a coarse Z-order locality assertion.

### Product / integration (carried over)
- [ ] Wire `leasedReliefProducts` into a live consumer.
- [ ] Surface `GeoTIFFWriter` in the export UI (only PNG + world file is wired today).
- [ ] Decide whether `GeoTileKey` keys by origin only or folds in zoom/span.
- [ ] Optional GeoTIFF niceties: `GDAL_NODATA="nan"`; guard zero-span Mercator bounds.

### Housekeeping
- [ ] Commit the branch in reviewable slices (engine; coordinator; transects; integration + Part B fixes; UI).
- [ ] `Config/Info.plist` / `project.pbxproj`: `ITSAppUsesNonExemptEncryption` moved from Info.plist to a build setting — incidental, accept or discard.
- [ ] Stale detached worktree `.claude/worktrees/reverent-noyce-f2a22c` (`git worktree remove`).
- [ ] `../HUMAN_DO_THIS.md` notes a prior file was overwritten on 2026-09-09; recreate its content if it still matters.

## Layout
`Core/` geometry + raster/Metal · `Domain/` value types + transects · `Services/`
elevation (ImageServer, Terrarium, COG coordinator)/transport/storage/export ·
`MapLayer/` MapKit overlays, renderers, analysis-raster builder · `Presentation/`
SwiftUI + view models · `Monetization/` ads/store · `Tools/` headless harness + live check.
