# Codebase review remediation (2026-10-14)

> **Status (2026-10-14):** complete. Commits 0be0a3b to 9583f7d on `main` after 5507203 (ten, one a step, not pushed
> when this was written). Harness 1605 to 1670 PASS / 0 FAIL at 9583f7d; Debug Simulator builds for the iPad Pro 11-inch
> (M5) after each UI step (7, 8, 9, 10) BUILD SUCCEEDED; `Tools/run-live-check.sh` compiles again (`LIVE_CHECK_BUILD_ONLY=1`)
> and was not run. No device build or run this task.

## Source

The owner's audit `lidar_explorer_codebase_review.md` (at the repository root, untracked, written against the code at
2d3869e/acfda68) listed five P0 defects, six P1 shader and rendering defects, two P1 memory and cache gaps, two P2
feature gaps and four hygiene items, with a ten-step ordered checklist. This record keeps the substance of that
checklist so the repository stands on its own: what each item was at HEAD, what changed, how it was checked, and where
the audit's reading of the code was wrong (five of its items were already in place or described code that does not exist).

The rule throughout was the project's: a failing check first (red), the fix, the section green, the full harness green,
an `xcodebuild` Simulator build where a file outside the harness's list changed, one commit a step.

## Steps

### Step 1 (BUG-01), curvature scalar plane, 0be0a3b

Real. The curvature kernel writes `float2(profile, planform)` into an `.rg32Float` plane and both result assemblies in
`MetalTerrainPipelineActor` wrapped it as 4 bytes a pixel, so `ScalarPlane.values()` read the window's west half as
interleaved pairs: the analytical curvature raster and its GeoTIFF export carried profile curvature over half the view,
planform over the other, and nothing east of the centre. `ScalarPlane` gained `channels` and `value(x:y:channel:)`,
`values(channel:)` gathers a two-channel plane, and the two assemblies pass the surface's own `bytesPerPixel`.
Checks: J compares both channels to the CPU reference over the whole window and at the platform's east rim; C8 reads
the mound's flat top as exactly zero and all four rims as bending; E2 exports the curvature file. Red first: four of the
five new checks failed (worst |diff| 0.51, the west rim read 0).

### Step 2 (BUG-02), platform mound volume, 0edef54

Real. `ElevationTransectEngine.computeMetrics` integrated the section over the whole diameter and applied Pappus's
half-section factor 2 pi, doubling every mound's earthwork volume. Now pi r A. Check: the 20 m platform's volume against
its frustum's (top 10 m, base 10 m plus the 25 degree flank's run, 2.8 m high), within 10 %: 3026 m³ before, 1514 m³
after, for a frustum of 1514 m³.

### Step 3 (BUG-03), dual-scale sky-view skirt, 7b4dd71

Real, with a detail the audit had wrong: `encodeSkyView` always passes the macro radius (the audit said only under a
blend weight below 1), and the kernel's macro march is gated on the blend weight. `TerrainTileProvider.neighbourhoodRadius`
reached 15 m for sky view, the product and the shading overlay alike, while the kernel marched macro rays to 60 m and
stopped at the raster's edge. `skyViewRadius(_:)` gives the macro radius while the blend lets it count. Check B17: a
56 m tower 35 m past a seam, the centre tile's east column against its neighbour's west column, 255 against 224.5
before, 225.5 against 224.5 after. At z19 the skirt is now the whole neighbour (the builder caps a skirt at one tile),
so the analysis raster of a sky-view tile is about 3.4 times larger; the C6 budgets held (sky view 2.2 ms at z19).

### Step 4 (BUG-04), the stitch race, e3bc4b0

Half real. The in-memory race was as described: a neighbour landing while a tile was being shaded cleared the tile's
`rendered` (already nil) and marked it stale, the renderer's reload then found the picture the in-flight render had
cached without that neighbour, and the tile stayed unstitched. `CachedTile.neighbourRevision` counts neighbour
arrivals and `tileImage` keeps a picture only under the count it started with; the renderer's `markStale` already
marks an in-flight tile, so the reload needs nothing more (an earlier draft re-inserted the key into the stale set,
which made a third render; dropped). The audit's other half, a rendered-tile disk cache written with partial
neighbourhoods, does not exist at HEAD (no `renderedDiskCache`, no `Caches/RenderedTiles`). Check B18 gates the
neighbour's fetch on the tile being cached and holds the GPU with a 3072² sky-view render so the tile's render lands
late: the reload served the unstitched picture before, the stitched one after, on every run. B10 now drains its burst's
stale tiles as the renderer does (23 of 24 shaded again), which is the cost of the fix: a tile whose neighbour lands
mid-render is rendered twice. A settle window for neighbour-driven reloads would trim that; not done.

### Step 5 (BUG-06), the COG byte reader, 2097e64

Real, and the reader had no harness checks at all. New `COGReaderChecks` (Q1-Q5) builds tiled Float32 TIFFs in memory
and serves them through a range-honouring `URLProtocol`. Found red: a file that ends inside its tag data (a server
clamps the range) trapped the whole harness process; -12000 m and 1e38 survived `fetchTile`. Changes: `extend` throws
`malformedHeader` on a short answer and refuses tag data beyond 64 MB; the byte readers answer zero outside their
buffer; a scalar tag with several values and a multi-band file (SamplesPerPixel 3, whose BitsPerSample entry holds an
offset the old code read as a bit depth) are `unsupportedLayout`; tile tables of a byte type are malformed; IFDs with
NewSubfileType bit 2 (GDAL's masks) are left out of the overview chain, which also refuses to loop; `fetchTile` voids
every non-finite value and every one outside -11000...9000 m, as the coordinator's CPU pass does. The audit's example of
-9999 m is inside that range and so a legitimate elevation; the fixture uses -12000.

### Step 6 (BUG-07 to BUG-10), compute and mesh accuracy, e77ad8d

- BUG-08, real but latent: `withSampleBytes` presented a leased raster as tight rows, and a lease's rows are padded to
  the linear texture alignment when the width is not a multiple of four floats (a 384 px tile decimated by three, as
  the owner's iPad asks); the reference elevation and the viewshed observer's ground read padding as ground and lost the
  last rows. The reader gathers such a lease tight, and the blit path sizes its image by the row stride. Check N5 reads
  a padded lease through both helpers (made internal for it): 7015 for 7029 and 2651 for 3514 before.
- BUG-07, not as described: the robust LRM kernels use the bound radius only to scale the planar fit's coordinates,
  and a fit's intercept does not depend on that scale; the audit's spatial cutoff (`spatialW = (u < 1) ? ... : 0`) is
  not in the kernel. The vertical pass now binds its own radius for symmetric conditioning, and a check pins the
  behaviour: the robust LRM of a 1 x 2 m scene renders as the transpose of its transpose at 2 x 1 m (it passed before
  the change too).
- BUG-09, not applicable: every derivative path (`TerrainDerivatives`, `RasterCompute`, `RasterGeometry(grid)`) uses
  `ElevationGrid.metersPerColumn`, the node-registered `width - 1` convention; the audit's `resolutionMeters` and
  `pixelSpacingMeters` do not exist.
- BUG-10, not applicable: `TerrainMeshBuilder` scales the heights before taking the slopes its normals come from, and
  T4 already checks that a 0.5 slope at 2x is a 45 degree face.

### Step 7 (BUG-05), the georeferenced map export, 70191a0

Real on every count. The PNG held Apple's basemap alone; now the shaded tiles the map draws are composited over it at
the map's opacity (`shadedComposite` takes a `background`, nil for transparent where no tile drew). The world file and
GeoJSON described the view, but a square snapshot of a wide view shows more ground than the view (MapKit widens one
axis), so they now describe the ground the snapshot drew, read off two points it drew (`snapshot.point(for:)`), with
the fitted region as a fallback. The GeoJSON is WGS 84 as RFC 7946 has it and names Web Mercator as the world file's
CRS. The badge names hemispheres by sign and the ground resolution in the display unit. The export takes the region on
screen now and says what share of the view the shading covers (`noteGeoreferencedExportCoverage`, shown as the GeoTIFF
export's notice is). The pure parts live in `GeoreferencedExportMetadata`, host-compiled and checked by E5 (the fitted
frame, the calibrated frame's round trip, the world file's six numbers, the GeoJSON's ring and properties, the badge in
both hemispheres and units, the pixel rect, and the composite transparent off the drawn tiles). The drawn image
itself is UIKit's: the Simulator build compiled it; nobody has looked at an exported PNG yet (see Unverified).

### Step 8 (BUG-11, BUG-12, GAP-01, GAP-02), 94cd393

- BUG-11, not applicable: `ViewshedOverlayRenderer.draw` already flips the context in place; there is no per-draw
  bitmap.
- BUG-12.1 and 12.2, not applicable: `SoilPolygon.contains` already excludes interior rings, and the map's
  `regionDidChangeAnimated` already reloads soils after a 400 ms settle.
- BUG-12.3, real: `loadSoils` ran an untracked task. It is now cancelled by the next, and a result is applied only when
  it is not cancelled. Found alongside: a GeoJSON the user imported was replaced by a USDA fetch the moment
  `showsSoils` went on (its `didSet`) and again at every move; the imported survey (`importedSoilSurvey`) now stands
  until soils are switched off. D6 reproduces the race (cell B cached on disk, cell A failing through the transport's
  retries, 0.1 s and more later) and the replacement; both mutants were caught.
- BUG-12.4, real: soil GeoJSON and historical map imports failed silently; `soilImportMessage` and
  `historicalMapImportMessage` now say why, under the import buttons in Settings.
- GAP-01, not applicable: `MetalTerrainPipelineActor` already pools textures (`texturePool`, keyed by size, format and
  usage, purged on a memory warning behind `canImport(UIKit)`). The audit's root cause for the device's memory growth
  is stale; STATUS's open item stands as it was.
- GAP-02, real: Settings' storage counted and cleared only the tile cache. It now shows "Other Caches" (the 3DEP
  service's raw rasters, the Terrarium and USGS basemap URL caches, the soil surveys) and "Clear Caches" clears all five;
  the soil cache is capped at 50 MB; the 3DEP memory cache promotes a hit (true LRU) and prunes its disk once in eight
  writes rather than after each; the two URL caches are one shared instance each under Caches (a bare `diskPath`
  landed in the working directory on a Mac, which is where the `terrarium-tiles/` and `usgs-tiles/` directories in the
  repository root came from; they were ignored by git and are now deleted). Two offline-store checks count and clear
  them.

### Step 9 (GAP-03, GAP-04), 2abca21

- Viewshed: the observer's eye height, the target height and the radius are Settings sliders; a placed viewshed is
  computed again once a slider rests (150 ms), with a reset.
- Tuning controls follow the products drawn (`drawnProducts`, `tunes(_:)`): the style's product, the layer draped over
  it with some weight, and sky view under sky-view shading. So a Local Relief layer over Raking Light gets its
  smoothing radius, the openness radius serves Positive and Negative Openness as well as RRIM, and sky-view shading
  brings the sky-view radius.
- An Advanced group holds the engine's finer parameters for the products drawn: the robust Tukey trend and its
  cutoff, the sky view's macro radius, blend weight and rays, the DoG scales, the occlusion distance, the ruggedness
  ceiling and the habitation radius.
- Every length, radius, band, earthwork volume (cubic yards in feet), curvature (per foot) and ground resolution reads
  in the display unit: `formattedLength`, `formattedVolume`, `formattedCurvature`, `formattedResolution`, in Settings,
  the profile's metrics and signature chips, the harvest view and the elevation file list.
- 2j checks the formatters, the tuning rule and the viewshed recompute. The display unit is kept in the defaults
  every model in the harness process shares, so 2j restores it (its first run left 2h reading feet).

### Step 10 (HYG-01 to HYG-03), 9583f7d

- HYG-01, real: the privacy manifest lacked the disk-space category (`OfflineStorageBudget` reads the volume's free
  space: E174.1, 85F4.1) and the system-boot-time category (the haptics and the sun dial read `systemUptime`: 35F9.1).
  Z1 reads the manifest and the sources and fails on a category the code calls but the manifest lacks (mutant
  caught); it also refuses a reason code Apple does not list for its category.
- HYG-02, real: the live check named a list of its own, six files short since 2026-09-20. `Tools/harness-sources.sh`
  now holds the flags and the app sources for both scripts; the live check builds in `build-review/live-check/` and
  `LIVE_CHECK_BUILD_ONLY=1` compiles it without the network. It compiled (0 errors); its checks were not run. Z3 pins
  the sharing.
- HYG-03, partly stale: `.gitignore` exists and already ignored `xcuserdata/`, `terrarium-tiles/` and `usgs-tiles/`;
  nothing under the two cache directories was ever tracked. What was real: one `xcuserdata` scheme file tracked from
  before the rule (untracked with `git rm --cached`), the dangling `TODO.md` reference in `project.pbxproj` (removed;
  Z2 checks every group-relative reference exists), and the two cache directories in the working copy (deleted; Step 8
  moved the caches under Caches). HYG-04 (a `LidarExplorerTests` target) was not in the checklist and was not done.

## Verification

| Gate | Result |
|---|---|
| `./Tools/run-harness.sh` | 1670 PASS / 0 FAIL, ALL CHECKS PASSED at 9583f7d (`build-review/step10-full.log`); a full run after every step (`step1-full.log` to `step10-full.log`), each green before its commit |
| Simulator build | `xcodebuild` Debug, iPad Pro 11-inch (M5), after steps 7, 8, 9 and 10: BUILD SUCCEEDED, no Swift warnings (`build-review/step7-sim.log` to `step10-sim.log`) |
| Live check | compiled through `Tools/harness-sources.sh` with `LIVE_CHECK_BUILD_ONLY=1` (`build-review/step10-livecheck-build.log`, 0 errors); not run |
| Red first | every behavioural fix had a failing check before it (logs `build-review/step*-red.log`); where a check was written with its fix (D6, Z1) the fix was reverted and the check seen to fail (`step8-mutant.log`, `step10-mutant.log`) |

## Unverified

- Everything UIKit draws: the exported PNG with the terrain composited (nobody has opened one), the Settings sliders,
  the Advanced group, the Viewshed section, the import messages and the storage rows. Compiled only.
- The live check's 67 network checks, not run since 2026-09-18.
- The device: nothing this task ran on the owner's iPad; the navigate-by-default device pass in `HUMAN_DO_THIS.md` is
  still pending from before.
- The real cost of the wider sky-view skirt and of the stale-tile re-render on the device during a pan burst.

## Follow-ups (not done)

- A settle window for neighbour-driven reloads, so a tile whose neighbours land over a burst is rendered once more
  rather than once per neighbour (B10: 23 of 24 tiles rendered twice).
- Run `Tools/run-live-check.sh` with the network and record its count in STATUS.
- A Simulator drive of Settings > Export > PNG + PGW, opening the PNG beside its world file in QGIS or by hand.
- HYG-04, a unit-test target for the UIKit-gated code, which the audit listed outside its checklist.
