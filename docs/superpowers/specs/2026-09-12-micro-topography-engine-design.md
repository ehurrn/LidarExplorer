# Micro-topography & terrain analysis engine

**Date:** 2026-09-12
**Status:** Engine (kernels, pipeline actor, COG coordinator, transect engine) implemented and harness-verified. Phase 4–5 integration partly implemented; calibration defects fixed in plan Part B (app builds, harness 464 / 0). Phases 6–7 pending. All uncommitted on `feat/micro-topography-engine`. See **Calibration** below; the requirement matrix further down predates that session.
**Plan:** [`docs/superpowers/plans/2026-09-12-micro-topography-engine.md`](../plans/2026-09-12-micro-topography-engine.md)
**Area:** `Core/Raster` (Metal), `Services/Elevation` (COG streaming), `Domain` (transects), `MapLayer` (tile provider/renderer), `Presentation` (dock, settings, panels)

## Calibration (2026-09-12, after the Antigravity session)

Measured on the working tree:

| Check | Result |
|---|---|
| `./Tools/run-harness.sh` | 424 PASS / 0 FAIL (now 464 after Part B) |
| `./Tools/run-live-check.sh` | 66 PASS / 0 FAIL (COG cold 0.79 s) |
| `xcodebuild` (iPad Simulator) | failed at calibration; **fixed in B1, BUILD SUCCEEDED** |
| Tile render through the provider (z19, 512 px, 3×3 cached) | LRM 10–21 ms · SVF 9 ms · raking 4 ms · RRIM 1.8 ms (legacy path) · REM **nil** |
| Provider memory after 9 tiles | 64 MB (~7 MB per tile: raster + six derivative planes) |

Seam probe (two cached z19 tiles, synthetic terrain, transect across their shared edge):

| Terrain | Seam filter off | Seam filter on (default) |
|---|---|---|
| Flat ground | 0 signatures, 0.00° slope within 3 m of the seam | 0 signatures |
| Platform centred on the seam | detected | detected |
| Platform whose plateau edge lies on the seam | detected | **dropped** |

Audit verdicts (Antigravity's reviewed spec): Blocker 1 partly addressed; Blocker 2 partly addressed;
**Blocker 3 refuted for same-zoom tiles** (the filter adopted for it causes false negatives); Majors 4, 5, 8
fixed; Major 6 open; Major 7 future; Minor 9 open.

Row updates that supersede the matrix below: 2E contours reach map tiles (habitation/sky-view overlays do not);
2F REM kernel ✅, REM tiles ❌; 2G habitation kernel ✅, not exposed; 3A drag + preview + signatures ✅, panel not
resizable, app build ❌; 3B pin + radius circle ✅, visibility mask never drawn ❌; 4.1–4.2 base layers ✅ (RRIM via
legacy path), habitation overlay ❌; 5.3 memory cap exists but excludes bitmaps, stitch buffers and GPU pools.
Defects: `STATUS.md` → Known issues. Fixes: plan Part B.

**Resolved in Part B (2026-09-12)** — harness 464 / 0, live check 67 / 0, app builds. The app compiles; REM tiles
render (flat water-plane fallback, thalweg plumbed); RRIM uses `compute_rrim`; the viewshed mask is drawn and follows
a dragged pin; the seam filter flags only resolution seams (the edge-on-seam platform is detected with it on); tiles
redraw in the background when a neighbour arrives; micro styles are analysed at native 1 m with per-product skirts
(z19 LRM tile 3.2 ms warm, was 10–21 ms); z18+ tiles stream from COGs first (cold z19 tile 0.94 s); derivative planes
are computed on demand (9 tiles < 25 MB, was 64 MB; budget 256 MB). Still open: viewshed range (C4), transect panel
and off-actor analysis (C3), overlays/controls in the UI (C1–C2, C5), device verification (E3).

## Problem

The source brief ("LidarExplorer Advanced Micro-Topography & Terrain Analysis Engine") asks for a feature-detection
pipeline that exposes degraded cultural earthworks, paleochannels and occupational terraces in USGS 3DEP 1 m
bare-earth DEMs: GPU kernels (LRM, RRIM, sky-view, raking light, micro-contours, REM, habitation mask), touch tools
(real-time transects with signature detection, a draggable viewshed), a multi-layer compositor (historical map wipe,
SSURGO soil hatching), and hard budgets (1024² LRM/RRIM < 8 ms GPU, 60/120 FPS, < 500 MB).

Before this work the app already streamed GPU-shaded MapKit tiles (fused Horn/display kernel), had an 8-direction
openness kernel, a two-stage RRIM, a per-target raymarch viewshed, a byte-range `COGByteReader`, and a tap-tap A/B
profile of 100 samples. None of the brief's analysis kernels, streaming coordinator, touch tools or overlays existed.

## Requirement matrix

| Brief § | Requirement | Status | Where |
|---|---|---|---|
| 1 | `actor ElevationTileCoordinator` for streaming/ingestion/preprocessing | ✅ | `Services/Elevation/ElevationTileCoordinator.swift` |
| 1 | `actor MetalTerrainPipelineActor` for dispatch + buffer management | ✅ | `Core/Raster/MetalTerrainPipelineActor.swift` |
| 1 | Sendable UI structures (samples, profiles, paths) | ✅ | `ElevationSamples`, `ProfileSample`, `TransectAnalysis`, `StreamedTile`, leases |
| 1 | UMA zero-copy (`bytesNoCopy` / shared), no PNG/CG round-trip of DEM | ✅ | linear R32F textures over COG storage / mapped cache; LZW decodes into that memory |
| 1 | Nodata normalised by a preparatory compute pass | ✅ | `normalize_nodata`, `normalizeNoDataInPlace(_:)` (runs at tile ingest) |
| 2 | Threadgroups 16×16 or dynamic via `threadExecutionWidth` | ✅ | dynamic (`threadgroupSize`) |
| 2A | LRM: horizontal + vertical Gaussian, residual, ±scale signed grey / diverging, flat = 128 | ✅ | `lrm_gaussian_horizontal/vertical`, `lrm_residual_to_texture` |
| 2B | RRIM `compute_rrim`: Horn slope, N-ray Φ/Ψ, I=(Φ−Ψ)/2, red chroma + I luminance | ✅ | one kernel, ray tables |
| 2C | SVF `compute_svf`: N azimuths, R_max, 1−mean(sin γ) | ✅ | γ clamped ≥ 0 |
| 2D | `dynamic_raking_hillshade`: az/alt/zFactor, ambient 0.15 | ✅ | |
| 2E | Procedural micro-contours with `fwidth` in a fragment shader | ✅ kernel / ⏳ map wiring | `terrain_composite_fragment`; map wiring = plan Task 15 |
| 2F | REM `detrend_river_elevation`, 1D thalweg or 2D surface, banded palette | ✅ kernel / ⏳ UI | thalweg drawing = plan Tasks 20, 22 |
| 2G | `evaluate_habitation_potential`: S ≤ 4°, S_max(30 m) ≥ 25° | ✅ kernel / ⏳ map wiring | jump flood |
| 3A | `sampleProfile(from:to:stepDistance:)`, 0.5 m bilinear, dz/dx, d²z/dx² | ✅ | `Domain/ElevationTransect.swift` |
| 3A | Platform-mound and ditch-and-berm signatures | ✅ | `TransectSignatureDetector` |
| 3A | Pencil/touch drag, floating resizable Swift Charts view | ⏳ | plan Tasks 19–21 |
| 3B | GPU viewshed: eye +2 m, target +0.5 m, ≤ 5 km, 720-step radial sweep | ✅ kernel / ⏳ UI | `viewshed_radial_sweep` + `compute_viewshed`; UI = Tasks 23–24 |
| 4.1–4.2 | Compositor: base (LRM/RRIM/raking) + contours + habitation mask | ✅ render pass / ⏳ tiles | Task 15 |
| 4.3 | Historical raster import, opacity + split wipe (slider + two-finger) | ⏳ | Tasks 25–26 |
| 4.4 | SSURGO polygons, hatch hydric clays vs well-drained sandy loams | ⏳ | Tasks 27–29 |
| 5.1 | 60/120 FPS during pan/zoom/light sweeps | ⏳ | Task 32 (device trace) |
| 5.2 | LRM and RRIM over 1024² < 8 ms GPU | ✅ | LRM 1.4–3.2 ms, RRIM 3.3–4.0 ms (M5 Pro, harness median) |
| 5.3 | Pool/heap recycling; < 500 MB during streaming | ✅ pool / ⏳ cache budget | pool capped 192 MB idle; tile-cache budget = Task 12 |
| 5.4 | Metal System Trace, zero wait bubbles, mapped buffers zero-copy | ✅ zero-copy proven / ⏳ trace | no `waitUntilCompleted` in new code; trace = Task 32 |

## Architecture

```
TNM product API ──► ElevationTileCoordinator (actor)
                      │  COGByteReader (actor): header + ranged tile GETs
                      │  TIFFLZWDecoder.decode(_:into:) ─► COGMappedStorage (page-aligned)
                      │  TIFFFloatingPointPredictor.decodeInPlace
                      │  MetalTerrainPipelineActor.normalizeNoDataInPlace  (GPU writes NaN into the same pages)
                      ├─► StreamedTile.raster        (native UTM tile → analysis, zero-copy)
                      └─► elevationRaster(for:)      (COGResampler → Mercator footprint → map tiles)

TerrainTileProvider (actor) ──► RasterCompute (legacy fused styles)
                            └─► MetalTerrainPipelineActor (micro styles)
                                  bind: linear R32F texture over shared/bytesNoCopy buffer   (device, Mac)
                                        private texture + GPU blit                           (Simulator)
                                  one command buffer: [nodata] → product passes → [habitation, SVF]
                                                      → composite render pass (fwidth contours) → [readback blit]
                                  outputs: SurfaceLease (recycles on deinit) → CGImage without copy
```

### Decisions and their reasons

1. **New actor instead of extending `RasterCompute`.** The legacy fused display path is hot, profiled and stable; the
   micro-topography passes share a pool, a queue and a surface mode of their own.
2. **Kernels read `texture2d<float>` (R32Float), bound without a copy.** `minimumLinearTextureAlignment` is 16 on
   M-series, so a raster binds zero-copy when `width*4 % 16 == 0` (all map tiles and COG tiles qualify); otherwise rows
   are restrided into a pooled buffer (`.copied`). The iOS Simulator raises on linear textures, so there the actor uses
   private textures with GPU blits in and out (`.blitted`) — bit-identical results, verified.
3. **LRM is a normalised separable convolution** (RG32F: weighted sum, weight), σ = R/2 truncated at R, sums relative
   to a reference elevation so Float32 accumulation stays sub-millimetre. Voids and edges never bias the trend.
4. **RRIM/SVF use CPU-built ray tables** (dx, dy, 1/d per sample) shared with the CPU reference: one `atan` per ray,
   and exact GPU/CPU parity testing. RRIM colour: `V = 0.5 + 0.5·I/range`, `S = slope/45°·multiplier`, `RGB = V·(1, 1−S, 1−S)`.
5. **Habitation mask via jump flooding.** "max slope in a 30 m disk ≥ 25°" ⇔ "nearest steep cell ≤ 30 m": seeds +
   JFA (+2 cleanup passes) on metric distance. Matches brute force exactly on the mesa test.
6. **Viewshed is two passes.** The 720-ray sweep stores each ray's prefix-max horizon; a per-cell pass looks the
   horizon up. The brief's θ_max rule, but gap-free at 5 km where rays are 44 m apart. 2048² at 5 km: 2.3 ms.
7. **Composite is a real render pass** (full-screen triangle), so `fwidth` gives screen-space 1 px contours; a density
   fade (`smoothstep(0.35, 0.9, fwidth)`) stops 0.25 m contours flooding steep banks. Rendered at `outputScale` =
   analysis decimation, i.e. back at display resolution.
8. **COG source is `prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/1m`**, discovered through
   `tnmaccess.nationalmap.gov/api/v1/products` (the brief's `usgs-lidar-public` bucket holds point clouds, not DEMs).
   Overlapping projects: those fully containing the region first, then newest `publicationDate`, up to three fill voids.
9. **COG → Mercator resampling** evaluates the exact UTM transform at 16-px block corners and interpolates inside
   (< 1 mm error, 256× fewer projections), placing pixel centres exactly where the ImageServer `exportImage` does.
10. **Transects run on a Sendable `ElevationField`** in a local metric frame (x east, y north); the map-side field is a
    `TileMosaicField` of cached tiles. Analysis of 10,001 samples takes 0.3 ms, so dragging re-analyses every change.
11. **Tile seams for neighbourhood styles** (radii of 15–30 m ≫ the 4 px skirt) are solved by stitching cached
    neighbours into a radius-sized analysis skirt, decimating oversampled 3DEP tiles to native 1 m first, and
    re-rendering tiles whose neighbours arrive later (Tasks 14–16).

## Findings worth keeping

- **Metal fast math breaks `atan2` on −0.0.** `atan2(dx, -dy)` with `dy == 0` returned the opposite half-plane,
  swapping due east/west on the observer's row. Fixed by writing offsets as differences (`observerY - row`, which is
  +0) and guarding the zero case. Any new kernel using `atan2` must avoid negating a possibly-zero value.
- **The 3DEP ImageServer takes > 30 s for a cold extent** (measured 31.4 s), past `HTTPTransport`'s 30 s request
  timeout; the COG path served the same footprint in 0.74–1.95 s cold and < 100 ms warm.
- **The ImageServer forces square pixels.** A non-square Mercator bbox comes back ~2 m wider than requested
  (served origin −10025747.08 vs requested −10025745.04). The live cross-check's 0.337 m mean |diff| used such a
  bbox; real map tiles are square, so this does not affect the app, but the square-region re-check is still open.
- **GPU timing for trivially cheap passes reads ~0.05 ms** (raking light over 1024²); sanity-check with wall clock.

## Deviations from the brief (intentional)

| Brief | Implemented | Why |
|---|---|---|
| RRIM ray count 16, radius 20 m | Same defaults, plus `minimumRayStepMeters` | Oversampled rasters need a floor on ray step |
| SVF `1 − mean(sin γ)` | γ clamped at 0 | Terrain below the horizontal hides no sky; keeps SVF ∈ [0, 1] |
| Raking intensity `max(0, N·L)` + ambient 0.15 | `0.15 + 0.85·max(0, N·L)` | Floor without exceeding 1.0 |
| Floating resizable **sheet** | Floating resizable **panel** over the map (Task 21) | iPadOS regular width presents sheets as centred form sheets that block the map |
| Separate horizontal/vertical outputs | RG32F intermediate | Exact normalised convolution with voids |

## Verification (current)

| Check | Command | Result |
|---|---|---|
| Offline harness | `./Tools/run-harness.sh <render-dir>` | 398 PASS / 0 FAIL (before the in-progress `ReliefStyle` change) |
| Live network | `./Tools/run-live-check.sh` | 66 PASS / 0 FAIL |
| GPU vs CPU parity | harness `MicroTopographyChecks` | LRM < 2 mm, openness < 0.02°, SVF < 1e-4, raking < 1e-4, REM < 1 mm, JFA exact, viewshed sweep ≤ 0.1% |
| Zero-copy | harness | GPU nodata pass rewrote sentinels in CPU-visible COG storage; `.zeroCopy` binding |
| Simulator path | harness `checkBlitParity` | bit-identical to linear path |
| Budget | harness `checkBudget` | LRM 1.4–3.2 ms, RRIM 3.3–4.0 ms, SVF 2.4, habitation 0.7, full composite 3.3 |
| COG streaming | live | GPU-normalised tiles, zero-copy bind, LRM 0.88 ms per native tile |

## Open risks

- Map-tile integration (stitching, stale refresh) is where visual seams or redraw storms would appear; Task 16 keeps
  old bitmaps drawing while replacements render to avoid flashes.
- SDA (verified 2026-09-12): `POST https://sdmdataaccess.sc.egov.usda.gov/Tabular/post.rest` answers in ~0.3 s when
  the area lookup uses `SDA_Get_Mupolygonkey_from_intersection_with_WktWgs84`; a direct `mupolygongeo.STIntersects`
  scan timed out at 60 s. `muaggatt.drclassdcd` / `hydclprs` exist; `JSON+COLUMNNAME` returns every value as a string.
  Remaining risk: service availability — the client caches each 0.01° cell on disk.
- On-device FPS/memory numbers exist only after Task 32; Simulator numbers are not representative.
