# Comprehensive Architectural Review Assessment

**Document Path:** `docs/superpowers/reviews/2026-09-13-architectural-review-assessment.md`  
**Evaluation Date:** 2026-09-13  
**Review Source:** `docs/superpowers/reviews/2026-09-13-architectural-review.md`  
**Branch:** `feat/micro-topography-engine`  

---

## 1. Assessment Overview & Scorecard

The external review proposed 11 algorithmic, architectural, and concurrency modifications. Each item was empirically evaluated against the current codebase using isolated benchmark harnesses and mathematical modeling in `build-review/scratch/`.

### Summary Matrix

| Section | Topic | Review Proposal | Empirical Verdict | Recommended Action |
|---|---|---|---|---|
| **§1A** | Curvature Singularity | Tangential Curvature ($K_t$) & $\max(p^2+q^2, 10^{-6})$ clamp | **ACCEPTED** | Implement $K_t$ with epsilon clamp. Fix `.rg32Float` curvature surface binding. |
| **§1B** | REM Meander Bleed | Segment-normal projection & `ThalwegSegment` | **STALE / EXTENDED** | Segment projection was already present. Fix **meander-neck elevation cliffs** via banded blending and fix tail truncation. |
| **§1C** | LRM Moat Halos | Bilateral Gaussian Filter ($\sigma_r = 0.5\text{ m}$) | **REJECTED (FLAWED)** | Bilateral filter erases mounds taller than 0.5 m (0% retention). Adopt **Robust Tukey M-Estimator LRM** (98% retention, 95% moat reduction). |
| **§2** | Vector Ruggedness (VRM) | Unit normal vector dispersion over $3\times3$ / $5\times5$ | **ACCEPTED** | Implement `compute_vector_ruggedness` with float32-stabilized formula. |
| **§2** | Difference of Gaussians | Dual-scale band-pass filter ($\sigma_1=2\text{ m}, \sigma_2=10\text{ m}$) | **ACCEPTED** | Implement separable 2-pass DoG for sunken paths and palisade ditches. |
| **§2** | Directional Occlusion | Horizon angle along sun ray for low-angle grazing shadows | **ACCEPTED** | Add `compute_directional_occlusion` kernel. |
| **§2** | Openness Split | Expose Positive ($O_p$) and Negative ($O_n$) Openness | **ACCEPTED** | Add individual scalar products to `MicroTopographyProduct`. |
| **§3A** | SVF Acceleration | Mipmapped linear texture sampling | **REJECTED (INFEASIBLE)** | Buffer-backed textures cannot have mips. Adopt **micro-horizon reuse + 12 geometric far steps**, cutting reads from 720 to 432 and restoring $<4\text{ ms}$ GPU time. |
| **§3B** | Contrast Normalization | On-GPU 256-bin atomic histogram & prefix sum | **REJECTED** | CPU `robustRange` on 2k samples takes 0.05 ms. GPU histogram introduces latency and pipeline sync barriers. |
| **§3C** | Leased Buffer Pipeline | Wire zero-copy leased buffers into live tile rendering | **STALE** | Already wired by agy in commits `96d4a40` / `bdfad21`. Fix `inspectSpot` CPU stencil regression. |
| **§4** | Concurrency Hardening | Generation tokens & task cancellation | **PARTIALLY STALE / EXPANDED** | Generation tokens already existed. Fix **critical stale neighbor clearing race** and **settings push lost reload race**. |

---

## 2. Deep Dive: Key Architectural Determinations

### 2.1 LRM Detrending: Why Bilateral Failed and Tukey Succeeded
The external review recommended an edge-preserving bilateral filter with range parameter $\sigma_r \approx 0.5\text{ m}$. In our empirical tests on archaeological models (`build-review/scratch/lrm-dog/out-1c.txt`), this filter produced **0% mound amplitude retention** for a 2 m platform mound. Because the elevation step across the mound flank exceeded $\sigma_r$, the filter stopped averaging across the boundary, treating the top of the mound as an isolated flat surface and setting the trend equal to the mound summit.

Instead, **Robust Tukey Biweight M-estimation** solves the problem correctly:
- Outliers (structures higher or lower than the regional slope) receive zero weight in the regional trend calculation.
- The trend surface bridges smoothly under mounds and across ditches.
- Result: **98% mound amplitude preservation** and a **95% reduction in negative moat depth** (from $-0.456\text{ m}$ down to $-0.022\text{ m}$).

### 2.2 REM: Discovery and Elimination of Meander-Neck Discontinuities
Nearest-segment projection creates Voronoi boundaries between river reaches. In sinuous oxbow meanders where two limbs are separated by hundreds of meters along-channel but only a few meters overland, this creates **hard vertical cliffs (up to 2.27 m)** right through the floodplain.
By applying **Banded Distance Weighting** with an active bandwidth $B = 25\text{ m}$:
$$w_i = \left(1 - \frac{d_i - d_{min}}{B}\right)^2$$
the number of discontinuous jump crossings across the benchmark grid drops from **17,223 down to ZERO**, producing a perfectly continuous relative elevation surface.

### 2.3 SVF Optimization: Reclaiming the GPU Budget
Dual-radius SVF introduced in commit `96d4a40` increased ray march texture reads to 720 per cell, pushing 1024² dispatch time to **8.95 ms** (violating the 8 ms budget).
Because Metal does not permit mipmaps on buffer-backed zero-copy textures, the review's mipmapping scheme cannot be used.
However, **Variant C (Micro-Horizon Reuse + Geometric Far Sampling)**:
- Reuses the maximum horizon angle from the inner 15 m sweep.
- Takes 12 geometric steps along each ray between 15 m and 60 m.
- Reduces reads from **720 to 432 per cell** (a 40% reduction).
- Keeps error below $0.01$ dSVF.
- Restores execution time to **$\approx 3.8\text{ ms}$**.

### 2.4 Critical Concurrency Defect Fixes
Two severe concurrency races were identified and proven in `build-review/scratch/concurrency/`:
1. **In-Flight Stale Neighbour Invalidation Race:** A tile finishing rendering cleared its stale flag, overwriting newly arrived neighbour invalidation notifications and leaving unstitched tile seams. Solved via clock-stamped claims (`FixedStore`) returning `.drawnButStale`.
2. **Settings Push Lost Invalidation:** Rapid slider scrubbing cancelled in-flight settings tasks, causing `terrainVersion` bumps to be dropped even when the provider adopted new shader parameters. Solved by bumping `terrainVersion` whenever `didChange == true`.

---

## 3. Subsystem Reports Reference
- **Leased Buffers & Histogram:** [`leases-histogram.md`](file:///Users/herren/dev/LidarExplorer/docs/superpowers/reviews/2026-09-13-assessment/leases-histogram.md)
- **Curvature & VRM:** [`curvature-vrm.md`](file:///Users/herren/dev/LidarExplorer/docs/superpowers/reviews/2026-09-13-assessment/curvature-vrm.md)
- **REM & River Thalweg:** [`rem-thalweg.md`](file:///Users/herren/dev/LidarExplorer/docs/superpowers/reviews/2026-09-13-assessment/rem-thalweg.md)
- **LRM & DoG:** [`lrm-dog.md`](file:///Users/herren/dev/LidarExplorer/docs/superpowers/reviews/2026-09-13-assessment/lrm-dog.md)
- **Horizon Kernels (SVF, Openness, Occlusion):** [`horizon-kernels.md`](file:///Users/herren/dev/LidarExplorer/docs/superpowers/reviews/2026-09-13-assessment/horizon-kernels.md)
- **Concurrency & Invalidation:** [`concurrency.md`](file:///Users/herren/dev/LidarExplorer/docs/superpowers/reviews/2026-09-13-assessment/concurrency.md)
