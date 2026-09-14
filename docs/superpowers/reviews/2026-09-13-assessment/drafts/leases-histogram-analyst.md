# Assessment draft: leased buffers (agy commits 96d4a40 + bdfad21) and the GPU histogram

Subsystem key: `leases-histogram`. Review items: **3B**, **3C**, **5.4**. There is also a defect-only audit of the rest of commit `bdfad21`.
Analyst date: 2026-09-13. Branch `feat/micro-topography-engine` at `bdfad21`.

Labels used below:
- **[verified]**: I read the code, or ran the scratch experiment named.
- **[inference]**: reasoning I did not execute.

No tracked file was modified. I did not run the harness or xcodebuild.

Experiments live in `build-review/scratch/leases-histogram/` (git-ignored). All ran on an Apple M5 Pro, macOS SDK 27.0, `metal` 32023.921:
- `bench_cpu.swift`: Metal linear-texture alignment on this host, plus the CPU cost of `ReliefRenderer.robustRange` (verbatim copy) against an exact sort and a 256-bin CPU histogram.
- `gpu_bench.swift` (uses `waitUntilCompleted`, which is fine in scratch but not in app code). It times three things:
  - the `leasedReliefProducts` round trip, using the real `horn_derivatives_and_relief` kernel from a scratch-compiled `TerrainKernels.metal`, against the CPU `hornSlopeAspect`;
  - a GPU atomic-histogram round trip;
  - a fresh page-aligned allocation against pooled buffer reuse.
- `atomic_histogram.metal`: an MSL `atomic_uint` histogram kernel, compiled at `-std` default, metal3.0, 3.1, 3.2 and 4.0 (macOS) and the iOS SDK default.
- `stride_replica.swift`: the leased-row write and read formulas, copied verbatim, for a width that is not a multiple of 4.
- `buflen.swift`: checks whether `MTLBuffer.length` equals the requested length.
- `geokey_legacy.swift`: compares the pre-bdfad21 `GeoTileKey` with bdfad21's `legacyCacheKey`, plus the bit-layout checks.

---

## 0. Provenance correction

The lead's hypothesis attributes the lease wiring to bdfad21. That is only partly right **[verified]** (`git log -S`, `git diff 8eebc8d..96d4a40`):

| Change | Commit |
|---|---|
| `AnalysisRasterBuilder.build(..., lease:)`, `AnalysisRaster.lease`, `ElevationSamples.leased`, the `bindElevation` `.leased` branch, and `TerrainTileProvider.microPipelineImage` acquiring `microPipeline.leasedSurface(...)` | **96d4a40** (agy) |
| Pool rewritten from actor-isolated with `Task` hops to lock-based and synchronous (`MetalTerrainPipelineActor.SharedBufferPool`, `RasterCompute.SynchronousBufferPool`); `RasterCompute.renderTile` output buffer pooled and leased (`TerrainBitmap.lease`); `TerrainTileProvider.inspectSpot` switched to `raster.leasedReliefProducts` | **bdfad21** (agy) |

Both commits are unverified agy work. Everything below verifies the code as it stands at HEAD.

---

## 1. Item 3C and action item 5.4: "wire leased buffers into the tile pipeline"

### 1.1 Is the review's "current gap" accurate?

**Stale. The wiring already exists (96d4a40), and part of the premise was wrong even before agy.**

- **[verified]** At `8eebc8d`, before agy, `AnalysisRasterBuilder.build` did not produce `[Float]` heap copies. It wrote straight into `COGMappedStorage(length:)`, which is page-aligned `posix_memalign` memory. `AnalysisRaster.raster` exposed that as `ElevationSamples.mapped`, and `MetalTerrainPipelineActor.bindElevation` adopted it zero-copy through `makeBuffer(bytesNoCopy:)`.
- **[verified]** There is no `terrain_derivatives` kernel. The micro-topography kernels (`compute_svf`, `lrm_*`, `compute_rrim`, …) compute everything they need from the R32F elevation texture inside the kernel. No derivative plane is assembled on the CPU on the micro pipeline path.
- **[verified]** The only `[Float]` copy-outs of derivative planes are in `RasterCompute.reliefProducts` (legacy). It is called only by `TerrainTileProvider.ensureProducts`, the CPU-render fallback, which runs when `renderTile` returned nil. That happens when there is no GPU, and then `leasedReliefProducts` returns nil too. **No live consumer gains from leased relief products.**
- **Measured gain of 96d4a40's lease over the old page-aligned storage** (`gpu_bench.swift`: fresh anonymous allocation plus first-touch fill, against refilling a pooled shared buffer): 0.027 vs 0.016 ms at 264², 0.101 vs 0.061 ms at 520², 0.221 vs 0.136 ms at 776². That is about 40–90 µs per tile shade, against 2–10 ms for the GPU product. **Harmless but negligible.**

### 1.2 Verification of the wiring as it stands

#### (a) Row stride and geometry

- **[verified]** `leasedSurface(for:width:height:)` rounds `bytesPerRow` up to `device.minimumLinearTextureAlignment(for:)`. On this M5 Pro that is **16 bytes** for `.r32Float`, `.rgba8Unorm` and `.rg32Float` (`bench_cpu.swift`). So `bytesPerRow == width*4` exactly when `width % 4 == 0`.
- **[verified]** `AnalysisRasterBuilder.build` writes row `oy` at `contents + oy * (lease.bytesPerRow / 4)`. That is correct for a strided layout.
- **[verified]** GPU binding. `bindElevation`'s `.leased` branch sets `sourceRowBytes = lease.bytesPerRow`. The linear path makes the texture with `bytesPerRow: sourceRowBytes` and `width/height = raster.geometry` (the builder's `outWidth`, not `lease.width`). **Kernels never read padding columns, even when `lease.width > outWidth`.**
- **[verified] The CPU readers assume tight rows.**
  - `MetalTerrainPipelineActor.withSampleBytes(.leased)` hands out `count*4` contiguous bytes.
  - `referenceElevation` (used by `encodeLocalRelief`) samples that range.
  - `sampleBilinear` (used by `viewshed` for the observer's ground height) reads `(cy*g.width + cx)*4`.
  - The blit (Simulator) path calls `blit.copy(... sourceBytesPerRow: sourceRowBytes, sourceBytesPerImage: sampleBytes ...)` with `sampleBytes = w*h*4`. That is smaller than `sourceRowBytes*h` when rows are strided.
  - The public `AnalysisRaster.pointer` also exposes strided memory to callers who index it tightly.
- **[verified] The defect is latent today.** `microPipelineImage` always requests a lease of exactly `outDimension × outDimension`. `outDimension` is always a multiple of 4: `AnalysisRasterBuilder.decimation` leaves `dest % (4f) == 0`, `skirtPixels` is a multiple of `2f`, and the harness asserts the decimated width stays a multiple of 4.
- **[verified] Concrete failing input** (`stride_replica.swift`): a lease with width 201 gives `bytesPerRow` 816 against a tight 804.
  - `referenceElevation` returns 198.51 against a true mean of 200.0.
  - `sampleBilinear` at (100, 200) reads **297 m against a true 300 m**, a 3 m observer-height error in a viewshed.

  Two other paths expose it: any future caller of `leasedSurface` with `width % 4 != 0`, and a device or Simulator whose alignment is larger than 16.
- **[inference]** On the Simulator, where alignment is unknown and not tested here, `sourceBytesPerImage` could also trip Metal validation if rows are strided.

#### (b) Lease lifetime

**Correct [verified].**

- The elevation lease is held by the `AnalysisRaster` local, and `render` appends it to `retained`.
- `render` awaits `complete(commandBuffer)`, which resumes from `addCompletedHandler`. Only then does it call `withExtendedLifetime(retained)`, recycle temporaries, and return.
- The lease's `deinit` runs when `microPipelineImage` returns, which is strictly after GPU completion.
- The display output leaves as a new `SurfaceLease`. `DisplayBitmap.makeImage` retains that lease in the `CGDataProvider` `dataInfo` and releases it in `releaseData`. The pixels therefore go back to the pool only when the last `CGImage` reference is gone (`CachedTile.rendered`, MapKit's renderer).
- `RasterCompute.renderTile` now does the same through `TerrainBitmap.makeImage`, which retains `lease ?? buffer`.

#### (c) Pool thread safety

**Sound [verified].**

- Every mutation of `SharedBufferPool.State` and `SynchronousBufferPool.State` happens inside `OSAllocatedUnfairLock.withLock`. `makeBuffer` runs outside the lock, and nothing calls out while the lock is held.
- The release callback runs synchronously from `deinit`. The earlier `Task { await self?.returnLease }` hop is gone, so `liveLeases` is exact the instant a lease dies.
- Recycling keys by `buffer.length`, and `MTLBuffer.length` equals the requested length (`buflen.swift`: requested 49153 gives length 49153, allocatedSize 65536). Obtain keys match recycle keys.

Two regressions from the split:
- **Low [verified] (defect D6):** before bdfad21 one actor counter, `idleBytes`, capped buffers **and** blit-mode textures together at `idleByteLimit` (192 MB). Now `SharedBufferPool.maxIdleBytes` caps buffers and the actor's `idleBytes` separately caps `texturePool`. In blit mode (Simulator) the idle ceiling doubles to 384 MB. On device (linear mode) textures are never pooled, so nothing changes there.
- **Low [verified] (defect D7):** `RasterCompute.SynchronousBufferPool` caps only the count per size (8), has no byte cap, and is never purged on memory warning. bdfad21 adds every `renderTile` output and `inspectSpot`'s seven planes to it. **[inference]** At 776² padded tiles (3x screens) that is up to 8 × 2.4 MB per distinct size, held until app exit.

#### (d) `inspectSpot`

**Performance regression with no functional gain (defect D1, medium) [verified].**

- Before bdfad21, `inspectSpot` computed a 3×3 Horn stencil per covering tile on the CPU (`TerrainTileProvider.hornSlopeAspect`).
- Now, for **every** cached tile whose `displayRegion` contains the coordinate, it awaits `raster.leasedReliefProducts(for: entry.grid)`. That is 7 shared buffers of the padded tile size, an elevation `memcpy`, a full-tile `horn_derivatives_and_relief` dispatch and a command-buffer round trip. It reads one pixel and drops the leases.
- It does this for every covering tile, even though only the finest is kept. The cache holds up to 160 tiles, and there is one covering tile per cached zoom, typically 3–10. `TerrainViewerModel.inspect` retries up to 3 times.
- The arithmetic is identical. The kernel source matches `hornSlopeAspect` line for line, and `gpu_bench.swift` gives GPU slope 55.1044 against CPU 55.1045.

| Padded tile | Fresh buffers | Pooled | CPU `hornSlopeAspect` |
|---|---|---|---|
| 264² | 0.57 ms | 0.20 ms | < 0.01 ms |
| 520² | 0.55 ms | 0.30 ms | < 0.01 ms |
| 776² | 0.75 ms | 0.26 ms | < 0.01 ms |
| 1040² | 1.16 ms | 0.34 ms | < 0.01 ms |

Plus 7 × plane bytes of buffer churn per tile on a pool miss (520² is 7.6 MB, 776² is 16.9 MB), GPU contention with tile shading on the `RasterCompute` actor, and suspension points inside the loop. The loop iterates a copy of `cache.values`, so this is safe, only wasteful. These timings are from an idle M5 Pro. **[inference]** An iPhone under tile load will be several times slower.

#### (e) Leaks

**None [verified].**
- If `build` returns nil, the lease is dropped and recycled.
- If `render` fails, `recycleBuffer(displayOut/scalarOut)` runs and the elevation lease drops at return.
- `renderTile`'s early returns drop the pooled buffer to ARC. It is freed, just not re-pooled.

### 1.3 Recommendation for 3C

**implement-modified.** No re-wiring is needed. Harden what agy wired, revert the `inspectSpot` hunk, and add the missing lease-path checks.

### 1.4 Design (for an engineer without this context)

Write the harness checks first (section 1.5); H2 fails today.

**Change A: make the leased elevation layout tight by construction** (`LidarExplorer/MapLayer/AnalysisRasterBuilder.swift`, `AnalysisRasterBuilder.build`)

- Replace the lease guard `if let lease, lease.width >= outWidth, lease.height >= outWidth` with:
  ```swift
  if let lease,
     lease.width == outWidth, lease.height == outWidth,
     lease.bytesPerPixel == MemoryLayout<Float>.stride,
     lease.bytesPerRow == outWidth * MemoryLayout<Float>.stride,
     lease.buffer.length >= outWidth * outWidth * MemoryLayout<Float>.stride {
      surfaceLease = lease
      storage = nil
      outPtr = lease.buffer.contents().bindMemory(to: Float.self, capacity: outWidth * outWidth)
      rowStrideFloats = outWidth
  } else { /* existing COGMappedStorage path */ }
  ```
- Update the doc comment on `ElevationSamples.leased` (`LidarExplorer/Core/Raster/RasterCompute.swift`): *"Rows must be tight (`bytesPerRow == width * 4`); CPU readers index `y * width + x`."*

**Change B: refuse strided leases at the binding instead of reading garbage** (`LidarExplorer/Core/Raster/MetalTerrainPipelineActor.swift`)

- In `bindElevation`, inside `if case let .leased(lease) = raster.samples`, add a first line:
  `guard lease.bytesPerRow == g.width * 4, lease.width == g.width, lease.height >= g.height else { return nil }`
  (`render` and `viewshed` then return nil, an explicit failure.)
- In `viewshed(...)`, `sampleBilinear` runs before `bindElevation`. Add the same stride test to the `.leased` case of `withSampleBytes`: `guard lease.bytesPerRow * lease.height >= count * 4, lease.bytesPerRow == lease.width * 4 else { return }`. The body is then never called with bad memory, and `sampleBilinear` returns nil.
- In the `.blit` branch of `bindElevation`, change `sourceBytesPerImage: sampleBytes` to `sourceBytesPerImage: sourceRowBytes * g.height`. The value is unchanged for tight rows.

**Change C: revert `inspectSpot` to the CPU stencil** (`LidarExplorer/MapLayer/TerrainTileOverlay.swift`, `TerrainTileProvider.inspectSpot`)

- Restore the non-async signature `public func inspectSpot(at coord: CLLocationCoordinate2D) -> SpotInspection?`. The call sites in `TerrainViewerModel.inspect`, `ProviderMicroChecks.checkProviderMemory` and `Tools/LiveCheck/main.swift` already `await` the actor, so they still compile.
- First pick the entry with the smallest `grid.groundSampleDistance` among those whose `displayRegion` contains `coord` and whose `grid.elevation(at:)` is non-nil. Then call `Self.hornSlopeAspect(grid, x: c, y: r)` **once** for that entry. No GPU work.
- Expected cost: microseconds. It removes 0.2–1.2 ms × covering tiles × up to 3 attempts per inspection, and the 7.6–17 MB per-tile buffer churn.

**Change D: bookkeeping** (`STATUS.md`)

- Tick "Wire `leasedReliefProducts` into a live consumer" as **won't do**: no live consumer benefits (see 1.1); the micro pipeline elevation lease was wired in 96d4a40.
- Replace the two lease test TODOs with the checks in section 1.5.

**GPU cost:** unchanged for tile shading. The `inspectSpot` GPU dispatches go away.

### 1.5 Harness checks (write first)

**H1** in `Tools/ViewerHarness/ProviderMicroChecks.swift`, `checkAnalysisRasterBuilder()`, after the existing `full` block (reuse its `tile(_:_:)` fixture and `all`). **Passes today.**

```swift
let leasePipeline = MetalTerrainPipelineActor()
if await leasePipeline.isAvailable(),
   let lease = await leasePipeline.leasedSurface(for: .r32Float, width: 16, height: 16),
   let leased = AnalysisRasterBuilder.build(center: tile(0, 0), skirt: 4, decimation: 1, cellSizeX: 1, cellSizeY: 1, neighbours: all, lease: lease) {
    check("a leased analysis raster adopts the lease, not new storage", leased.lease === lease && leased.storage == nil)
    let base = lease.buffer.contents()
    var wrong = 0
    for oy in 0..<16 { for ox in 0..<16
        where base.load(fromByteOffset: oy * lease.bytesPerRow + ox * 4, as: Float.self) != Float((oy - 4) * 1000 + (ox - 4)) { wrong += 1 } }
    check("a leased analysis raster stitches every pixel like page-aligned storage", wrong == 0, "\(wrong) wrong")
}
```

**H2**, same place. **Fails today, passes after Change A.**
- Acquire `let wide = await leasePipeline.leasedSurface(for: .r32Float, width: 17, height: 16)` and build with `lease: wide`.
- `check("a lease whose size or row stride differs from the analysis raster is refused", r.lease == nil && r.storage != nil)`.

**H3** in `Tools/ViewerHarness/MicroTopographyChecks.swift`: new `@MainActor func checkLeasedElevation(_ pipeline: MetalTerrainPipelineActor) async`, called from `runMicroTopographyChecks` just before `checkPool`. **Passes today on hosts with 16-byte alignment.**
- `let grid = platformScene()` (120×120, 1 m).
- `let lease = await pipeline.leasedSurface(for: .r32Float, width: 120, height: 120)!`.
- `check("a 120-wide lease has tight rows", lease.bytesPerRow == 480)`.
- Copy `grid.samples` into `lease.buffer.contents()` with `memcpy`, row by row, at `y * lease.bytesPerRow`.
- `let leasedRaster = ElevationRaster(samples: .leased(lease), geometry: RasterGeometry(grid))`, and `let arrayRaster = ElevationRaster(grid: grid)`.
- For `product in [.localRelief, .skyView]`, render both with default options and window.
- Assert:
  - `a.elevationBinding == .zeroCopy` when `pipeline.surfaceMode == .linear`;
  - the bit patterns of `a.scalar.values()` equal those of `b.scalar.values()`, element for element (NaN bit patterns included);
  - every `a.display.pixel(x:y:)` equals `b.display.pixel(x:y:)`.
- Tolerance: exact (same input bytes, same kernels).
- Check name: `"\(product.rawValue): leased elevation renders bit-identically to an array raster"`.

**H4**, same function. **Passes today; it is the missing SurfaceLease pool-reuse-while-reading check.**
- `let held = await pipeline.render(.localRelief, raster: leasedRaster)!`, then `let snap = held.scalar.values().map(\.bitPattern)`.
- Repeat 10 times:
  - `if let l = await pipeline.leasedSurface(for: .r32Float, width: 120, height: 120) { memset(l.buffer.contents(), 0x7F, l.buffer.length) }`, dropped immediately;
  - `_ = await pipeline.render(.skyView, raster: arrayRaster)`;
  - `_ = await pipeline.render(.localRelief, raster: ElevationRaster(grid: sceneGrid(width: 64, height: 64, gsd: 1) { _, _ in 5 }))`.
- `check("a held micro result survives pool churn of its own size", held.scalar.values().map(\.bitPattern) == snap)`.
- Drop `held` and the leases, then with **no sleep** (release is synchronous since bdfad21): `check("leases return synchronously", await pipeline.poolStatistics().liveLeases == 0)`.

**H5** in `Tools/ViewerHarness/main.swift`, "UMA buffer leasing" section, using `leaseGrid` (300×300). **Passes today; documents that Change C loses nothing.**
- For 50 interior cells on a stride, compare `TerrainTileProvider.hornSlopeAspect(leaseGrid, x:, y:)` with `leased.slope[y*300+x]` and `leased.aspect[...]`.
- Slope tolerance 1e-3°. Aspect tolerance 1e-2° on circular distance (`min(|a-b|, 360-|a-b|)`). Skip NaN-NaN pairs.

**H6** in `Tools/ViewerHarness/main.swift`, "Non-square raster grid" section. Add a **400×180** grid (72,000 ≥ `RasterCompute.gpuThresholdCells` 65,536).
- `check(..., products.backend == .gpu)`.
- Slope parity against `TerrainAnalysis.derivatives` within 0.01 for both `reliefProducts` and `leasedReliefProducts`.
- Rationale **[verified]**: the existing 200×120 case has only 24,000 cells, so `reliefProducts` runs on the **CPU** there. The GPU copy-out path has never been exercised on a non-square grid.

### 1.6 Do bdfad21/96d4a40 make the STATUS lease TODOs more urgent?

- **[verified]** Both STATUS TODOs are **already implemented and stale**:
  - "run one non-square grid (200×120) through both" is in `main.swift`, section "Non-square raster grid (200x120)";
  - "force pool-reuse-while-reading" is in `main.swift`, section "Lease pool reuse resilience" (commits 5d106b9/07ac07f, before PR #54).
- Both cover only `RasterCompute.MetalBufferLease`, and the 200×120 GPU copy-out case silently runs on the CPU.
- 96d4a40 made a **different** lease live in tile shading: `MetalTerrainPipelineActor.SurfaceLease` used as elevation input. Today it is exercised only indirectly, through `ProviderMicroChecks` scenes (`tileImage` → `microPipelineImage`), with no parity or churn assertion.
- So **yes, more urgent, but for the SurfaceLease path**. H1–H4 and H6 replace the stale TODOs.

---

## 2. Item 5.4: "replace heap copies in AnalysisRasterBuilder with leasedSurface; verify the harness"

- **Claim status:** stale, already implemented (96d4a40). There were no heap copies to replace (section 1.1).
- The baseline the lead measured before this assessment (549 PASS / 0 FAIL, Simulator build succeeded) already includes the leased path through `ProviderMicroChecks`.
- **Recommendation: reject as a separate task.** The remaining real work (Changes A–D, H1–H6) lives under 3C.

---

## 3. Item 3B: Metal compute histogram and robust range normalisation

### 3.1 Is the claim accurate?

**Partially accurate.** `ReliefRenderer.robustRange` does run on the CPU **[verified]**, but everything else in the premise is off.

- **One production caller [verified]:** `TerrainTileProvider.CachedTile.init` (`LidarExplorer/MapLayer/TerrainTileOverlay.swift`), once per tile **load** (network `shade` or disk-mapped decode). It does not run per frame, and not per settings change.
- **It is not "dynamic contrast stretching" of rendered products [verified].** Its outputs, `elevationLow`/`elevationHigh`, are CPU metadata:
  1. `elevationRange(in:)` unions them over visible tiles. `TerrainViewerModel.refreshElevationRange` passes the union to `ElevationRangePolicy.next` (9% hysteresis, nice-step quantisation), which picks one shared palette range for `.elevation` and REM.
  2. `microPipelineImage` uses `tile.elevationLow` as the REM fallback water surface.

  Both consumers need the number on the CPU.
- **By design, micro-topography products use fixed per-style ranges [verified].** `TerrainTileProvider.displayRange(for:)` has a doc comment explaining that a per-tile range "would normalise each tile against its own contrast … the seam would be obvious".
- **Nothing does a "float plane inspection or round-trip"** for display ranges. The CPU already owns `grid.samples`.

### 3.2 Numbers

| Padded tile | CPU `robustRange` (2048 stride samples + sort) | Exact full-sort p2/p98 | CPU 256-bin histogram, all samples | GPU atomic 256-bin histogram round trip |
|---|---|---|---|---|
| 264² | **0.054 ms** → [102.34, 196.75] | 3.6 ms → [102.31, 196.95] | 0.093 ms | 0.14 ms |
| 520² | **0.057 ms** → [106.75, 198.17] | 14.4 ms → [106.83, 198.16] | 0.34 ms | 0.17 ms |
| 1040² | **0.059 ms** → [103.68, 197.67] | 65.8 ms → [103.63, 197.66] | 1.40 ms | 0.14 ms |

The CPU columns come from `bench_cpu.swift`, the GPU column from `gpu_bench.swift`; synthetic terrain with 1% voids.

- `robustRange` is constant-cost and lands within 0.3 m of the exact percentiles.
- The GPU round trip is **~3× slower** than today's CPU call, before even counting the texture binding the provider would need. `CachedTile` holds `[Float]` or a mapped file, not a texture. It would also need an async command buffer per tile load.
- A 256-bin histogram adds bin quantisation: 0.39 m bins over a 100 m span.
- **MSL availability is not the blocker [verified].** `device atomic_uint *bins` with `atomic_fetch_add_explicit` compiles at MSL default, 3.0, 3.1, 3.2 and 4.0 on macOS, and on the iOS SDK default. The deployment target is `IPHONEOS_DEPLOYMENT_TARGET = 27.0`.
- **Seam risk [verified from design, inference on effect]:** feeding a per-tile p2/p98 into the composite pass reintroduces exactly the per-tile contrast seams that `ElevationRangePolicy` and the fixed style ranges exist to prevent.
- "Zero-copy real-time palette contrast" is already true for the view-level range. Changing it re-renders tiles through `pushSettings`, which is a policy choice, not a transfer cost.

### 3.3 Recommendation

**reject.**
- The cost is 57 µs once per tile load. The GPU alternative is slower and needs a readback.
- It would break the seam-free shared range design.
- No harness work is required. If a future product ever needs a view-level adaptive stretch, derive it from the existing per-tile extents on the CPU, as `.elevation` already does.

---

## 4. Defect-only audit of the rest of bdfad21

**D2 (medium): COG overview selection almost never selects an overview; labels and the `nativeDetailZ` rationale are wrong [verified arithmetic, inference on UX].**

- `ElevationTileCoordinator.elevation(for:targetSamples:)` computes `mpp = mercatorSpan / targetSamples` and maps it through `overviewLevel(forMetersPerPixel:)`: `<1.7` gives level 0, `<3.2` gives level 1, otherwise level 2.
- `TerrainTileProvider.fetchRaster` passes `targetSamples = pixels + 2*margin`, where `pixels = 256 × contentScaleFactor` and `margin = 4`. For the real inputs, at 38.66° N:

  | z | scale | samples | Mercator m/px | level | ground m/px (×cos lat) |
  |---|---|---|---|---|---|
  | 16 | 1x | 264 | 2.389 | 1 | 1.865 |
  | 16 | 2x | 520 | 1.194 | **0** | 0.933 |
  | 16 | 3x | 776 | 0.796 | **0** | 0.622 |
  | 17 | 1x/2x/3x | 264/520/776 | 1.194/0.597/0.398 | **0** | ≤0.93 |

- On every Retina device, z16 and z17 therefore fetch **native 1 m** COG tiles. Level 2 is unreachable.
- Despite that, `TerrainTileProvider.sourceName(forZ:)` labels them "3DEP 4m (Overview)" and "3DEP 2m (Overview)" (shown in `TileDebugView`).
- `nativeDetailZ` moved from 18 to 16 on the premise that overviews are fast. The deleted comment recorded ImageServer at about 3.5 s per cold z17 tile, and `FallbackElevationProvider` still falls back to `USGS3DEPService` wherever the COG declines. z16 shows 16× more tiles per screen than z18.
- The harness `CoordinatorChecks` passes only because it feeds synthetic mpp values (2.1, 4.2) and asserts constants (`nativeDetailZ == 16`).
- **Fix:**
  - Either restore `nativeDetailZ = 18` until a device trace shows z16–17 COG loads inside budget,
  - or select the level from **ground** sample distance relative to the COG's own `modelPixelScale`: `level = clamp(floor(log2(groundMpp / nativePixel)), 0, overviews.count)`, with `groundMpp = mercatorMpp × cos(lat)`.
  - Either way, derive the source label from the level actually used.
- **Harness:** a `CoordinatorChecks` case that builds the padded z16 and z17 tile regions at 38.66° N with `targetSamples` 520, and asserts the chosen level and label agree with the intended design.

**D3 (low, latent): strided `SurfaceLease` CPU readers.** See 1.2(a). Fixed by Changes A and B; covered by H2.

**D4 (low): `GeoTileKey` "backward-compatible disk cache fallback" is not backward compatible, and re-creates a cross-zoom collision.** Code: `LidarExplorer/Core/Geometry/GeoRegion.swift` `GeoTileKey.init(region:zoom:)`, `legacyCacheKey`; `LidarExplorer/Services/Storage/TileDiskCache.swift` `read(for:)`, `map(for:)`.

- **[verified]** None of these has a production caller. The grid cache keys by the string `gridCacheKey` (`grid_z_x_y_p_m`), which already includes zoom.
- **[verified]** (`geokey_legacy.swift`): the pre-bdfad21 key for SW (39.0, −106.5) is `8f3a3a3a3a3a3a3a`. bdfad21's `legacyCacheKey` for the same origin is `023ce8e8e8e8e8e8`. The fallback can never find an old file.
- That `legacyCacheKey` also **equals the new zoom-0 key**. Because `zoom` defaults to 0, any writer that omits `zoom` stores data that a zoom-18 reader at the same SW origin then receives through the fallback.
- **[verified] The bit layout itself is sound:**
  - 29+29 interleaved bits occupy bits 0–57 and zoom bits 58–63;
  - the extremes (±90, ±180) do not overflow;
  - 200,000 random 29-bit pairs give 200,000 distinct codes;
  - the quantum is 3.7 cm in latitude and 7.5 cm in longitude.
- **Stale leftovers:** the type's doc comment still describes the 32+32 "two-halves" interleave, and `interleave(lat:lon:)`/`dilate16To32` are no longer used by `init`, yet the harness still tests them.
- **Fix:**
  - delete `legacyCacheKey` and the fallback branches;
  - make `zoom` a required parameter;
  - update the doc comment;
  - repoint the "interleave is a bijection" check at `dilate32To64`;
  - resolve the STATUS decision "keys by origin only or folds in zoom/span".

**D5 (low): the COG IFD walk does not filter mask or odd IFDs.** Code: `COGByteReader.loadHeader` and `parseIFD`.

- **[verified]** Neither the SubIFD (tag 330) path nor the chained-IFD path reads `NewSubfileType` (tag 254). Neither checks that an overview's `sampleFormat`/`bitsPerSample` match the root, or that widths strictly decrease.
- **[inference]** A GDAL COG with internal masks orders its IFDs as full, mask, overview1, mask1, …, so `overviews[0]` would be a mask. `georeference(for:overviewLevel: 1)` would then fail and the tile falls back to ImageServer.
- `header(forOverview:)` silently returns `root.overviews.last ?? root` for a missing level. That duplicates native tiles under a different `TileKey.overviewLevel` in `tileCache`.
- **Fix:**
  - skip IFDs where `(tag254 & 4) != 0`;
  - require a float32 sample format equal to the root's, and a width smaller than the previous IFD's;
  - make `header(forOverview:)` return the clamped level it actually used, so callers key caches by that level.

**D6 (low): split idle caps.** See 1.2(c). **Fix:** move `texturePool`'s byte accounting into `SharedBufferPool.State` (one `idleBytes`, one cap), or cap the textures at `idleByteLimit − poolIdleBytes`.

**D7 (low): `RasterCompute.SynchronousBufferPool` has no byte cap and no purge.** See 1.2(c). **Fix:**
- add `maxIdleBytes` (for example 64 MB) alongside `maxBuffersPerSize`;
- add `func purge()`, called from `TerrainTileProvider.evictUnderPressure` through a `RasterCompute.purgeIdleBuffers()` actor method.

**D8 (low): GeoTIFF export filename can collide [verified].** Code: `TerrainViewerModel.exportCurrentRegionAsGeoTIFF`.
- The filename `LidarExplorer_%.4f_%.4f_z%d.tif` has no timestamp, unlike `GeoTIFFWriter.writeGeoTIFF`. Re-exporting the same view atomically replaces a file an open share sheet may still reference.
- It duplicates the degenerate-bounds guard that `GeoTIFFWriter.export` already performs.
- It sets `self.exportURL` even though `ViewerTopBarView` also sets it.
- The picker wiring in `ViewerSettingsSheetView.exportSection` is otherwise correct.
- **Fix:** call `GeoTIFFWriter.writeGeoTIFF(grid:)` (timestamped) and drop the duplicate guard.

**`RayTableKey`: no defect [verified].**
- Every `RayTable` and `DualRadiusRayTable` constructor input is in the key, and the two caches are separate dictionaries.
- `bitPattern` equality treats −0.0 and +0.0 as different keys, which can only cause a cache miss.
- Eviction at more than 32 entries is unchanged.

**Test-coverage note (low):** the STATUS lease TODOs are stale, and the 200×120 `reliefProducts` check runs on the CPU. See 1.6 and H6.
