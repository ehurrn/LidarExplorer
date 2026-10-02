> **Latest (2026-10-01): start with `STATUS.md`, then `.agent/HANDOFF.json` (local, gitignored), not this file.** Everything
> below this banner is a finished record kept as history: the architectural review remediation (2026-09-13, complete in
> 75e85f1, merged to `main` in 29e07af on 2026-09-14) and micro-topography Parts B-E (2026-09-12, merged in PRs #54 and #55,
> complete except E3, the device Metal System Trace, deferred since 2026-09-19 in 58bc2dc). Their counts (464, 549 and 561
> PASS; live check 67) were true then. The branch they used, `feat/micro-topography-engine`, is merged, and no local branch
> or fetched `origin` ref for it remains. The newest work is navigate by default
> (`docs/superpowers/plans/2026-09-28-navigate-by-default.md`, da96513..acfda68, record db4452c, 6b90b04, 2d3869e, all pushed
> to `origin/main`), waiting on the owner's device pass (`HUMAN_DO_THIS.md` at the repo root, local and untracked, "Device
> pass: navigate by default (2026-09-28)"). Open items, the 2026-09-21 audit's D-G included, are in `STATUS.md` TODOs.
> Before building on anything, run `./Tools/run-harness.sh` (1605 PASS / 0 FAIL at 2d3869e) and an `xcodebuild` Simulator
> build with `-derivedDataPath build-review/DerivedData`. The harness does not compile the 25 app files missing from its
> `SOURCES` list (the SwiftUI views, `TerrainMapView.swift`, `PencilMarkupOverlay.swift`, `ViewshedOverlay.swift`,
> `GeoreferencedExportService.swift` and others) or any `#if DEBUG` code. `Tools/run-live-check.sh` is stale: its source
> list (last changed 2026-09-12) lacks files `TerrainTileOverlay.swift` now needs, so it cannot compile as is (inferred, not
> run), and it builds in a `mktemp -d` outside the repo.

# COMPLETED PHASE — Architectural review remediation (2026-09-13 to 2026-09-14; 75e85f1, merged 29e07af)

**History: this phase and the one below the horizontal rule are both complete. For the current state read `STATUS.md`.**

## What is going on
The user supplied an external architectural review of the micro-topography engine. It is saved verbatim at
`docs/superpowers/reviews/2026-09-13-architectural-review.md`. **It was not written against this code:** several of its
claims describe problems that are already fixed, and at least one proposed fix is technically wrong. So every claim is
being verified against the code (and with numeric experiments) **before** anything is implemented.

## Checkpoint (update at each milestone)
- [x] Baseline verified, before any change in this phase (Claude Code, 2026-09-13):
  - `./Tools/run-harness.sh <dir>` → **549 PASS / 0 FAIL**, `ALL CHECKS PASSED`
  - `xcodebuild -project LidarExplorer.xcodeproj -scheme LidarExplorer -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' -derivedDataPath build-review/DerivedData build` → **BUILD SUCCEEDED**
  - Harness GPU medians at 1024² / 1 m: LRM 1.66 ms · RRIM 3.92 · **SVF 8.95** (STATUS.md recorded 2.4 before commit `96d4a40` added dual-radius SVF) · raking 0.05 · habitation 0.70 · full composite 9.79 (design brief: < 8 ms). Only LRM has a pass/fail budget assertion, which is why the harness did not catch the SVF regression.
- [x] Review saved to the repo (path above)
- [x] Verification: six per-subsystem reports → `docs/superpowers/reviews/2026-09-13-assessment/<key>.md` (analyst drafts in `drafts/`)
- [x] Summary assessment → `docs/superpowers/reviews/2026-09-13-architectural-review-assessment.md`
- [x] Remediation plan (authoritative task list, with checkboxes) → `docs/superpowers/plans/2026-09-13-architectural-review-remediation.md`
- [x] Implementation, tracked task by task in that plan's checkboxes and Progress log:
  - Part 1: Concurrency & Tile Lifecycle Hardening (clock-stamped store, settings bump, 3×3 Horn spot query, row alignment).
  - Part 2: SVF Optimization & Horizon Kernels (SVF Variant C drops to 5.34 ms; Directional Occlusion and Openness Split added).
  - Part 3: Tangential Curvature Stabilization, RG32Float scalar surface, Vector Ruggedness Measure (VRM).
  - Part 4: REM Thalweg Continuous Banded Distance Blending (eliminates meander cliffs), tail point densification.
  - Part 5: Robust Tukey M-Estimator LRM, Multi-scale Difference of Gaussians (DoG).
  - Part 6: Comprehensive Verification & Build. Harness PASS: 561 PASS / 0 FAIL. iOS Simulator build: BUILD SUCCEEDED.

Committed since: the review, the assessment reports and the plan in 49753d3, the implementation in 75e85f1, merged to `main` in 29e07af (2026-09-14).

## If you (agy) pick this up mid-way
- **Plan exists and is complete** (all 19 steps ticked in `docs/superpowers/plans/2026-09-13-architectural-review-remediation.md`): nothing here is left to pick up. (Its scratch experiments were in `build-review/scratch/`, local and since deleted.) The table below is the scope the per-subsystem verification used, kept as the record.

| key | Review items | Lead's preliminary findings (unverified hypotheses) |
|---|---|---|
| `curvature-vrm` | §1A, §2 VRM, §5.1–5.2 | Flat cells are already guarded: `slopeSq < 1e-7` gives curvature 0. Planform curvature is still unbounded just above the threshold (≈1/‖∇z‖). Tangential curvature is bounded and cheap to add. Possible defect: `encodeCurvature` writes into an `.r32Float` scalar surface, so the kernel's planform channel may be discarded. VRM is not present. |
| `rem-thalweg` | §1B, §5.3 | Mostly stale. `mt_thalweg_surface` already does clamped nearest-segment projection, and `ThalwegSegment` already exists in Swift and Metal. Still open: no max cross-valley distance, and a hard step seam where non-adjacent meander limbs meet. |
| `lrm-dog` | §1C, §2 DoG | The halo diagnosis is valid. The proposed bilateral filter (σ_r 0.5 m) likely erases features taller than σ_r from the LRM. A rolling-ball/top-hat filter or Hesse purged-DEM LRM are the candidate alternatives. DoG is not present. |
| `horizon-kernels` | §3A, §2 occlusion, §2 openness split | The SVF cost regression is real (8.95 ms). The review's mip + hardware-linear-sampler design is doubtful: buffer-backed textures have no mips, r32Float filtering is limited on iOS, and averaged mips underestimate horizons. `compute_rrim` already computes positive and negative openness but outputs only their difference. |
| `leases-histogram` | §3B, §3C, §5.4 | Leases were already wired by agy commit `bdfad21`, so verify that commit's correctness (stride, lifetime, pool locking, `inspectSpot` cost) rather than rebuilding. The GPU histogram looks low-value: `robustRange` has one caller and samples about 2k values. |
| `concurrency` | §4 | The generation token already exists in `TileImageStore`. Suspected real race: a tile still in flight when its neighbour arrives loses its stale mark and is never redrawn. Tile render Tasks are never cancelled on invalidate. |

---

# Previous handoff — micro-topography Parts B–E (2026-09-12, complete)

**State:** Part B of the plan is done and verified. Harness: 464 PASS / 0 FAIL. Live check: 67 / 0. `xcodebuild`: BUILD SUCCEEDED.
Branch then: `feat/micro-topography-engine`, since merged (PRs #54, 8eebc8d, and #55, 6d528f8, on 2026-09-12; 29e07af on 2026-09-14); no local branch or fetched `origin` ref for it remains. Everything here is committed.

Read first: `STATUS.md`, then `docs/superpowers/plans/2026-09-12-micro-topography-engine.md` (the authoritative plan).
Part B has an execution note listing where the code differs from the plan text.

## Loose ends (a few minutes)
1. Doc cleanup: some older notes still say "app does not compile / 424 PASS". Update them to the numbers above:
   - Done.
2. Done: every Part B step in the plan is ticked, and Part B is committed in 07ac07f.

## Work queue (DONE: every task below is ticked in the plan except E3's three device steps, deferred since 2026-09-19 in 58bc2dc; kept as the record)
- **C1:** habitation mask + sky-view overlays in the UI; grazing raking-light control.
- **C2:** replace the 10-segment style picker with dock chips.
- **C3:** transect panel. Make it resizable, use min-max chart decimation, and move analysis off the provider actor.
- **C4:** viewshed tiered Mercator mosaic out to 5 km. `viewshed(at:)` still uses `stitchedRaster` (3×3).
- **C5:** thalweg drawing UI. `TerrainStyleSettings.thalweg` is already plumbed.
- **C6:** per-zoom budget table.
- **D1–D2:** historical maps (world file import, opacity, split wipe).
- **D3–D5:** SSURGO soils:
  - Endpoint: POST `https://sdmdataaccess.sc.egov.usda.gov/Tabular/post.rest` with `{"query","format":"JSON+COLUMNNAME"}`.
  - Polygons: `SDA_Get_Mupolygonkey_from_intersection_with_WktWgs84`.
  - Attributes: `muaggatt.drclassdcd` / `hydclprs` (these come back as strings).
- **E1–E5:**
  - E1: release build.
  - E2: Simulator smoke run.
  - E3: on-device Metal System Trace + memory. This needs a human and a device: it is logged in `HUMAN_DO_THIS.md` at the repo root (local, untracked), section 'Open (deferred): E3', deferred since 2026-09-19.
  - E4: COG vs ImageServer check on a square footprint.
  - E5: commit/PR (needs user approval).

## After every task
- Run `./Tools/run-harness.sh` (or `./Tools/run-harness.sh build-review/renders` to keep the PNGs; nothing may be written outside `/Users/herren/dev/LidarExplorer`). It must end with `ALL CHECKS PASSED`.
- For UI tasks, also run: `xcodebuild -project LidarExplorer.xcodeproj -scheme LidarExplorer -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' -derivedDataPath build-review/DerivedData build`. The harness does not compile the SwiftUI views, `TerrainMapView.swift` or other UIKit/MapKit view code.
- The app target picks up every file under `LidarExplorer/` by itself (a synchronized folder). Add a new host-compilable file the harness must see to `SOURCES` in `Tools/run-harness.sh`. `Tools/run-live-check.sh` is stale (see the banner); repair or retire it before relying on it.
- Update `STATUS.md` with real measured numbers only, and only once the task is complete.

## Gotchas
- Swift 6 with default MainActor isolation:
  - New value types need `nonisolated`.
  - Copy a `var` into a `let` before capturing it in a `@Sendable` closure.
  - Don't send non-Sendable Metal objects to `nonisolated async` functions.
- Metal fast math: `atan2(y, -0.0)` returns the wrong half-plane. Write offsets as differences and guard zero.
- Keep analysis-raster widths a multiple of 4 so textures stay zero-copy.
- Don't claim a check passes without running it; Claude re-verifies on return.

---

## Detailed task guide

The plan already has step-by-step code for every task below. **Search the plan for the `### Task <ID>:` heading, follow the steps exactly, and tick each `- [ ]` as you finish it.** Find code by symbol name (e.g. `grep -n "func viewshed(at" LidarExplorer/MapLayer/TerrainTileOverlay.swift`), never by line number.

### Workflow for each task
1. Read the whole task section, from its `### Task` line to the next one.
2. Write the harness check first (add it to `Tools/ViewerHarness/ProviderMicroChecks.swift`, or the file the task names). Run the harness. The expected "red" is a compile error or a FAIL for the new check.
3. Implement.
4. Run `./Tools/run-harness.sh`. It must print `ALL CHECKS PASSED`, with no lower PASS count than before (1605 at 2d3869e; 464 when this was written).
5. If the task touches a file the harness does not compile (any not in `SOURCES` of `Tools/run-harness.sh`: the SwiftUI views, `TerrainMapView.swift`, `PencilMarkupOverlay.swift`, `ViewshedOverlay.swift`, `HapticFeedbackManager.swift`, `TerrainViewerModel+OfflineHarvest.swift`, `BackgroundWork.swift`, `GeoreferencedExportService.swift`, `LidarExplorerApp.swift` and others) or any `#if DEBUG` code, also run `xcodebuild` (with `-derivedDataPath build-review/DerivedData`) and expect `** BUILD SUCCEEDED **`.
6. If it touches networking: `./Tools/run-live-check.sh` (67 PASS on 2026-09-12) is stale and builds in a `mktemp -d` outside the repo, so do not run it as is; first repair it (build directory under `build-review/`, the missing sources, the harness's flags) or say what was not checked.
7. Tick the boxes in the plan and update `STATUS.md`: the verification table, Known issues and TODOs. Use measured numbers only.
8. If the plan text doesn't compile as written, fix the code. Then add a one-line "Where the code differs" note under that Part's header, like the Part B note.

### Part C — integration features
| Task | Plan heading | Key files | Done when |
|---|---|---|---|
| C1 habitation / SVF overlays, grazing raking, REM controls | `### Task C1` | `TerrainTileOverlay.swift` (`CompositeOverlays` from settings), `ViewerSettingsSheetView.swift`, `TerrainViewerModel.swift` | Habitation and sky-view overlays toggle on map tiles. Raking light has a 0–15° grazing slider and an azimuth control. REM exposes its range. Harness + build green. |
| C2 style chips | `### Task C2` | `ViewerBottomDockView.swift` (deleted in c519cda, 2026-09-26; the chips now live in `ShadingDockView.swift`) | A horizontal `ScrollView` of chips replaces the 10-segment `Picker`; the selection drives `model.style`. Build green. |
| C3 transects | `### Task C3` | `ElevationTransect.swift`, `TerrainTileOverlay.swift` (`analyzeTransect`/`previewTransect` → snapshot the mosaic, analyse in `Task.detached`), `ElevationProfileView.swift`, `TerrainMapView.swift` | Analysis is off the provider actor. The chart uses per-bucket min+max decimation, so spikes survive. The panel floats and resizes with a drag handle (clamp its height). Apple Pencil draws a transect in any mode (superseded 2026-09-28: the Pencil draws only with the ruler lit). |
| C4 wide viewshed | `### Task C4` | `TerrainTileOverlay.swift` `viewshed(at:)` (replace `stitchedRaster`; done in 6d6ea20, which removed it; the app's radius is fixed at 2500 m, `TerrainViewerModel.swift:1256`), `MetalTerrainPipelineActor.viewshed` | Radius ≤ 5 km on a tiered mosaic ≤ 2048² (pick the zoom so extent/2048 ≥ tile GSD). Near-field is fine, far-field coarse. The mask aligns with the overlay region. Harness check: an occluding wall at 2 km. |
| C5 thalweg drawing | `### Task C5` | `TerrainMapView.swift`, `TerrainViewerModel.swift` → `TerrainStyleSettings.thalweg` | Drawing a polyline in REM mode sets the thalweg and redraws tiles, which detrend along it. Clearing it falls back to the flat water plane. |
| C6 budget table | `### Task C6` | harness | The harness prints ms per product at z16–z20, and `STATUS.md` gets a table. Everything is < 8 ms at 1024² on the Mac. |

### Part D — historical maps and soils
| Task | Plan heading | Notes |
|---|---|---|
| D1 world files + import | `### Task D1` | Parse `.tfw/.jgw/.pgw` (6 lines: A, D, B, E, C, F). Downsample large images with ImageIO (`kCGImageSourceCreateThumbnailFromImageAlways`, max pixel size) so memory stays bounded. Pure parser tests go in the harness. |
| D2 historical overlay | `### Task D2` | Custom MKOverlay + renderer; opacity slider; split wipe by clipping the renderer's context to `x < wipeFraction`. UI needs `xcodebuild`. |
| D3 SSURGO model | `### Task D3` | Pure types plus drainage/hydric classification and WKT polygon parsing. Harness-testable with no network. |
| D4 SDA client | `### Task D4` | POST `https://sdmdataaccess.sc.egov.usda.gov/Tabular/post.rest`, body `{"query": "...", "format": "JSON+COLUMNNAME"}`. Get keys via `SDA_Get_Mupolygonkey_from_intersection_with_WktWgs84('POLYGON((...))')`, then join `mupolygon.mupolygongeo.STAsText()` and `muaggatt` (`drclassdcd`, `hydclprs`, which are strings). **`mupolygonWkt` is not a column.** Cache on disk per tile key. Add a live check in `Tools/LiveCheck/main.swift`. |
| D5 hatched overlay | `### Task D5` | Hatch density/angle by drainage class, legend, and the spot readout shows the soil unit. `xcodebuild`. |

### Part E — release
| Task | Plan heading | Notes |
|---|---|---|
| E1 release build | `### Task E1` | Same `xcodebuild` with `-configuration Release`. Zero concurrency errors. |
| E2 Simulator smoke | `### Task E2` | Boot the iPad Simulator, run the app, and try every style, transect drag, viewshed pin drag, REM thalweg, historical wipe and soils. Record the results in STATUS. |
| E3 device trace | `### Task E3` | **Needs a human with an iPad.** The exact steps (Instruments → Metal System Trace + Allocations; pan z19 LRM for 60 s; record FPS, GPU ms and peak memory < 500 MB) are in `HUMAN_DO_THIS.md` at the repo root (local, untracked; 'Open (deferred): E3', deferred by the owner on 2026-09-19); skip ahead. |
| E4 open verification | `### Task E4` | COG vs ImageServer on a **square** footprint. Use a patient URLSession (ImageServer takes > 30 s cold). Agreement should be within ~0.5 m median. |
| E5 commit/PR | `### Task E5` | Only with user approval. Commit in slices: engine; coordinator; transects; integration + Part B fixes; UI; Parts C/D. |

### Don'ts
- Don't re-add a blanket 1.5 m seam filter. Same-zoom seams are continuous; only resolution seams get flagged (`isResolutionSeam`).
- Don't use `waitUntilCompleted`, and don't allocate textures per frame. Use the pipeline actor's pool and leases.
- Don't compute derivative planes eagerly in the provider (they were removed in B8 for memory).
- Don't move the viewshed pin programmatically while the user drags it (B3).
- Don't read or write outside `/Users/herren/dev/LidarExplorer`: builds, logs and recordings go in `build-review/`.
- If you're blocked, log it in `HUMAN_DO_THIS.md` at this repo's root (local and untracked: edit it, never commit it; never `/Users/herren/dev/HUMAN_DO_THIS.md`) and continue with the next task.
