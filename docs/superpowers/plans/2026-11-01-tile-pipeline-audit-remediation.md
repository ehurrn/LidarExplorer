# Tile Pipeline Audit Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Status (2026-11-02):** complete, executed inline in the session that wrote it, on branch
> `claude/tile-pipeline-audit-2026-11-01` from `main` at 8283fef (the merge of PR #58 plus its record commit), one
> commit per task from 3af1259 (Task 2) to 294148f (Task 7), then the record. Harness 1869 to 1926 PASS / 0 FAIL,
> ALL CHECKS PASSED, every check red first; the builds: see Verification. The owner pasted an audit (2 blockers, 5 majors, 4 minors; "concurrency, memory-transfer, and
> render-scheduling bottlenecks in `TerrainTileOverlay.swift` and the MapKit/SwiftUI bridge") with no words of their
> own. Every claim was located in the code at 8283fef before any task was written; the verdicts are in the table
> below. The audit's line numbers are off by about 170 lines (its `fetchRemoteRaster` at 1838-1868 is at 1671-1731),
> so each claim was found by symbol, not by line. Each task's code is written red-first in the session and recorded
> under "Where the code differs from this text" as it lands.

**Goal:** Take the audit's confirmed findings out of the tile pipeline: a culled tile's native fetch stops at once
rather than at the 2 s deadline or the fetch's end; the eight-upgrade cap holds under a burst and a tile past it is
answered with a stand-in rather than waiting the ImageServer out; GPU shading is admitted a few tiles at a time so a
flick's swept-past tiles and a dial drag's superseded steps never reach the GPU; every fetched raster is born in
page-aligned pages, so the first shade of a network tile is zero-copy and the second-shade copy on the actor goes; a
Terrarium stand-in neither invalidates its 1 m neighbours nor feeds their skirts; a relight keeps a sun-invariant
layer over a sun-lit base as it keeps a sun-invariant base under a sun-lit layer; the robust extent reads a paged
raster in place; and the Tile Activity log names the COG level a z16/z17 tile really reads.

**Architecture:** Nothing is restructured. The provider gains a FIFO admission gate for shading (a counter and a
queue of continuations) and a queue of upgrades waiting for a slot; `first(of:within:)` learns to wake on
cancellation; a `PreparedBase` can now stand for either layer of a composite; the grid producers in the services
write into `COGMappedStorage` pages through one helper. Everything else is a condition added to a line that exists.

**Tech Stack:** Swift 6 (`-strict-concurrency=complete -default-isolation MainActor`, `NonisolatedNonsendingByDefault`,
`InferIsolatedConformances`), Metal, MapKit, SwiftUI. Verification: `Tools/run-harness.sh` (host-compiled; `HARNESS_ONLY=`
for a section) and the Simulator `xcodebuild` in `STATUS.md` for every UIKit/SwiftUI file.

---

## The audit's claims against 8283fef

| # | Claim | Verdict at 8283fef | Task |
|---|---|---|---|
| B1a | Cancelling a tile's load (`cullTiles`) neither cancels `native` nor wakes `first(of:within:)`; the cancel reaches `native.cancel()` only when the 2 s budget runs out, or, on the `else` branch, when the whole fetch has returned | **Confirmed**: `first(of:within:)` suspends on a continuation nobody resumes on cancellation, and `await native.value` is not interrupted by it (the function's own comment says so). The window is 2 s for a prompt request and the fetch's whole length for the others (a tile asked for while eight upgrades run, the read-back, the harvester). The coordinator and the ImageServer client honour cancellation once it reaches `native` (T6, T15), so the gap is the suspension alone. | 2 |
| B1b | `upgradeLimit` is checked before the race, not at the deadline: a burst of 35 tiles all passes `upgrades.count < 8` at t = 0 and all 35 register at t = 2 s; a tile asked for while eight run takes the `else` branch and waits the full fetch out with no stand-in | **Confirmed**: `registerUpgrade` does not re-check the limit; the `else` branch awaits `native.value` with no Terrarium stand-in. The counter-proposal is taken, with a queue: a stand-in whose upgrade found no slot waits for one, and the next slot freed (`completeUpgrade`, `cancelUpgrades`) starts it while the tile is still wanted. | 2 |
| B2a | No bound on concurrent GPU shading: a dial step encodes every visible tile's command buffer at once; the stitching bursts onto the cooperative pool | **Confirmed for the GPU queue, declined as stated, taken for another reason**: `MetalTerrainPipelineActor` encodes one tile at a time but `complete(_:)` suspends the actor until the GPU finishes, so a burst commits every tile's command buffer back to back. Whether that starves the compositor is a Metal System Trace question (STATUS 2026-09-14 B10 measured the lease peak and recommended no gate; E3 is still the owner's). What a gate does settle without a trace: a tile waiting for admission is cancelled by the cull before any GPU work is committed for it (a flick asks for tiles it sweeps past), and a tile admitted during a 20 Hz dial drag is shaded under the settings current at admission rather than at request, so the GPU never queues a step the dial has left. The detached stitching is bounded by the cooperative pool's width already. | 3 |
| B2b | `setNeedsDisplay` per tile completion; the second, zoom-scale-agnostic call on `.drawnButStale` | **Declined**: MapKit draws a tiled overlay tile by tile whatever rect is invalidated, so coalescing the calls into one rect redraws the same tiles (and, for a union, tiles not yet landed, with their placeholders again); the call itself marks a rect dirty and is not measured as a cost. The all-scales call has been there since 75e85f1 (2026-09-14) for the stale draw; removing it on an unmeasured claim risks a stale image at another scale. | none |
| M1 | A network tile's first shade copies its heap array into a fresh `MTLBuffer`; its second shade does a synchronous `mmap` + `memcpy` on the provider actor; a micro-topography style never promotes it and readers copy paged grids back to the heap | **Confirmed for the two copies**: `alignedForShading` promotes at `shades >= 1` on the actor, and `RasterCompute.renderTile` copies an `.array` into a shared buffer. The cheapest fix is upstream: `StreamedRaster.grid` already copies the resampler's `COGMappedStorage` pages onto the heap for nothing; `ElevationService.makeGrid` and the two Terrarium cuts write a `[Float]`. All of them can write the pages directly. **Wrong on the third point**: `elevationExtent` is memoized per entry, so a paged grid is copied once, not repeatedly (fixed by M4 anyway). | 4 |
| M2 | A Terrarium stand-in's arrival bumps its eight neighbours' `neighbourRevision` and re-shades them with the coarse skirt; the upgrade then re-shades them again | **Confirmed for the double re-shade, wrong on the skirt**: `store(_:for:)` marks neighbours stale for any tile whose analysis reaches past the 4 px margin, stand-in or not (TP6's red run pushed both native neighbours stale on a stand-in's arrival), but no native skirt ever read a stand-in: a stand-in is its tile's share of a 256 px Terrarium ancestor (16 px at z19, 128 px at z16) and `AnalysisRasterBuilder.build` takes a neighbour only in the centre's shape, so it was already "missing" (NaN beyond the margin, a void to every kernel). The counter-proposal is taken for the invalidation, and the skirt skip is written down as a rule rather than left to the shape. | 5 |
| M3a | `RelightCache` keeps a sun-invariant base under a sun-lit layer but not a sun-invariant layer over a sun-lit base | **Confirmed** (`blendsSunInvariantBase`, `renderComposite(preparedBase:keepBase:)`): Sky-View or Local Relief draped over Raking Light re-encodes the layer on every sun step. The same mechanism serves the layer: `PreparedBase` stands for either product's display and scalar. The overlay exclusions mirror the base's. | 6 |
| M3b | `noteRendered` evicts bitmaps past 48 but leaves `relight` until the 256 MB budget; 60-80 relights pin the 192 MB surface pool | **Declined**: `idleByteLimit` caps the pool's *idle* memory, not live leases, so a kept relight pins nothing the pool needs; the budget sheds relights before any raster (`enforceMemoryBudget` step 1) and the memory warning drops those off screen (T18). A relight kept past the bitmap cap is what makes the tile cheap when a pan brings it back. | none |
| M4a | `elevationExtent(for:)` calls `tile.grid.samples`, a 1 MB heap copy for a paged tile, and sorts on the actor | **Confirmed for the copy**, once per tile (memoized), and the REM fallback at the same site. `robustRange` takes the grid and reads it in place. | 7 |
| M4b | `reloadData`, `visibleTileKeys`, `drawnTiles` and `keepsDrawn` still parse `z/x/y` keys; `memoryCacheSize` reduces 160 entries per store; `cacheOrder` removals are O(N) | **Declined**: a key parses in about a microsecond and the store holds at most 160 (`cacheLimit`), so each of these is well under a millisecond per call, at 20 Hz during a drag; T14 moved the one per-frame path (`cullTiles`) off parsing. Not worth the surface area. | none |
| M5a | `model.mapHeading` is written on every `mapViewDidChangeVisibleRegion`, at 120 Hz through a pan | **Stale**: the bridge writes only when `model.mapHeading != heading` (X9, 4cfa839); a pan leaves the camera's heading as it is. Floating jitter on a static heading is a conjecture with no device evidence; a deadband is not added for it. | none |
| M5b | `updateUIView` walks `MKMapView`'s subviews for the double-tap recognizer on every call | **Stale**: `Coordinator.mapDoubleTapRecognizer` is found once and kept (weak), `applyDoubleTapTouchTypes` walks only while it is nil (Task 6 of the 2026-11-01 plan). | none |
| m1 | `shadeBareTiles` is sequential and runs twice per export (coverage, then composite) | **Declined**: the second pass finds nothing bare unless more than 48 tiles touch the frame; the shades go through one GPU actor, so concurrency would overlap only the stitch; the coverage is measured before the composite because its notice is shown first. | none |
| m2 | `pendingGridWrites` (up to 64 MB) sits outside the memory budget; `encode` copies the samples into `Data` | **Declined**: the queue drains at utility priority in under a second and the budget counting it would shed bitmaps for a transient; `encode` already makes the one copy `Data` needs through `withUnsafeSamples`. | none |
| m3 | `canDraw` and `draw` take `store.lock` up to four times per missing tile | **Declined**: an uncontended `NSLock` costs tens of nanoseconds; a 35-tile pass takes about 10 µs of locking on MapKit's drawing threads. | none |
| m4 | `sourceName(forZ:)` labels z16 "3DEP 4m (Overview)" and z17 "3DEP 2m (Overview)" while 384 px and 512 px tiles read the 1 m level | **Confirmed** (STATUS "What exists" records it): the level is `overviewLevel(forMetersPerPixel:)` of the tile's Mercator metres per pixel, which depends on the tile size. The name takes the pixels. | 7 |

## Verification constraints

- `./Tools/run-harness.sh` must end `ALL CHECKS PASSED` after every task; `HARNESS_ONLY=<codes>` while iterating.
- Every file this plan touches is on the harness's `APP_SOURCES` list (`Tools/harness-sources.sh`): no UIKit file
  changes. A Simulator build runs once at the end (Task 8) because `TerrainTileOverlay.swift` has `#if canImport(UIKit)`
  code and `GeoreferencedExportService.swift` is checked only by xcodebuild.
- New checks go in `Tools/ViewerHarness/TilePipelineChecks.swift` (codes `TP1`...), registered in `runSections()` and in
  `harness-sources.sh`'s check list by `run-harness.sh`.

## File structure

- `LidarExplorer/MapLayer/TerrainTileOverlay.swift`: `TerrainTileProvider` (the fetch race, the upgrade queue, the
  shading gate, `store(_:for:)`, `microPipelineImage`, `elevationExtent`, `sourceName`), the two Terrarium cuts.
- `LidarExplorer/Services/Elevation/ElevationTileCoordinator.swift` (`StreamedRaster.grid`),
  `LidarExplorer/Services/Elevation/ElevationService.swift` (`makeGrid`), a new
  `LidarExplorer/Services/Elevation/PageAlignedElevationGrid.swift` (the helper over `COGMappedStorage`).
- `LidarExplorer/Core/Raster/MetalTerrainPipelineActor.swift` (`renderComposite(preparedModulation:keepModulation:)`),
  `LidarExplorer/Core/Raster/ReliefRenderer.swift` (`robustRange(of: ElevationGrid)`).
- `Tools/ViewerHarness/TilePipelineChecks.swift` (new), `TileLoadingChecks.swift` (T9 flipped), `CoordinatorChecks.swift`
  (the source names), `main.swift`, `Tools/harness-sources.sh`.

---

### Task 1: Plan, branch, baseline

- [x] Harness at 8283fef: ALL CHECKS PASSED (`build-review/harness-baseline-2026-11-01b.log`).
- [x] Branch `claude/tile-pipeline-audit-2026-11-01` from `main`.
- [x] This plan.

### Task 2: A culled fetch stops at once; the upgrade cap holds at the deadline

**Files:** `TerrainTileOverlay.swift` (`fetchRemoteRaster`, `first(of:within:)`, `registerUpgrade`,
`startUpgradeIfStandIn`, `cancelUpgrades`, `completeUpgrade`, `clear()`); test `TilePipelineChecks.swift` (TP1, TP2).

- [x] TP1, red: a prompt load cancelled 100 ms in has its native request cancelled within 500 ms (before: at the 2 s
  deadline); a harvest (no stand-in) cancelled 100 ms in likewise (before: at the fetch's end).
- [x] TP2, red: twelve z19 tiles asked for at once over a 2.5 s native source are all answered within the budget;
  eight upgrades run at the deadline and four wait; when the eight land, the four start and land; a tile asked for
  while eight run is answered with a stand-in within the budget, not after the fetch.
- [x] `first(of:within:)` resumes on the caller's cancellation (`withTaskCancellationHandler`), cancelling the native
  task and the timer; the `else` branch awaits `native` under the same handler. The pre-race check drops
  `upgrades.count < upgradeLimit`; `registerUpgrade` enforces it at the deadline, queueing the tile (its x, y, z,
  region, pixels, margin) when no slot is free; `completeUpgrade` and `cancelUpgrades` start the next queued tile that
  is still a cached, wanted stand-in; `clear()` drops the queue.
- [x] Harness green.

### Task 3: Shading is admitted a few tiles at a time

**Files:** `TerrainTileOverlay.swift` (`tileImage`, a `ShadingGate` on the provider, diagnostics); test
`TilePipelineChecks.swift` (TP3, TP4).

- [x] TP3, red: with the gate held at one slot by a diagnostic, twelve requests wait; cancelling eleven and releasing
  the hold shades one (the pipeline's built count and the shade counts say so).
- [x] TP4, red: a tile waiting at the gate while the sun turns is shaded under the new sun once, and its bitmap is
  kept (the request after it is a cache hit); the picture equals a from-scratch render at the new sun.
- [x] A FIFO gate of `shadingLimit = 4` around `shadeToImage`, entered after the fetch and before the settings
  snapshot, left on every path; cancellation while waiting returns nil as a culled tile does.
- [x] Harness green.

### Task 4: Every fetched raster is born in pages

**Files:** `PageAlignedElevationGrid.swift` (new), `ElevationTileCoordinator.swift`, `ElevationService.swift`,
`TerrainTileOverlay.swift` (`terrariumRaster`, `padByReplication`, the two merges, `alignedForShading`); tests
`TileLoadingChecks.swift` (T9), `TilePipelineChecks.swift` (TP5).

- [x] T9 retitled and TP5, red: a tile from a COG, from the ImageServer, from Terrarium (native and upsampled) is held
  in pages before its first shade; across two shades the provider makes no page-aligned copy (a diagnostic counter);
  the budget counts one plane.
- [x] `ElevationGrid.inPages(width:height:region:fill:)` over a `COGMappedStorage`; `StreamedRaster.grid` is built
  over the streamed storage with no copy; `makeGrid` voids into pages; the Terrarium cuts and the merges fill pages.
  `alignedForShading` stays for a heap grid from elsewhere (a `LEG1` cache file, a mounted file's merge).
- [x] Harness green (RasterStorageChecks N1-N4 hold: the pages are `mmap`).

### Task 5: A stand-in neither invalidates nor feeds its native neighbours

**Files:** `TerrainTileOverlay.swift` (`store(_:for:)`, `microPipelineImage`, a diagnostic); test
`TilePipelineChecks.swift` (TP6).

- [x] TP6, red: with the centre and its east neighbour native and the west slow, the west stand-in's arrival pushes
  nothing stale; the centre's analysis under Local Relief lists the west as missing and reads the east; the west
  upgrade's arrival pushes the centre stale once.
- [x] `store(_:for:)` skips the neighbour bump for a stand-in; `microPipelineImage` skips stand-in neighbours unless
  the centre is one.
- [x] Harness green.

### Task 6: A relight keeps a sun-invariant layer over a sun-lit base

**Files:** `MetalTerrainPipelineActor.swift` (`renderComposite(preparedModulation:keepModulation:)`,
`MicroTopographyResult.modulationDisplay/modulationScalar`), `TerrainTileOverlay.swift` (`blendsSunInvariantLayer`,
`RelightCache.layer`, `microPipelineImage`, the counters); test `TilePipelineChecks.swift` (TP7).

- [x] TP7, red: Sky-View draped over Raking Light, re-lit, stitches nothing and reuses the layer (a `reusedLayer`
  counter); the pixels equal a from-scratch render at the new sun within a level per channel; the cache is counted.
- [x] Harness green.

### Task 7: The robust extent reads in place; the source name says the level read

**Files:** `ReliefRenderer.swift`, `TerrainTileOverlay.swift` (`elevationExtent`, the REM fallback, `sourceName`);
tests `TilePipelineChecks.swift` (TP8, TP9), `CoordinatorChecks.swift`.

- [x] TP8, red: `robustRange(of: grid)` over a paged grid equals the array form.
- [x] TP9 (in CoordinatorChecks), red: `sourceName(forZ: 16, pixels: 512)` is "3DEP 1m"; at 256 px it is the 2 m
  overview (level 1); z17 at 256 px is 1 m; z15 is terrarium.
- [x] Harness green.

### Task 8: Full gates and the record

- [x] `./Tools/run-harness.sh` ALL CHECKS PASSED; Debug Simulator build; Release Simulator build; the signed device
  Debug build; the live check compiled.
- [x] STATUS.md (the harness and build rows, a TODO section, "What exists" line 69's label note), this plan's
  "Where the code differs", Verification and Unverified; `.agent/HANDOFF.json`; HUMAN_DO_THIS.md device items.

## Where the code differs from this text

- Task 2 (3af1259): as written. `PromptAnswer.cancelled` is the race's third outcome; `UpgradeRequest` carries what a
  queued stand-in's restart needs (x, y, z, pixels, margin, region); `startQueuedUpgrades()` runs from
  `completeUpgrade` and `cancelUpgrades(for:)`, and `cancelUpgrades` also dequeues the keys it is given; `clear()`
  drops the queue. The pre-race check keeps `upgrades[key] == nil` (an upgrade already running for the key is not
  raced again) and drops only the count. TP2 uses a 3.5 s native delay so the thirteenth tile's answer (a stand-in at
  2 s against a 3.5 s fetch) separates the two behaviours; the check takes about 7 s.
- Task 3 (cc824fc): as written, with one more property than the audit asked for: the settings snapshot moves after
  the admission, so a tile that waited through a dial step shades under the newest sun once (TP4, red on its own
  with the gate in place and the snapshot before it). The gate is FIFO; the audit's "prioritized by distance from
  viewport center" was not taken (MapKit orders its own requests, and the GPU is serial behind the gate anyway).
- Task 4 (8d3d238): the helper is `ElevationGrid.inPages(width:height:region:fill:)` and a `samples:` convenience,
  in `Services/Elevation/PageAlignedElevationGrid.swift` (a `nonisolated extension`; the type is Core's, the pages
  are Services'). The COG path needed no new allocation: `StreamedRaster.grid` had been copying the resampler's own
  `COGMappedStorage` onto the heap, and now builds the grid over those pages. `alignedForShading` stays for a heap
  grid from elsewhere (a `LEG1` cache file, a mounted file's raster) and counts its copies (`pageAlignedCopies()`);
  T9 keeps that path covered through the synthetic stub, which still hands the provider heap arrays on purpose.
- Task 5 (bd0246a): the "coarse skirt" half of M2 turned out not to happen at 8283fef: a stand-in is its tile's
  share of a 256 px Terrarium ancestor (16 px at z19, 128 px at z16) and `AnalysisRasterBuilder.build` reads a
  neighbour only in the centre's shape, so a native tile's skirt never saw one. The double invalidation was real
  (TP6's red run pushed both native neighbours stale on the stand-in's arrival). `store(_:for:)` now skips the bump
  for a stand-in; `microPipelineImage` skips stand-in neighbours for a native centre explicitly (the shape rule
  already did; the condition says why) and a stand-in centre still reads stand-ins of its shape (TP6 pins both).
- Task 6 (d734308): `PreparedBase` serves the layer unchanged (its doc says so); `renderComposite` takes
  `preparedModulation:keepModulation:` and returns `modulationDisplay`/`modulationScalar`; `RelightCache.layer`;
  `relightCounters()` gains `reusedLayer`. The overlay exclusions mirror the base's (`blendsSunInvariantLayer`).
- Task 7 (294148f): `robustRange(of:)` and `dataRange(of:)` take an `UnsafeBufferPointer<Float>` at the core, the array forms
  call them, and the grid form borrows the samples. `sourceName(forZ:pixels:)` derives the level from
  `mercatorMetersPerPixel(z:pixels:)` (the world's circumference over 2^z tiles of `pixels`), the ratio the
  coordinator takes from the padded region and samples; `Tools/LiveCheck/main.swift` passes 512.

## Verification

- Harness: 1926 PASS / 0 FAIL, ALL CHECKS PASSED at 294148f (`build-review/harness-task7.log`); a full run after each
  task (`harness-task2.log` 1880, `harness-task3.log` 1892, `harness-task4.log` 1903, `harness-task5.log` 1911,
  `harness-task6.log` 1920), all ALL CHECKS PASSED; 1869 at the 8283fef baseline (`harness-baseline-2026-11-01b.log`).
  Every new check was red first: TP1 (0 cancelled within 500 ms), TP2 (12 upgrades, the thirteenth tile at 3.52 s),
  TP3 and TP4 (the gate missing; then TP4 alone with the snapshot before admission: shaded under the old sun, bitmap
  not kept), TP5 (six legs red: heap grids from the COG, the ImageServer and Terrarium, one copy), TP6 (two native
  neighbours pushed stale on a stand-in's arrival), TP7 (`reusedLayer` 0 twice), TP8/TP9 (the old signature and labels).
- Builds at 294148f, 2026-11-02, with Xcode-beta: Debug for the iPad Pro 11-inch (M5) Simulator BUILD SUCCEEDED
  (`build-review/sim-debug-2026-11-02.log`), Release for the same Simulator in `build-review/DerivedData-release`
  (`sim-release-2026-11-02.log`), the signed device Debug build (`device-debug-2026-11-02.log`): all BUILD SUCCEEDED
  with no Swift warnings (the App Intents metadata note only). The live check compiled without the network
  (`LIVE_CHECK_BUILD_ONLY=1`, `livecheck-build-2026-11-02.log`), not run.

## Unverified

- Nothing has run on a device: `HUMAN_DO_THIS.md` "Device pass: the tile pipeline audit (2026-11-02)". The shading
  gate's depth of 4 is reasoned (a tile's encode against its 3-6 ms of GPU time), not measured; the Metal System
  Trace (E3) would set it. The relight's saving for a sun-invariant layer is shown by the harness's counters and
  pixels, not timed. The cull's prompt cancellation and the upgrade queue are seen against stubs with fixed delays,
  not the ImageServer; the queue's "still wanted" test reads the renderer's visible keys, which no harness check
  drives through MapKit.
- The Simulator was not run (builds only): the stand-in rule and the pages are exercised by the harness's provider,
  not by the map.
- No mutants were run this pass (the two previous passes ran one per task).

## Follow-ups (not done)

- The Metal System Trace under a 120 Hz flick and a dial drag (E3, the owner's): the one measurement that says whether
  the shading gate's depth of 4 is right, and whether B2b's coalescing is worth anything.
