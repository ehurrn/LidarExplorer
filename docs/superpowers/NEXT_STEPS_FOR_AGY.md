# Next steps — handoff to Antigravity (2026-09-12)

**State:** Part B of the plan is done and verified. Harness: 464 PASS / 0 FAIL. Live check: 67 / 0. `xcodebuild`: BUILD SUCCEEDED.
Branch: `feat/micro-topography-engine`. **Nothing is committed** since `5d106b9`, so commit only when the user asks.

Read first: `STATUS.md`, then `docs/superpowers/plans/2026-09-12-micro-topography-engine.md` (the authoritative plan).
Part B has an execution note listing where the code differs from the plan text.

## Loose ends (a few minutes)
1. Doc cleanup: some older notes still say "app does not compile / 424 PASS". Update them to the numbers above:
   - Done.
2. The plan's unticked Part B lines are commit steps only, which is intended. Two of those lines also contain a done step, so you can split them if you want:
   - B1 Step 5: the STATUS update is done, the commit is not.
   - B9 Step 4: the run passed, the commit is not.

## Work queue (do in order; tick checkboxes in the plan as you go)
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
  - E3: on-device Metal System Trace + memory. This needs a human and a device, so log it in `/Users/herren/dev/HUMAN_DO_THIS.md`.
  - E4: COG vs ImageServer check on a square footprint.
  - E5: commit/PR (needs user approval).

## After every task
- Run `./Tools/run-harness.sh /tmp/lidar-renders`. It must end with `ALL CHECKS PASSED`.
- For UI tasks, also run: `xcodebuild -project LidarExplorer.xcodeproj -scheme LidarExplorer -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build`. The harness does not compile the SwiftUI/MapKit views.
- Add any new source file to the compile lists in `Tools/run-harness.sh` and `Tools/run-live-check.sh`.
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
4. Run `./Tools/run-harness.sh /tmp/lidar-renders`. It must print `ALL CHECKS PASSED`, with no lower PASS count than before (464 now).
5. If the task touches `Presentation/` or `MapLayer/*View*`, also run `xcodebuild` and expect `** BUILD SUCCEEDED **`.
6. If it touches networking, run `./Tools/run-live-check.sh` (67 PASS now).
7. Tick the boxes in the plan and update `STATUS.md`: the verification table, Known issues and TODOs. Use measured numbers only.
8. If the plan text doesn't compile as written, fix the code. Then add a one-line "Where the code differs" note under that Part's header, like the Part B note.

### Part C — integration features
| Task | Plan heading | Key files | Done when |
|---|---|---|---|
| C1 habitation / SVF overlays, grazing raking, REM controls | `### Task C1` | `TerrainTileOverlay.swift` (`CompositeOverlays` from settings), `ViewerSettingsSheetView.swift`, `TerrainViewerModel.swift` | Habitation and sky-view overlays toggle on map tiles. Raking light has a 0–15° grazing slider and an azimuth control. REM exposes its range. Harness + build green. |
| C2 style chips | `### Task C2` | `ViewerBottomDockView.swift` | A horizontal `ScrollView` of chips replaces the 10-segment `Picker`; the selection drives `model.style`. Build green. |
| C3 transects | `### Task C3` | `ElevationTransect.swift`, `TerrainTileOverlay.swift` (`analyzeTransect`/`previewTransect` → snapshot the mosaic, analyse in `Task.detached`), `ElevationProfileView.swift`, `TerrainMapView.swift` | Analysis is off the provider actor. The chart uses per-bucket min+max decimation, so spikes survive. The panel floats and resizes with a drag handle (clamp its height). Apple Pencil draws a transect in any mode. |
| C4 wide viewshed | `### Task C4` | `TerrainTileOverlay.swift` `viewshed(at:)` (replace `stitchedRaster`), `MetalTerrainPipelineActor.viewshed` | Radius ≤ 5 km on a tiered mosaic ≤ 2048² (pick the zoom so extent/2048 ≥ tile GSD). Near-field is fine, far-field coarse. The mask aligns with the overlay region. Harness check: an occluding wall at 2 km. |
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
| E3 device trace | `### Task E3` | **Needs a human with an iPad.** Write the exact steps into `/Users/herren/dev/HUMAN_DO_THIS.md` (Instruments → Metal System Trace + Allocations; pan z19 LRM for 60 s; record FPS, GPU ms and peak memory < 500 MB), then skip ahead. |
| E4 open verification | `### Task E4` | COG vs ImageServer on a **square** footprint. Use a patient URLSession (ImageServer takes > 30 s cold). Agreement should be within ~0.5 m median. |
| E5 commit/PR | `### Task E5` | Only with user approval. Commit in slices: engine; coordinator; transects; integration + Part B fixes; UI; Parts C/D. |

### Don'ts
- Don't re-add a blanket 1.5 m seam filter. Same-zoom seams are continuous; only resolution seams get flagged (`isResolutionSeam`).
- Don't use `waitUntilCompleted`, and don't allocate textures per frame. Use the pipeline actor's pool and leases.
- Don't compute derivative planes eagerly in the provider (they were removed in B8 for memory).
- Don't move the viewshed pin programmatically while the user drags it (B3).
- Don't write outside `/Users/herren/dev`.
- If you're blocked, log it in `HUMAN_DO_THIS.md` and continue with the next task.
