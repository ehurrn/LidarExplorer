# Architectural & Algorithmic Review: Micro-Topography Engine (external input, 2026-09-13)

> **Status of this document:** verbatim copy of an external review the user supplied on 2026-09-13.
> Its claims were **not** written against the current code and several are stale or incorrect.
> Do **not** implement from this file directly — read the verified assessment first:
> `docs/superpowers/reviews/2026-09-13-architectural-review-assessment.md`
> and the actionable plan: `docs/superpowers/plans/2026-09-13-architectural-review-remediation.md`.

**Target Branch:** `feat/micro-topography-engine`
**Focus:** Analytical accuracy, GPU kernel efficiency, pipeline throughput, and novel micro-relief methods.

---

### 1. Mathematical & Algorithmic Refinements

#### A. Curvature Singularity Elimination (Zevenbergen & Thorne vs. Florinsky)
* **Current Issue:** Planform curvature ($K_{plan}$) divides by $(p^2 + q^2)^{3/2}$ where $p = \partial z / \partial x$ and $q = \partial z / \partial y$. On flat plains or low-gradient floodplains ($p, q \to 0$), floating-point division causes catastrophic cancellation and noise amplification.
* **Correction:** Implement **Tangential Curvature** ($K_t$) alongside or in place of Planform Curvature:
  $$K_t = -\frac{q^2 r - 2pqs + p^2 t}{(p^2 + q^2)\sqrt{1 + p^2 + q^2}}$$
  Add an epsilon clamp to the denominator: $\max(p^2 + q^2, 10^{-6})$. For $(p^2 + q^2) < 10^{-6}$, clamp $K_t = 0.0$ and $K_{plan} = 0.0$ to prevent NaN/Inf spikes across flat alluvial plains.

#### B. Relative Elevation Model (REM): Mitigating Meander-Neck Bleed
* **Current Issue:** IDW interpolation against 1D thalweg points is isotropic. In meandering river corridors (e.g., Mississippi bottomlands), Euclidean inverse-distance weighting leaks river water elevations across narrow oxbow necks and levees into adjacent scroll bars.
* **Correction:**
  * Segment the thalweg polyline into oriented vectors $\vec{v}_i = P_{i+1} - P_i$.
  * For any grid cell $C$, determine orthogonal projection onto the nearest line segment $\vec{v}_i$.
  * Only interpolate using segment-normal projection rather than radial Euclidean distance. If the orthogonal projection falls outside the segment bounds, clamp to the nearest vertex.
  * Enforce maximum orthogonal search radius (`maxCrossValleyWidthMeters`, default: 2,500 m) to prevent unconstrained interpolation into upland bluffs.

#### C. Edge-Preserving Detrending for Local Relief Models (LRM)
* **Current Issue:** The separable 2D Gaussian filter blurs across sharp anthropogenic edges (e.g., platform mound aprons, ramparts). Subtracting the Gaussian trend leaves distinct negative "halo" moats around elevated structures.
* **Correction:** Introduce a **Bilateral Filter** or **Rolling-Ball Morphological Filter** pass as an alternative detrending mode:
  * In `TerrainKernels.metal`, implement a separable or small-window (e.g., $15 \times 15$) bilateral Gaussian filter that weights samples by spatial distance *and* elevation difference:
    $$W(x, y) = G_{\sigma_s}(\|\Delta x\|) \cdot G_{\sigma_r}(|z(x,y) - z_{center}|)$$
  * Clamping the photometric range $\sigma_r \approx 0.5\text{ m}$ preserves sharp terrace breaks while smoothing regional terrain trends, eliminating negative moat artifacts.

---

### 2. Additional Micro-Terrain Methods to Implement

| Method | Mathematical Formulation | Target Feature Detection |
| :--- | :--- | :--- |
| **Vector Ruggedness Measure (VRM)** | Decouples ruggedness from slope steepness using 3D unit normal dispersion: $VRM = 1 - \frac{\|\sum \vec{n}_i\|}{N}$ over a $3\times3$ or $5\times5$ window. | Identifies eroded ditch remnants, rubble scatters, and collapsed earthworks on steep talus slopes where Horn slope saturates. |
| **Multi-Scale Difference of Gaussians (DoG)** | $DoG = G_{\sigma_1}(Z) - G_{\sigma_2}(Z)$ with $\sigma_1 = 2\text{ m}$, $\sigma_2 = 10\text{ m}$. Band-pass spatial frequency filter. | Isolates linear wagon ruts, sunken lanes, and narrow palisade trenches while attenuating high-frequency point-cloud noise and low-frequency topographic swell. |
| **Directional Occlusion / Micro-Horizon Shading** | Evaluates angular horizon elevation $H(\theta)$ at grazing sun angles ($5^\circ - 15^\circ$) along the light ray vector, generating true hard/soft shadows: $S = \max(0, \sin(H - \alpha_{sun}))$. | Highlights subtle earthwork edges that standard Lambertian cosine shading leaves flat. |
| **Positive & Negative Openness Split** | Expose positive openness ($O_p$) and negative openness ($O_n$) as distinct scalar outputs, not just differential $I = (O_p - O_n)/2$. | $O_p$ isolates convex mound crowns and ridge crests; $O_n$ isolates subsurface borrow pits, sunken roadways, and cellar depressions. |

---

### 3. GPU Kernel & Apple Silicon Architecture Enhancements

#### A. Mipmapped Hierarchical Raymarching for Macro-SVF
* **Bottleneck:** `compute_svf` marches 16–32 rays out to 50+ meters in native 1-meter steps. On large destination windows, this causes non-coalesced global VRAM cache misses.
* **Refactoring:**
  * Sample the native texture up to `microRadiusMeters` (e.g., 10 m).
  * For steps beyond 10 m, transition to mipmapped elevation overviews (Level 1 / 2) with stride doubling ($\Delta r_{step} = 2 \times \text{cell\_size}$).
  * Leverage Metal hardware linear samplers (`min_filter::linear, mag_filter::linear`) for interpolated height sampling along rays.

#### B. Direct Metal Compute Histogram & Robust Range Normalization
* **Current State:** Dynamic contrast stretching relies on `ReliefRenderer.robustRange()` on the host CPU, requiring float plane inspection or round-trips.
* **Refactoring:**
  * Implement `compute_terrain_histogram` in Metal: 256 bins using threadgroup local atomics (`atomic_fetch_add_explicit`), followed by a single grid-level reduction.
  * Dispatch a prefix-sum kernel to compute the 2nd and 98th percentiles ($p_{02}, p_{98}$) into an `MTLBuffer`.
  * Pass this min/max buffer directly into the composite render pass for on-GPU linear stretching, enabling zero-copy real-time palette contrast adjustments.

#### C. Wire `leasedReliefProducts` into Live Consumer Pipeline
* **Current Gap:** `RasterCompute.leasedReliefProducts` exists in the engine and tests green in `MicroTopographyChecks.swift`, but `AnalysisRasterBuilder` and `TerrainTileProvider` still allocate heap buffers when assembling intermediate derivative grids.
* **Refactoring:**
  * Update `AnalysisRasterBuilder.build()` to accept an optional `SurfaceLease` input directly from `MetalTerrainPipelineActor`.
  * Bind the leased surface directly to `terrain_derivatives` output, avoiding `[Float]` array intermediate allocations during high-frequency panning.

---

### 4. Concurrency & Swift 6 Safety Hardening

* **Actor Re-entrancy during Stale Tile Invalidation:**
  When an adjacent tile arrives in `TerrainTileProvider`, `takeStaleTiles()` marks drawn tiles stale. Ensure `store.beginLoad(key)` uses an atomic state token (`generation: UInt64`) so that rapid zoom/pan events cannot allow a slower stale background pass to overwrite a freshly loaded higher-zoom tile.
* **Task Cancellation on Continuous Relighting:**
  When dragging azimuth/altitude sliders, cancel in-flight `Task` instances in `TerrainViewerModel` prior to dispatching new frames. Use `withTaskCancellationHandler` within `MetalTerrainPipelineActor.render` to immediately drop command buffers that have not yet been committed to `MTLCommandQueue`.

---

### 5. Implementation Action Plan

1. **Topographic Curvature Kernel Update:**
   * Modify `compute_topographic_curvature` in `TerrainKernels.metal`.
   * Add tangential curvature output and division-by-zero epsilon clamp $\max(p^2 + q^2, 10^{-6})$.
   * Update `MicroTopographyReference.swift` CPU reference and assert agreement in `MicroTopographyChecks.swift`.
2. **VRM Vector Ruggedness Kernel:**
   * Add `compute_vector_ruggedness` to `TerrainKernels.metal`.
   * Bind normalized surface normal components $(n_x, n_y, n_z)$. Compute unit vector sum over $k \times k$ neighborhood.
   * Add `.vectorRuggedness` to `MicroTopographyProduct` enum and register pipeline state in `MetalTerrainPipelineActor`.
3. **REM Segment-Normal Thalweg Projection:**
   * Refactor `ThalwegBuilder.swift` to construct directional segment structures:
     ```swift
     public struct ThalwegSegment: Sendable {
         public let start: SIMD2<Float>
         public let end: SIMD2<Float>
         public let startElevation: Float
         public let endElevation: Float
     }
     ```
   * Update `detrend_river_elevation` kernel to find orthogonal projection distance rather than isotropic Euclidean radius.
4. **Wire Leased Buffers in Tile Pipeline:**
   * Replace heap copies in `MapLayer/AnalysisRasterBuilder.swift` with `MetalTerrainPipelineActor.shared.leasedSurface`.
   * Verify test suite passes with `./Tools/run-harness.sh`.
