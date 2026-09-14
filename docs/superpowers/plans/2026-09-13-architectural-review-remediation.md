# Architectural Review Remediation Plan

**Authoritative Plan:** `docs/superpowers/plans/2026-09-13-architectural-review-remediation.md`  
**Target Branch:** `feat/micro-topography-engine`  
**Assessment Basis:** `docs/superpowers/reviews/2026-09-13-architectural-review-assessment.md`  

---

## 1. Plan Overview

This plan executes the verified remediations identified during the adversarial audit of the 2026-09-13 architectural review. It resolves all confirmed defects, introduces high-value micro-topography algorithms, restores the GPU dispatch budget to $<4\text{ ms}$, and eliminates concurrency races.

---

## 2. Implementation Tasks

### Part 1: Concurrency & Tile Lifecycle Hardening

- [x] **Task 1.1: Clock-Stamped `TileImageStore` Invalidation**
  - **Files:** `LidarExplorer/MapLayer/TerrainTileOverlay.swift`
  - **Changes:** Replace boolean `stale: Set<String>` with monotonic `markClock` tracking (`FixedStore` design). When `finishLoad` completes, return `.drawnButStale` if an invalidation mark arrived during flight, triggering an immediate restitch pass.
  - **Verification:** Unit test reproducing neighbour arrival during in-flight render confirms 0 lost redraws.

- [x] **Task 1.2: Settings Push Version Bump Hardening**
  - **Files:** `LidarExplorer/Presentation/TerrainViewerModel.swift`
  - **Changes:** In `pushSettings`, ensure `terrainVersion &+= 1` is called whenever `didChange == true`, even if the originating task was superseded.
  - **Verification:** Rapid slider scrub test passes with renderer reloaded.

- [x] **Task 1.3: Spot Inspection Performance Restoration**
  - **Files:** `LidarExplorer/MapLayer/TerrainTileOverlay.swift`
  - **Changes:** Restore the CPU 3×3 Horn stencil (`hornSlopeAspect`) in `inspectSpot(at:)` for single-point slope/aspect/normal queries instead of dispatching full-tile 7-plane GPU passes.
  - **Verification:** Harness spot inspection passes without GPU command-buffer allocation.

- [x] **Task 1.4: Analysis Raster Geometry Alignment Assertion**
  - **Files:** `LidarExplorer/MapLayer/AnalysisRasterBuilder.swift`
  - **Changes:** Add assertions enforcing `width % 4 == 0` on all analysis rasters to guarantee zero padding on 16-byte aligned linear textures.

---

### Part 2: SVF Optimization & Horizon Kernels

- [x] **Task 2.1: SVF Ray Marching Acceleration (Variant C)**
  - **Files:** `LidarExplorer/Core/Raster/Shaders/TerrainKernels.metal`, `LidarExplorer/Core/Raster/MetalTerrainPipelineActor.swift`
  - **Changes:** In `compute_svf`, reuse the maximum horizon angle from the micro sweep ($1\dots15\text{ m}$) and evaluate 12 geometrically spaced far steps ($15\dots60\text{ m}$) along each ray. Reduce reads/cell from 720 to 432.
  - **Verification:** Harness GPU benchmark at 1024² confirms SVF drops from 8.95 ms to $<4.0\text{ ms}$.

- [x] **Task 2.2: Directional Grazing Occlusion Kernel**
  - **Files:** `LidarExplorer/Core/Raster/Shaders/TerrainKernels.metal`, `LidarExplorer/Core/Raster/MetalTerrainPipelineActor.swift`
  - **Changes:** Add `compute_directional_occlusion` evaluating horizon angle along the solar vector. Add `.directionalOcclusion` to `MicroTopographyProduct`.
  - **Verification:** Harness check asserts directional shadow generation at low sun angles.

- [x] **Task 2.3: Positive & Negative Openness Product Exposure**
  - **Files:** `LidarExplorer/Domain/TerrainStyles.swift`, `LidarExplorer/Core/Raster/MetalTerrainPipelineActor.swift`, `LidarExplorer/MapLayer/TerrainTileOverlay.swift`
  - **Changes:** Expose `.positiveOpenness` and `.negativeOpenness` in `MicroTopographyProduct`.
  - **Verification:** Harness renders sample PNGs for positive and negative openness.

---

### Part 3: Curvature & Vector Ruggedness Measure (VRM)

- [x] **Task 3.1: Tangential Curvature ($K_t$) & Singularity Clamp**
  - **Files:** `LidarExplorer/Core/Raster/Shaders/TerrainKernels.metal`, `LidarExplorer/Core/Raster/MicroTopographyReference.swift`
  - **Changes:** Add Tangential Curvature ($K_t$) formula and clamp denominator with $\max(p^2 + q^2, 10^{-6})$. Clamp output to $0$ when $p^2 + q^2 < 10^{-6}$.
  - **Verification:** Numerical test confirms zero noise explosions on flat floodplains.

- [x] **Task 3.2: Curvature Surface Channel Preservation**
  - **Files:** `LidarExplorer/Core/Raster/MetalTerrainPipelineActor.swift`
  - **Changes:** Change `encodeCurvature` surface format from `.r32Float` to `.rg32Float` (Profile in R, Tangential in G).
  - **Verification:** Harness check validates both curvature channels in output buffer.

- [x] **Task 3.3: Vector Ruggedness Measure (VRM) Kernel**
  - **Files:** `LidarExplorer/Core/Raster/Shaders/TerrainKernels.metal`, `LidarExplorer/Core/Raster/MetalTerrainPipelineActor.swift`, `LidarExplorer/Domain/TerrainStyles.swift`
  - **Changes:** Implement `compute_vector_ruggedness` with float32-stabilized formula and square-root display mapping. Add `.vectorRuggedness` to `MicroTopographyProduct`.
  - **Verification:** Harness asserts $VRM = 0$ on planar slopes and $>0$ on ditches and rubble.

---

### Part 4: REM Thalweg Detrending & Continuity

- [x] **Task 4.1: Banded Distance Blending for River Thalwegs**
  - **Files:** `LidarExplorer/Core/Raster/Shaders/TerrainKernels.metal`
  - **Changes:** In `mt_thalweg_surface`, implement banded distance-weighted segment blending ($B = 25\text{ m}$) to eliminate meander-neck elevation cliffs.
  - **Verification:** Synthetic meander neck test verifies 0 jump crossings $> 1\mu\text{m}$.

- [x] **Task 4.2: Fix `ThalwegBuilder` Tail Truncation**
  - **Files:** `LidarExplorer/MapLayer/ThalwegBuilder.swift`
  - **Changes:** Ensure `ThalwegBuilder.densify` always appends the exact terminal coordinate of the polyline.
  - **Verification:** Harness asserts 100 m polyline densifies all the way to 100.0 m.

- [x] **Task 4.3: Cross-Valley Extrapolation Ceiling**
  - **Files:** `LidarExplorer/Core/Raster/Shaders/TerrainKernels.metal`
  - **Changes:** Add `maxCrossValleyMeters` parameter to `mt_thalweg_surface` to prevent extrapolation into upland terrain.

---

### Part 5: LRM Robust Tukey Detrending & Difference of Gaussians (DoG)

- [x] **Task 5.1: Robust Tukey M-Estimator LRM**
  - **Files:** `LidarExplorer/Core/Raster/Shaders/TerrainKernels.metal`, `LidarExplorer/Core/Raster/MetalTerrainPipelineActor.swift`
  - **Changes:** Implement iterative Tukey biweight detrending ($c = 0.5\text{ m}$) to eliminate negative moat halos around elevated earthworks.
  - **Verification:** Mound test confirms $\ge 95\%$ mound amplitude retention with moat depth $< 0.05\text{ m}$.

- [x] **Task 5.2: Multi-Scale Difference of Gaussians (DoG)**
  - **Files:** `LidarExplorer/Core/Raster/Shaders/TerrainKernels.metal`, `LidarExplorer/Core/Raster/MetalTerrainPipelineActor.swift`, `LidarExplorer/Domain/TerrainStyles.swift`
  - **Changes:** Implement 2-pass separable DoG kernel ($\sigma_1 = 2\text{ m}, \sigma_2 = 10\text{ m}$). Add `.differenceOfGaussians` to `MicroTopographyProduct`.
  - **Verification:** Harness asserts band-pass response on linear earthworks.

---

### Part 6: Comprehensive Verification & Documentation

- [x] **Task 6.1: Offline Test Harness Expansion**
  - **Files:** `Tools/ViewerHarness/main.swift`, `Tools/ViewerHarness/MicroTopographyChecks.swift`
  - **Changes:** Add test cases for VRM, DoG, Tangential Curvature, Tukey LRM, and Thalweg continuous blending.
  - **Command:** `./Tools/run-harness.sh /tmp/lidar-harness-remediation`

- [x] **Task 6.2: Live Network Check**
  - **Command:** `./Tools/run-live-check.sh`

- [x] **Task 6.3: iOS Release Build**
  - **Command:** `xcodebuild -project LidarExplorer.xcodeproj -scheme LidarExplorer -destination "generic/platform=iOS Simulator" -configuration Debug CODE_SIGNING_ALLOWED=NO build`

- [x] **Task 6.4: Update Status & Roadmap**
  - **Files:** `STATUS.md`, `docs/superpowers/NEXT_STEPS_FOR_AGY.md`
