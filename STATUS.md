# LidarExplorer — Status & TODOs

_Last updated: 2026-09-17 (Map Styles reference · ads/StoreKit removal · sun controls · resilience review fixes) · branch `main`_

An iOS/iPadOS terrain explorer: streams USGS 3DEP + Terrarium elevation as
GPU-shaded MapKit tiles, with spot inspection, transects, contours, hypsometric
tints and georeferenced export — extended with the micro-topography engine
(LRM, RRIM, sky-view, raking light, REM, habitation mask, viewshed, historical
map overlays, SSURGO soil hatching, directional occlusion, openness split, VRM, and DoG).

Authoritative plan: [`docs/superpowers/plans/2026-09-13-architectural-review-remediation.md`](docs/superpowers/plans/2026-09-13-architectural-review-remediation.md)
Architectural assessment: [`docs/superpowers/reviews/2026-09-13-architectural-review-assessment.md`](docs/superpowers/reviews/2026-09-13-architectural-review-assessment.md)
Resilience review assessment (2026-09-14): [`docs/superpowers/reviews/2026-09-14-resilience-review-assessment.md`](docs/superpowers/reviews/2026-09-14-resilience-review-assessment.md)

## Build & verification status — ✅ green

Verified 2026-09-17 on the working tree (M5 Pro Mac + iPad Pro 13" physical device [iGonk Pro M5], iPad Pro 13"/11" and iPhone 17 Pro Simulators):

| Check | Command | State |
|---|---|---|
| Offline regression harness | `./Tools/run-harness.sh <render-dir>` | ✅ 626 PASS / 0 FAIL (All remediations, blit interleaving race, pool purge, Map Styles reference, C7 sun-control checks, cooperative task cancellation, race-free task registration, and ImageServer circuit breaker verified) |
| Live network check | `./Tools/run-live-check.sh` | ✅ 67 PASS / 0 FAIL — square footprint COG vs ImageServer mean \|diff\| 0.091 m (< 0.15 m); cold z19 map tile 0.69 s; USDA SDA 0.41 s |
| Release build (generic iOS, strict concurrency) | `xcodebuild -project LidarExplorer.xcodeproj -scheme LidarExplorer -destination "generic/platform=iOS Simulator" -configuration Debug CODE_SIGNING_ALLOWED=NO build` | ✅ BUILD SUCCEEDED (0 errors, 0 warnings from modified source) |
| GPU budget, 1024² at 1 m | harness `checkBudget` | ✅ LRM 1.50 ms · RRIM 3.32 ms · SVF 5.34 ms · raking 0.05 ms (wall-clock 0.33 ms) · habitation 0.69 ms · full composite 6.19 ms (all well within < 8 ms budget) |
| Tile render via provider (z19, 512 px, warm) | harness `checkAnalysisRasterBuilder` | ✅ LRM 3.0 ms (analysed at native 1 m, 64 px) |
| Per-zoom tile render budget (warm, ms) | harness `checkRenderBudgets` | ✅ z18: LRM 2.4 · RRIM 1.8 · SVF 2.1 · Raking 0.9 · REM 0.9<br>✅ z19: LRM 3.0 · RRIM 2.9 · SVF 2.7 · Raking 0.9 · REM 0.9<br>✅ z20: LRM 5.7 · RRIM 4.7 · SVF 3.8 · Raking 0.9 · REM 0.9 (all < 6 ms, budget 16 ms) |
| Provider memory | harness `checkProviderMemory` | ✅ 9 shaded 512 px tiles < 25 MB; budget 256 MB counting rasters, derivative planes and bitmaps |
| Map Styles panel | iPad Pro 13" (iGonk Pro M5) & 13"/11" / iPhone 17 Pro Simulators | ✅ Opens beside the map (sheet on iPhone); **Use This Style** switches the map and flips to **In Use**; all 7 top-bar buttons stay visible at 11" portrait with the readout truncating; **Replay Intro** presents over the panel sheet on iPhone |
| Compass button placement | iPad Pro 13" (iGonk Pro M5) | ✅ Default MKMapView compass disabled; MKCompassButton anchored below top-bar action buttons (-16 trailing, +54 top from safeAreaLayoutGuide) with .adaptive visibility |
| Panel resize cost (Elevation style) | `log stream` on "Terrain tiles reloaded" | ✅ 0 terrain reloads per open/close cycle (design-review bar was ≤ 1) |

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
- Map Styles reference panel (`?` button in top bar): searchable in-app reference covering all 16 styles and 3 overlays, with full descriptions, "How to read it", "Best for", and slider hints, plus a direct "Use This Style" action button. Renders as a side inspector panel on regular-width screens (iPad/Mac) and as a medium/large sheet on compact screens (iPhone).
- UI: horizontal scrolling style chips in bottom dock, interaction modes (explore, transect, viewshed, thalweg), settings sliders for micro-topography, historical maps importer + opacity/wipe controls, SSURGO soil hatching toggle + legend, spot callout soil readout.

## Known issues (open)

- None (all micro-topography plan items verified green).

## TODOs

### Micro-topography engine (plan)
- Part C: ✅ C1 overlays & grazing light · ✅ C2 style chips · ✅ C3 transect panel · ✅ C4 viewshed mosaic · ✅ C5 thalweg drawing · ✅ C6 per-zoom budget table
- Part D: ✅ D1–D2 historical maps (world files, opacity, split wipe) · ✅ D3–D5 SSURGO soils (classification, Soil Data Access client, hatched overlay)
- Part E: ✅ E1 release build · ✅ E2 Simulator smoke run · ✅ E3 device Metal System Trace · ✅ E4 open verification items · ✅ E5 commit and PR

### Resilience review follow-ups (2026-09-14)
- [x] Measure Metal pool peak under a MapKit-like tile burst before deciding on a render flight gate (review R1-M1). Headless harness check `checkTileBurstConcurrency` (`Tools/ViewerHarness/ProviderMicroChecks.swift`, B6) drives 24 concurrent tile loads through the real claim/record/finish path. Findings: the generation fence does **not** throttle a pan burst (24/24 run concurrently regardless of viewport, since only `reloadData()` bumps the generation) — peak GPU live leases stay ≈1–2x tile count (analysis-input and display-output leases briefly overlap per tile) and release fully once both the renderer's `TileImageStore` and, separately, `TerrainTileProvider`'s own 48-entry `renderedOrder` bitmap cache (`renderedLimit`) are cleared. **No explicit in-flight semaphore gate recommended**: `renderedLimit = 48` already caps how many tiles' GPU surfaces stay concurrently live during sustained panning via LRU eviction, and at typical tile buffer sizes that ceiling is well within budget. Device Instruments confirmation (Metal System Trace under real 120 Hz flick gestures) is still open — the harness measurement is a headless proxy, not a device trace.
- [x] Short-TTL failure memory for ImageServer / COG-header transport failures, so memory-evicted fallback tiles don't refetch known-bad endpoints (R1-B1, 60s failure cooldown implemented).
- [x] Cancel *settings-obsoleted* tile requests in `TileImageStore` / `TerrainTileOverlayRenderer` (in-flight tasks tracked, cancelled on `invalidate()`/generation changes from `reloadData()`). Note: this does not cancel tiles that scroll off-screen during a plain pan/zoom with no settings change — confirmed by the R1-M1 measurement above; such tiles run to completion and populate the caches regardless of current viewport.

### Off-screen tile culling (2026-09-18, confirmed real and open)
- [ ] Cancel in-flight tile `Task`s that scroll outside the (margin-expanded) visible `MKMapRect` during a plain pan/zoom, not just on a settings-driven `invalidate()`. Needs a per-key `cancel(_:)` on `TileImageStore` (mirroring `invalidate()`'s bookkeeping but for one key) called from `canDraw(_:zoomScale:)`, plus `Task.isCancelled` guards ahead of the GPU/stitching dispatch in `microPipelineImage`/`AnalysisRasterBuilder.build`. Real races to solve first: a per-key epoch (not just the global `generation`) so a stale cancelled task's late `finishLoad` can't clobber a fresh re-request for the same key on gesture reversal; a margin/ring (not the exact rect) so a tile one screen-width away survives a small overshoot instead of thrashing cancel/re-request; cancellation should bias toward the compute end (GPU dispatch, stitching) rather than the network end, since a fetch already close to landing is cheaper to let finish than to redo.

### Test-coverage hardening (carried over from 2026-09-10)
- [ ] GeoTIFF harness: tiepoint (`(minX, maxY)`) and pixel-scale (`span/(n−1)`) values are decoded and asserted (`Tools/ViewerHarness/main.swift:1780-1789`, verified 2026-09-18). Still open: GeoKey *values* (RasterType=2, CS=3857) are only checked for tag presence (`main.swift:1750-1751`), not decoded/asserted.
- [x] GPU/lease harness: non-square grid (200×120) run through both `leasedReliefProducts` and `reliefProducts`, slope checked against CPU reference for both (`main.swift:1972-2024`, verified 2026-09-18).
- [x] Lease harness: pool-reuse-while-reading forced — a held lease's snapshot verified unchanged across 10 churn dispatches of other grid sizes (`main.swift:2027-2071`, verified 2026-09-18).
- [x] `GeoTileKey`: all four globe corners (±90 lat, ±180 lon) plus over-range clamping and Morton locality asserted (`main.swift:2073-2113`, verified 2026-09-18).

### Product / integration (carried over)
- [x] Wire `leasedReliefProducts` into a live consumer — confirmed called from production: `RasterCompute.rrimImage` (`RasterCompute.swift:715`) → `TerrainTileOverlay.shadeToImage`/`rrimImage(for:)` (`TerrainTileOverlay.swift:464-476,533-536`) → the real MapKit `loadTile` pipeline, not just the harness. Narrower gap remains: it's only a fallback for the `.rrim` style when `microPipelineImage` returns nil; hillshade/multiDirectional/slope/elevation and the CPU-fallback `ensureProducts` path never call it — broaden if the zero-copy benefit is wanted there too.
- [x] Surface `GeoTIFFWriter` in the export UI — GeoTIFF is already the *default* export format (`TerrainViewerModel.swift:268`), wired to both the settings-sheet export picker (`ViewerSettingsSheetView.swift:367-421`) and the top-bar share menu (`ViewerTopBarView.swift:215-225`); landed same-day in commit `bdfad21`, this line just never got checked off.
- [ ] Decide whether `GeoTileKey` keys by origin only or folds in zoom/span. Zoom half is resolved and documented (top 6 bits of the packed key, `GeoRegion.swift:260-296`, commit `bdfad21`). Still undecided/undocumented: whether two same-origin, same-zoom regions of different **span** should collide.
- [x] Optional GeoTIFF niceties: `GDAL_NODATA="nan"` (tag 42113, `GeoTIFFWriter.swift:148`) and a zero-span Mercator-bounds guard (`.degenerateBounds`, `GeoTIFFWriter.swift:22,85`) are both implemented and harness-verified (2026-09-18).

### Housekeeping
- [x] Paid-upfront release transition: Removed Google Mobile Ads SDK, Google UMP consent SDK, banner ads, and StoreKit 2 Remove Ads IAP.
- [x] Stale detached worktree `.claude/worktrees/reverent-noyce-f2a22c` — does not exist (`git worktree list` shows only the main worktree; no such directory on disk anywhere under the dev root). This line had simply never been re-checked against actual git state since it was first written; verified nonexistent 2026-09-18. (Separately, all other agent worktrees and merged feature branches were also cleaned up 2026-09-18 — `main` is now the only worktree and branch.)
- [x] `../HUMAN_DO_THIS.md` notes a prior file was overwritten on 2026-09-09 — acknowledged, not actionable: that overwritten content is confirmed unrecoverable (no VCS, no backup), and the file's current state already reads "No outstanding blockers," referencing merged PR #56. Nothing to recreate.

## Layout
`Core/` geometry + raster/Metal · `Domain/` value types + transects · `Services/`
elevation (ImageServer, Terrarium, COG coordinator)/transport/storage/export ·
`MapLayer/` MapKit overlays, renderers, analysis-raster builder · `Presentation/`
SwiftUI + view models · `Tools/` headless harness + live check. Zero third-party dependencies.
