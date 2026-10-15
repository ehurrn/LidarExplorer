# Second review remediation (2026-10-14)

> **Status (2026-10-14):** complete. One commit for the eight findings, 0f80567 on `main` after e830c14, then this
> record. Harness 1670 to 1695 PASS / 0 FAIL at 0f80567; Debug Simulator build for the iPad Pro 11-inch (M5)
> BUILD SUCCEEDED. The owner asked for all eight done and then one commit, where the first pass committed a step
> at a time.

## Source

The owner's second audit (`lidar_explorer_agent_review-2.md`, kept outside the repository), the first draft of
which was checked against HEAD finding by finding: eight of its nine items were real, the ninth (local GeoTIFF
voids and duplicate providers) was not, and a "pre-flight" section named code that does not exist. The second
draft dropped what was wrong; its one new claim, that a local file's voids fall back to the remote raster, matches
`fetchRaster`. Each item below says what the code did, what changed, and how it was checked. Red-first evidence came
by mutation: with the fixes for F-02 to F-06 reverted at once, nine of the new checks failed (`build-review/r2-mutant.log`);
the F-01, F-07 and F-08 checks pin new behaviour.

## Findings

### F-01, the georeferenced map's basemap and coverage

The snapshot always drew Apple's standard map while the app's default basemap is USGS shaded relief, and the coverage
notice measured the view's elevation while the image shows the view fitted into a square. Now: Apple imagery comes
through the snapshot's own configuration; a USGS basemap's tiles are fetched through `HillshadeTileOverlay`, the
overlay the map uses (so harvested tiles, the URL cache and the overzoom slicing answer as on the map), and drawn
over the snapshot at the map's basemap opacity; `GeoreferencedExportMetadata.basemapTiles(for:)` picks the zoom
whose 256 px tiles are as fine as the image's pixels, never finer, caps the count at 144 by going coarser, and
gives each tile's pixel rect. Coverage is measured over the square image's ground, on the tiles the composite
draws (`TerrainTileProvider.shadedCoverage(over:)`, a 64 x 64 lattice against the drawn tiles' regions), so a
landscape view's bare bands are reported. E5 checks the tile grid (zoom, edge-to-edge tiling, the cap), the
coverage shares (two thirds of a three-tile span with two drawn, all of a drawn tile, none of a bare one) and the
model's notice (a three-tile landscape view says its bands are bare; a square view inside a drawn tile says
nothing). The basemap drawing is UIKit's and compiled only; one `nonisolated(unsafe)` capture of the overlay,
whose loader MapKit already calls concurrently.

### F-02, a profile's voids

`profile(from:to:)` emitted 0 m before the first valid sample and the last value across later voids; the model shows
that profile. Both are NaN now; `ElevationProfile` already skips non-finite points and splits its ground runs on
them. B19: a profile that starts two tiles west of any loaded tile has 19 leading gaps, then the ground, with a
minimum of 120 m (the plain) where it read 0 before.

### F-03, the queries read back drawn tiles

The five query paths read only the in-memory cache. A `layers(touching:)` helper gives the tiles held plus the drawn
tiles the cache let go, read back from the disk tile cache or fetched again (`readBackOnScreen`, which View in 3D
and the exports already used). `inspectSpot`, `profile`, `transectMosaic` (now async, with `analyzeTransect` and
`previewTransect`), `viewshed` and a new `elevation(readingBackAt:)` for the model's spot and waypoint readings use
it; the sync `elevation(at:)` stays for the thalweg builder's closure. B19 turns the cache over with 170 tiles and
checks each path answers over the nine drawn tiles. This closes the queued "holes" item for the tiles the
renderer reports drawn; before the renderer's first region change it still names none.

### F-04, the location button

`didUpdateLocations` stopped updates on the first fix and `goToUserLocation` returned the remembered coordinate, so a
second tap in the field recentred on the launch position. Now every tap asks `currentLocation()`, which answers at
once only from a fix under 15 s old and otherwise waits for a new one (the manager still stops once it lands, so a
tap costs one fix), and falls back to the last known position when no fix comes. 2k drives the model with a
walking location stub: the second tap asks again and lands where the user walked to; no fix falls back; no fix ever
says unavailable. The `assumeIsolated` delegate hops were left: the manager is created on the main queue, which is
where CoreLocation calls back.

### F-05, neighbour invalidation for zero-radius products

`store` marked all eight neighbours stale under every micro-topography style. It now asks `analysisPlan(for:settings:)`
(the products, options, overlays, decimation and skirt `microPipelineImage` builds from, factored out) whether the
skirt reaches past the tile's own 4 px margin, which is the condition under which `AnalysisRasterBuilder` reads a
neighbour at all. The review's impact estimate was too high: at z18 and deeper the analysis is decimated 4x and
more to the native metre, so even a zero-radius product's one-cell Horn window is 8 to 16 tile pixels wide and
outruns the margin, and the neighbours are read. The saving is at z17 and coarser. B20: raking light and
curvature at z16 leave no tile stale, sky view and local relief do, and raking light at z19 does.

### F-06, the contrast scale and the openness radius

The contrast scale normalises the difference of Gaussians as it does local relief, and its slider showed for local
relief alone; it shows for both. Topographic Openness, shaded on the CPU, read a fixed 15 cells; it takes the
openness radius in its tile's cells (`opennessRadiusCells`, 1 to 64, the old 15 for no radius) and the model's
`tunesOpennessRadius` offers the slider for it as for RRIM and the openness split. B21: 5 m and 40 m shade the tile
differently (identical before). 2k: Topographic Openness offers the radius, Hillshade does not.

### F-07, mapped tiles and the analysis builder

A tile read from the disk cache was decoded into a heap array while the mapping was kept for the shader, and the
pointer-based `AnalysisTileSource` had no callers. `CachedTile.analysisSource` now hands the builder the mapped
pages where there is a mapping (the same pages the shader adopts) and the array otherwise, so the stitching of a
disk tile reads the file's pages. The heap copy stays: `ElevationGrid` owns an array and every CPU reader (spot,
profile, interpolation, the Horn stencil) goes through it; dropping the mapping instead would cost the shader its
zero-copy binding. The mapped pages are clean, file-backed and the kernel's to drop under pressure, so the cost is
address space more than resident memory. No new check: every provider check renders disk tiles through this path.

### F-08, embedded GeoTIFF georeferencing

A historical `.tif` with no sidecar was stretched over the view. `FloatTIFFDecoder.georeference(of:)` reads the pixel
scale, tiepoint and GeoKeys alone (the decoder's own parser, for a file whose pixels are RGB), and
`WorldFile(geoTIFF:)` makes a world file of them: degrees for a geographic model or WGS 84, metres for Web Mercator,
a file with no keys read as a world file would, any other projection (UTM scans) refused rather than misplaced; the
tiepoint is a pixel's corner (PixelIsArea) or centre (PixelIsPoint) and the world file names the centre. The importer
tries it when the sidecar is missing. D7 builds such TIFFs with the harness's TIFF fixture.

## Verification

| Gate | Result |
|---|---|
| `./Tools/run-harness.sh` | 1695 PASS / 0 FAIL, ALL CHECKS PASSED (`build-review/r2-full.log`) |
| Simulator build | `xcodebuild` Debug, iPad Pro 11-inch (M5): BUILD SUCCEEDED, no Swift warnings (`build-review/r2-sim.log`) |
| Mutation | the fixes for F-02 to F-06 reverted together: 9 of the new checks failed (`build-review/r2-mutant.log`) |

## Unverified

- The USGS basemap and Apple imagery in an exported PNG, and the location button on a device: UIKit and
  CoreLocation, compiled only. The PNG export Simulator drive proposed after the first pass covers the first.
- The read-back queries on a device after a memory warning (the harness turns the cache over by volume).

## Follow-ups (not done)

- The settle window for neighbour-driven reloads (proposed after the first pass) still stands; F-05 narrows the
  cost only at z17 and coarser.
- `ElevationGrid` backed by mapped storage, if the heap copy of disk tiles ever shows in a memory profile.
- Before the renderer's first region change `readBackOnScreen` reads nothing; the queued item to register the
  renderer's sources at creation covers it.
