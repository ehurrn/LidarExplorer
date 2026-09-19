# LidarExplorer — Status & TODOs

_Last updated: 2026-09-18 (tile-burst pool measurement · off-screen tile culling · TODO reconciliation) · branch `main`_

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
| Offline regression harness | `./Tools/run-harness.sh <render-dir>` | ✅ 697 PASS / 0 FAIL, re-measured 2026-09-19 (the other rows are from 2026-09-17) (All remediations, blit interleaving race, pool purge, Map Styles reference, C7 sun-control checks, cooperative task cancellation, race-free task registration, ImageServer circuit breaker, tile-burst pool peak (B10) and off-screen tile culling (B11) verified) |
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
- [x] Measure Metal pool peak under a MapKit-like tile burst before deciding on a render flight gate (review R1-M1). Headless harness check `checkTileBurstConcurrency` (`Tools/ViewerHarness/ProviderMicroChecks.swift`, B10) drives 24 concurrent tile loads through the real claim/record/finish path. Findings: the generation fence does **not** throttle a pan burst (24/24 run concurrently regardless of viewport, since only `reloadData()` bumps the generation) — peak GPU live leases stay ≈1–2x tile count (analysis-input and display-output leases briefly overlap per tile) and release fully once both the renderer's `TileImageStore` and, separately, `TerrainTileProvider`'s own 48-entry `renderedOrder` bitmap cache (`renderedLimit`) are cleared. **No explicit in-flight semaphore gate recommended**: `renderedLimit = 48` already caps how many tiles' GPU surfaces stay concurrently live during sustained panning via LRU eviction, and at typical tile buffer sizes that ceiling is well within budget. Device Instruments confirmation (Metal System Trace under real 120 Hz flick gestures) is still open — the harness measurement is a headless proxy, not a device trace.
- [x] Short-TTL failure memory for ImageServer / COG-header transport failures, so memory-evicted fallback tiles don't refetch known-bad endpoints (R1-B1, 60s failure cooldown implemented).
- [x] Cancel *settings-obsoleted* tile requests in `TileImageStore` / `TerrainTileOverlayRenderer` (in-flight tasks tracked, cancelled on `invalidate()`/generation changes from `reloadData()`). Note: this does not cancel tiles that scroll off-screen during a plain pan/zoom with no settings change — confirmed by the R1-M1 measurement above; such tiles run to completion and populate the caches regardless of current viewport.

### Off-screen tile culling (2026-09-18)
- [x] Cancel in-flight tile `Task`s that a pan carries outside the visible `MKMapRect`, which the generation fence cannot do (it moves only on a shading change). `TileImageStore.cancel(_:)` retires one key's claim and task; `TerrainTileOverlayRenderer.cullTiles(outsideVisible:)` drives it from `mapViewDidChangeVisibleRegion`, which fires continuously through a gesture. Because culling deliberately leaves the generation alone, claims now carry a unique `id` (`TileImageStore.Ticket`) so a cancelled task's late `finishLoad` cannot retire a fresh re-request's claim for the same key; claims culled before their task registers are remembered in `cancelledClaimIDs` so the task is cancelled on arrival rather than left running. `Task.isCancelled` guards sit ahead of shading (after the fetched raster is cached — the fetch is paid for and answers every setting) and ahead of the surface lease + stitching pass in `microPipelineImage`. Tiles within one viewport of the edge are kept, so a gesture reversal doesn't trade GPU work for a repeated fetch. Harness: `checkOffScreenTileCulling` (B11), 16 checks covering both races and the geometry.
- [x] Device-verified on iGonk Pro M5 (2026-09-18), via the Tile Activity panel: **hard flick** 765 cancelled / 899 fetched / 884 cached — culling fires hard when tiles are genuinely stranded. **Map stationary ~15 s** 0 events — culling never fires on its own, so it is not fighting MapKit's prefetcher (the one plausible thrash mode). **Realistic session** (zoom out → pan → zoom in → pan back to start) 9 cancelled / 174 fetched / 266 cached / 0 failed / 0.24 s mean fetch — ~2% cancellation during deliberate navigation, so the one-viewport margin is not over-culling. Cache hits exceeding fetches on the pan-back is the guard's placement paying off: the cancellation sits *after* the raster is cached, so returning to culled ground is served from memory rather than refetched. No margin tuning needed.

### Test-coverage hardening (carried over from 2026-09-10)
- [x] GeoTIFF harness: tiepoint (`(minX, maxY)`) and pixel-scale (`span/(n−1)`) values are decoded and asserted (`Tools/ViewerHarness/main.swift:1908-1917`), and so are the GeoKeyDirectory (tag 34735) header and its three keys read from the file: version 1 / revision 1.0 / 3 keys, GTModelType=1 (Projected), GTRasterType=2 (PixelIsPoint), ProjectedCSType=3857 (`main.swift:1859-1879`, commit `efbd644`, verified 2026-09-18).
- [x] GPU/lease harness: non-square grid (200×120) run through both `leasedReliefProducts` and `reliefProducts`, slope checked against CPU reference for both (`main.swift:2100-2153`, verified 2026-09-18).
- [x] Lease harness: pool-reuse-while-reading forced — a held lease's snapshot verified unchanged across 10 churn dispatches of other grid sizes (`main.swift:2155-2199`, verified 2026-09-18).
- [x] `GeoTileKey`: all four globe corners (±90 lat, ±180 lon) plus over-range clamping and Morton locality asserted (`main.swift:2201-2241`, verified 2026-09-18).

### Product / integration (carried over)
- [x] Wire `leasedReliefProducts` into a live consumer — confirmed called from production: `RasterCompute.rrimImage` (`RasterCompute.swift:715`) → `TerrainTileOverlay.shadeToImage`/`rrimImage(for:)` (`TerrainTileOverlay.swift:464-476,533-536`) → the real MapKit `loadTile` pipeline, not just the harness. Narrower gap remains: it's only a fallback for the `.rrim` style when `microPipelineImage` returns nil; hillshade/multiDirectional/slope/elevation and the CPU-fallback `ensureProducts` path never call it — broaden if the zero-copy benefit is wanted there too.
- [x] Surface `GeoTIFFWriter` in the export UI — GeoTIFF is already the *default* export format (`TerrainViewerModel.swift:268`), wired to both the settings-sheet export picker (`ViewerSettingsSheetView.swift:367-421`) and the top-bar share menu (`ViewerTopBarView.swift:215-225`); landed same-day in commit `bdfad21`, this line just never got checked off.
- [x] `GeoTileKey` identity decided (2026-09-18): **south-west origin plus zoom; span is deliberately not part of the key.** Exact for a tile's own (unpadded) extent at every zoom the app serves (up to 21), where origin and zoom fix the extent; any other region must key on `GeoRegion.cacheKey`, which encodes all four bounds (to 1e-6 degrees). Folding span in was rejected: all 64 bits are used (6 zoom + 29 + 29), it would still not make this a grid key (`pixels`/`margin`/`targetSamples` sit outside it), and only the harness constructs a `GeoTileKey` — the sole other references are the uncalled `TileDiskCache.read(for:)`/`map(for:)`/`write(_:for:)` overloads that accept one. Recorded in the type doc (`GeoRegion.swift:262-270`) and pinned in the harness (`main.swift:1733-1806`): span-blindness across four span variants, a per-bound check (moving only the north or east bound leaves the key unchanged), and two checks on real geometry through `TerrainTileOverlay.region(for:)` (a tile and its south-west child share origin bits, and 5×5 neighbourhoods at z21 at the equator, 39°N and 70°N key uniquely). A mutant that XORs the latitude span (in 1e-6 degree units) into the key is caught by three of those checks: span-blindness, the per-bound check, and the real-tile parent/child check. When measured on 2026-09-18, a fourth check, the since-removed `legacyCacheKey` one, also caught it. The same edit corrected the doc's quantum (about 3.7 cm latitude / 7.5 cm longitude, not 0.34 m) and dropped its "collision-free" overclaim.
- [x] Removed `GeoTileKey.legacyCacheKey` and the `TileDiskCache` zoom-0 fallback (review item D4, `docs/superpowers/reviews/2026-09-13-assessment/drafts/leases-histogram-analyst.md`), and made the `zoom` parameter of `GeoTileKey.init(region:zoom:)` required (2026-09-19). Before, an entry stored at zoom 0 answered a read at *any* zoom at the same origin, because `read(for:)`/`map(for:)` fell back to the zoom-0 key (entries at other zooms never did); the old default of `zoom: 0` made it easy to store at zoom 0 by omission. New harness checks (`main.swift:953-983`): the two leak checks (a zoom-0 entry must not answer a `read(for:)` or `map(for:)` at zoom 14) failed against the old code (`got 16 bytes`) and pass now, alongside positive controls that an entry round-trips and maps at its own zoom and that zoom-0 and zoom-14 entries at one origin stay separate. `cacheKey` is unchanged, so filenames written by `write(_:for:)` are the same. The string-keyed `map(forKey:)`/`write(_:forKey:)` that production uses (`TerrainTileOverlay.swift:812,858`) never had the fallback. Dead code either way, so no user-visible effect.
- [ ] Decide whether to delete the uncalled `GeoTileKey` type and its `TileDiskCache.read(for:)`/`map(for:)`/`write(_:for:)` overloads outright. Nothing in the app uses them. Keeping them costs the three public overloads and the harness checks on them (`main.swift:953-983`, the Morton section `1649-1731`, the GeoTileKey checks in `1733-1806`, and `2201-2241`); deleting them would make the identity decision above moot. The two `GeoRegion.cacheKey` checks inside `1733-1806` would stay, because the 3DEP cache keys on it (`ElevationService.swift:151`). Not started; needs a call.
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
