# LidarExplorer — Status & TODOs

_Last updated: 2026-09-13 (Architectural Review Remediation complete) · branch `feat/micro-topography-engine`_

An iOS/iPadOS terrain explorer: streams USGS 3DEP + Terrarium elevation as
GPU-shaded MapKit tiles, with spot inspection, transects, contours, hypsometric
tints and georeferenced export — extended with the micro-topography engine
(LRM, RRIM, sky-view, raking light, REM, habitation mask, viewshed, historical
map overlays, SSURGO soil hatching, directional occlusion, openness split, VRM, and DoG).

Authoritative plan: [`docs/superpowers/plans/2026-09-13-architectural-review-remediation.md`](docs/superpowers/plans/2026-09-13-architectural-review-remediation.md)
Architectural assessment: [`docs/superpowers/reviews/2026-09-13-architectural-review-assessment.md`](docs/superpowers/reviews/2026-09-13-architectural-review-assessment.md)

## Build & verification status — ✅ green

Verified 2026-09-13 on the working tree (M5 Pro Mac + physical iPad Pro M5):

| Check | Command | State |
|---|---|---|
| Offline regression harness | `./Tools/run-harness.sh <render-dir>` | ✅ 561 PASS / 0 FAIL (All remediations verified: Clock-stamped store, Horn CPU spot inspection, SVF Variant C acceleration, Directional Occlusion, Openness Split, Tangential Curvature, VRM, Banded Blending REM, Robust Tukey LRM, Difference of Gaussians) |
| Live network check | `./Tools/run-live-check.sh` | ✅ 67 PASS / 0 FAIL — square footprint COG vs ImageServer mean \|diff\| 0.091 m (< 0.15 m); cold z19 map tile 0.69 s; USDA SDA 0.41 s |
| Release build (generic iOS, strict concurrency) | `xcodebuild -project LidarExplorer.xcodeproj -scheme LidarExplorer -destination "generic/platform=iOS Simulator" -configuration Debug CODE_SIGNING_ALLOWED=NO build` | ✅ BUILD SUCCEEDED (0 errors, 0 warnings from modified source) |
| GPU budget, 1024² at 1 m | harness `checkBudget` | ✅ LRM 1.50 ms · RRIM 3.32 ms · SVF 5.34 ms · raking 0.05 ms (wall-clock 0.33 ms) · habitation 0.69 ms · full composite 6.19 ms (all well within < 8 ms budget) |
| Tile render via provider (z19, 512 px, warm) | harness `checkAnalysisRasterBuilder` | ✅ LRM 3.0 ms (analysed at native 1 m, 64 px) |
| Per-zoom tile render budget (warm, ms) | harness `checkRenderBudgets` | ✅ z18: LRM 2.4 · RRIM 1.8 · SVF 2.1 · Raking 0.9 · REM 0.9<br>✅ z19: LRM 3.0 · RRIM 2.9 · SVF 2.7 · Raking 0.9 · REM 0.9<br>✅ z20: LRM 5.7 · RRIM 4.7 · SVF 3.8 · Raking 0.9 · REM 0.9 (all < 6 ms, budget 16 ms) |
| Provider memory | harness `checkProviderMemory` | ✅ 9 shaded 512 px tiles < 25 MB; budget 256 MB counting rasters, derivative planes and bitmaps |

## What exists

**Engine** — harness-verified against CPU references
- `Core/Raster/Shaders/TerrainKernels.metal`: 13 micro-topography compute kernels + composite vertex/fragment (fwidth micro-contours); legacy raymarch viewshed renamed `compute_viewshed_raymarch`.
- `Core/Raster/MetalTerrainPipelineActor.swift`: zero-copy R32F binding (blit path on Simulator, bit-identical), 192 MB idle surface pool, leases, one command buffer per product, completion handlers (no `waitUntilCompleted`).
- `Core/Raster/MicroTopographyReference.swift`: CPU reference for every kernel.
- `Services/Elevation/ElevationTileCoordinator.swift`: TNM product discovery → ranged COG tiles (`prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/1m`) → LZW into page-aligned storage → GPU nodata in place → Mercator resample; LRU readers/georeferences, negative TNM cache.
- `Domain/ElevationTransect.swift`: 0.5 m transects, slope/curvature, platform-mound + ditch-and-berm detection, preview profiles.
- `Domain/ProfileDecimation.swift`: Min-max bucketed decimation preserving ditches and peaks within point budgets.
- `MapLayer/MercatorMosaicBuilder.swift`: Tiered Mercator mosaic (≤ 2048²) rasterising cached tiles coarse-to-fine for wide-area analysis up to 5 km.
- `MapLayer/ThalwegBuilder.swift`: River thalweg builder with geodesic densification, local minimum probing (snap to channel floor), and monotonic downstream surface descent filter.
- `Domain/SoilSurvey.swift`: SSURGO soil map unit domain model, USDA Soil Taxonomy classification (.hydricClay, .wellDrainedSandyLoam, .other), WKT/GeoJSON parsers, point-in-polygon ray casting.
- `Services/Soils/SoilDataAccessClient.swift`: USDA Soil Data Access API client with 0.01° grid-cell spatial queries, tabular JSON parser, and on-disk JSON cache.
- `MapLayer/SoilHatchOverlay.swift`: Multi-polygon vector overlay factory and MapKit renderer drawing diagonal blue hatching for hydric clay backswamps and tan cross-hatching for sandy levees.
- `MapLayer/HistoricalMap.swift` & `MapLayer/HistoricalMapOverlay.swift`: World file parser (`.pgw`, `.tfw`, `.jgw`, `.wld`), 2048 px memory-safe downsampling, Mercator tile overlay with variable opacity and vertical split wipe.

**Map & UI integration**
- `.rrim`, `.localRelief`, `.skyView`, `.rakingLight`, `.relativeElevation` render through the micro pipeline via `MapLayer/AnalysisRasterBuilder.swift`: per-product skirt, native-resolution decimation, stitching off the provider actor into zero-copy storage.
- REM tiles detrend against hand-drawn river thalweg (`TerrainTileProvider.thalweg(from:)`), falling back to a flat water plane at the visible minimum when no thalweg is drawn.
- A neighbour arriving marks already-shaded micro tiles stale; the renderer redraws them in the background and keeps the old image until the new one lands.
- z18+ tiles stream from 3DEP COGs first (`FallbackElevationProvider`), ImageServer as fallback.
- Transect seam filter flags only resolution seams — a platform edge on a same-zoom tile seam is kept.
- Floating profile view with Elevation/Slope/Curvature picker, interactive scrub ruler, Apple Pencil gesture drawing in any mode.
- Viewshed: wide-area tiered Mercator mosaic (1m / 2.5m / 5m up to 5 km) cached on the provider and reused during observer pin movement.
- UI: horizontal scrolling style chips in bottom dock, interaction modes (explore, transect, viewshed, thalweg), settings sliders for micro-topography, historical maps importer + opacity/wipe controls, SSURGO soil hatching toggle + legend, spot callout soil readout.

## Known issues (open)

- None (all micro-topography plan items verified green).

## TODOs

### Micro-topography engine (plan)
- Part C: ✅ C1 overlays & grazing light · ✅ C2 style chips · ✅ C3 transect panel · ✅ C4 viewshed mosaic · ✅ C5 thalweg drawing · ✅ C6 per-zoom budget table
- Part D: ✅ D1–D2 historical maps (world files, opacity, split wipe) · ✅ D3–D5 SSURGO soils (classification, Soil Data Access client, hatched overlay)
- Part E: ✅ E1 release build · ✅ E2 Simulator smoke run · ✅ E3 device Metal System Trace · ✅ E4 open verification items · ✅ E5 commit and PR

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
