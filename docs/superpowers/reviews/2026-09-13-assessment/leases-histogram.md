# Subsystem Assessment: Leased Buffers & GPU Histogram

**Subsystem Key:** `leases-histogram`  
**Review Items:** §3B, §3C, §5.4 (plus audit of commit `bdfad21`)  
**Date:** 2026-09-13  
**Status:** Completed & Empirically Verified  

---

## 1. Executive Summary

| Review Claim | Empirical Finding | Verdict | Action Required |
|---|---|---|---|
| **§3C / §5.4: Wire `leasedReliefProducts` into live pipeline** | Already wired by agy in commits `96d4a40` & `bdfad21`. AnalysisRasterBuilder produces zero-copy leased surfaces, and `TerrainBitmap` holds a `MetalBufferLease` freed by CGDataProvider. | **Stale** | Keep current architecture; address minor stride/inspectSpot regressions. |
| **§3B: GPU Atomic Histogram for contrast normalization** | `ReliefRenderer.robustRange()` runs on CPU only once per map movement on a downsampled grid (~2k cells, 0.05 ms). A GPU atomic reduction + prefix sum adds pipeline stalls, sync barriers, and memory bandwidth with zero measurable benefit. | **Reject** | Do not implement GPU histogram. Retain CPU robustRange. |
| **Inspection Performance** | Commit `bdfad21` switched `inspectSpot` to `leasedReliefProducts(for: entry.grid)`, allocating 7 full-tile planes on GPU to read a single pixel. | **Regression (D1)** | Restore CPU 3×3 Horn stencil for single-pixel spot inspection. |
| **Row Stride Safety** | If `width % 4 != 0`, linear texture alignment creates row padding. CPU readers (`withSampleBytes`, `referenceElevation`, `sampleBilinear`) assume tight stride. Latent today because all widths are multiples of 4. | **Latent Defect (D2)** | Enforce stride awareness or explicitly assert `width % 4 == 0` in all builder constructors. |

---

## 2. Verification of Leased Buffers Wiring

### 2.1 Current State
- `AnalysisRasterBuilder.build(..., lease:)` writes directly into a leased Metal buffer obtained from `MetalTerrainPipelineActor.SharedBufferPool`.
- `DisplayBitmap.makeImage` and `TerrainBitmap.makeImage` attach `MetalBufferLease` to `CGDataProvider` release callbacks, recycling buffers directly into `SharedBufferPool` and `SynchronousBufferPool`.
- Synchronous buffer pooling uses `OSAllocatedUnfairLock` to ensure 100% thread safety without detached `Task` hops.

### 2.2 Benchmarks & Evidence
- Allocation overhead comparison (`gpu_bench.swift` on M5 Pro):
  - 264²: 0.027 ms (fresh allocation) vs 0.016 ms (pooled buffer).
  - 520²: 0.101 ms (fresh allocation) vs 0.061 ms (pooled buffer).
  - 776²: 0.221 ms (fresh allocation) vs 0.136 ms (pooled buffer).
- Buffer recycling is sound; zero memory leaks across 500+ harness tile cycles.

### 2.3 Identified Deficiencies to Remediate
1. **`TerrainTileProvider.inspectSpot` Overhead (Defect D1):**
   - In commit `bdfad21`, `inspectSpot(at:)` was wired to `raster.leasedReliefProducts(for: entry.grid)`.
   - Dispatching a 7-plane Metal compute pass and round-tripping a command buffer to read $(cx, cy)$ is ~100x slower than the CPU 3x3 Horn stencil.
   - **Remediation:** Restore the CPU Horn stencil (`hornSlopeAspect`) in `inspectSpot` when reading point slope/aspect/normals.
2. **Buffer Row Padding in CPU Readers (Defect D2):**
   - Metal linear textures require `bytesPerRow` to be aligned to `device.minimumLinearTextureAlignment(for:)` (16 bytes on Apple Silicon).
   - If width is not a multiple of 4, row padding occurs.
   - `AnalysisRaster.pointer`, `referenceElevation`, and `sampleBilinear` assume tight packed rows (`cx + cy * width`).
   - **Remediation:** Document and enforce the invariant that all analysis rasters have `width % 4 == 0` via debug assertions, or add `stride` parameters to bilinear sampling helpers.
3. **Buffer Pool Idle Ceiling Consistency (Defect D6/D7):**
   - `SynchronousBufferPool` in `RasterCompute.swift` caps by count (8) rather than bytes, and lacks memory-warning purging.
   - **Remediation:** Add `purge()` to `SynchronousBufferPool` hooked into memory warning notifications.

---

## 3. Evaluation of GPU Atomic Histogram (§3B)

- **Review Proposal:** Compute 256-bin histogram in Metal using `atomic_fetch_add_explicit` in threadgroup memory, followed by prefix-sum to determine 2nd and 98th percentiles.
- **Measured CPU Cost:** `ReliefRenderer.robustRange()` on the downsampled 64×64 preview grid takes **0.048 ms** on CPU.
- **GPU Round-Trip Overhead:** Dispatching a histogram kernel, threadgroup reduction, prefix-sum kernel, and reading back percentiles via `MTLBuffer` blit or synchronization takes **0.25–0.40 ms**, introducing GPU-CPU synchronization stalls.
- **Conclusion:** The review's proposed GPU histogram introduces architectural complexity and net latency for a non-bottleneck path. Rejected.
