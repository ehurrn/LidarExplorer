# Architectural Implementation Plan: Micro-Topography Engine (Devil's Advocate Audit Review)

> **Calibration note (2026-09-12, Claude Code):** Historical. Current state lives in `STATUS.md` and the authoritative
> plan `plans/2026-09-12-micro-topography-engine.md` (Part B fixed the defects found at calibration: app builds,
> harness 464 / 0, live 67 / 0).

> **Document Status:** REVIEWED & AUDITED (Hardened Execution Roadmap)  
> **Original Plan:** [`docs/superpowers/plans/2026-09-12-micro-topography-engine.md`](file:///Users/herren/dev/LidarExplorer/docs/superpowers/plans/2026-09-12-micro-topography-engine.md)  
> **Companion Spec:** [`docs/superpowers/specs/2026-09-12-micro-topography-engine-design-reviewed.md`](file:///Users/herren/dev/LidarExplorer/docs/superpowers/specs/2026-09-12-micro-topography-engine-design-reviewed.md)  
> **Review Date:** 2026-09-12  
> **Target Subsystem:** LidarExplorer Advanced Micro-Topography & Terrain Analysis Engine (Phases 5–7)

---

## Executive Summary & Audit Context

The original 48-line execution plan outlined 7 high-level phases but left Phases 5, 6, and 7 as unstructured bullet points, omitting critical interaction constraints, concurrency backpressure, and boundary failure modes. Following the Devil's Advocate audit, this reviewed plan establishes a hardened, task-by-task execution roadmap that directly addresses:

1. **MapKit Gesture Contention:** Eliminates 3D camera pitch/tilt hijacking via `TransectPencilGestureRecognizer` (filtering `.pencil` touches) and interaction mode state arbitration.
2. **120 Hz Swift Charts Saturation:** Decouples 120 Hz Apple Pencil drag previews (decimated 256-pt path) from background 0.5 m analytical transect calculation ($N \le 20,000$) and signature detection.
3. **Tile Boundary Phantom Signatures:** Adds seam-aware multi-tile sampling and a tile boundary artifact rejection filter to prevent false-positive mound/ditch detections at tile seams.
4. **Poison Pill Crash Hardening:** Eliminates force-unwrapping on coordinate bounds in `COGResampler`.
5. **Memory & Cache Bounding:** Enforces bounded LRU caches for COG readers and georeferences, and establishes a Tiered Viewshed Resolution Schedule capping grids to $2048 \times 2048$.

---

## Hardened Architecture Decisions

| # | Topic | Decision | Devil's Advocate Rationale |
| :--- | :--- | :--- | :--- |
| **1** | Metal Surface Allocation | Linear textures over shared buffers on device; blit fallback on Simulator. | Zero CPU-GPU copy overhead; prevents Simulator crashes. |
| **2** | Buffer/Texture Recycling | `SurfacePool` with 192 MB idle limit; leases return via deinit. | Guarantees bounded idle footprint across continuous rendering. |
| **3** | Dispatch Synchronization | Async continuation via `commandBuffer.addCompletedHandler`. | Never blocks threads on GPU completion (`waitUntilCompleted` prohibited). |
| **4** | Raster Staging | Zero-copy when `rowBytes % 16 == 0`; staging copy when unaligned. | Avoids Metal linear texture alignment assertion panics. |
| **5** | Sentinels / NoData | In-place GPU normalisation to `NaN` in source memory before kernels run. | Eliminates branch divergence and false edge detection in shaders. |
| **6** | LRM Kernel | Two-pass 1D Gaussian ($\sigma=5\text{ m}, r=3\sigma$) in shared memory, detrend residual. | Replaces $O(R^2)$ 2D conv with $O(R)$ separable passes. |
| **7** | RRIM Kernel | Openness from 16-ray lookup, slope saturation, blended overlay. | Matches Chiba et al. standard for micro-relief visualization. |
| **8** | Sky-View Factor | 16-ray horizon lookup over 10 m radius, cosine-weighted dome integral. | Quantifies diffuse skylight occlusion in trenches and ditches. |
| **9** | Raking Light | Dynamic solar azimuth/elevation grazing angle with diffuse wrap. | Highlights subtle micro-topographic linear features. |
| **10** | REM Kernel | 1D along-river thalweg profile or 2D trend surface detrending. | Normalizes relative elevation for paleochannel identification. |
| **11** | Habitation Potential | Slope $\le 4^\circ$, Distance-to-Bluff ($\ge 25^\circ$) via Jump Flood Algorithm. | Identifies occupational terraces and defensive promontories. |
| **12** | COG Streaming | `actor ElevationTileCoordinator`, page-aligned `COGMappedStorage`. | Direct-to-GPU byte-range streaming from S3 `usgs-lidar-public`. |
| **13** | **Gesture Arbitration** | Modal `ViewerInteractionMode` + `TransectPencilGestureRecognizer`. | **Audit Fix (Blocker 1):** Prevents MapKit 3D camera tilt collisions. |
| **14** | **Dual-Rate Transects** | 120 Hz 256-pt preview path; 10 Hz background 0.5 m analytical engine. | **Audit Fix (Blocker 2):** Prevents Swift Charts MainActor frame freezes. |
| **15** | **Seam Rejection** | Suppress curvature extrema within 1.5 m of Web Mercator tile seams. | **Audit Fix (Blocker 3):** Eliminates phantom earthwork detections at seams. |
| **16** | **Safe Coordinate Math** | Guard `.isFinite` on all projections in `COGResampler`; no force-unwraps. | **Audit Fix (Major 4):** Eliminates fatal crashes on degenerate bounds. |
| **17** | **Bounded LRU Caches** | `LRUCache` for readers (cap 16) and georeferences (cap 64); negative TNM caching. | **Audit Fix (Major 5 & Minor 8):** Prevents memory leaks and cache stampedes. |
| **18** | **Tiered Viewshed Grids** | Tiered cell size ($1\text{ m} \le 1\text{ km}$, $2.5\text{ m} \le 2.5\text{ km}$, $5\text{ m} \le 5\text{ km}$); max $2048^2$. | **Audit Fix (Major 6):** Enforces 192 MB surface pool memory bounds. |
| **19** | **Screen-Space Soil Hatches** | Procedural Metal fragment shader hatching via stencil; background SDA fetch. | **Audit Fix (Major 7):** Eliminates CPU ear-clipping UI freezes. |
| **20** | **Historical Map Streaming** | Max texture clamping ($2048^2$) and background downsampling on import. | **Audit Fix (Major 3):** Prevents OOM crashes on huge scanned GeoTIFFs. |

---

## Phase Status Summary

- [x] **Phase 1: Metal Kernels & Pipeline Actor** (13 kernels, `MetalTerrainPipelineActor`, CPU references, harness checks passing).
- [x] **Phase 2: COG Streaming Coordinator** (`ElevationTileCoordinator`, S3 range fetching, mapped storage, GPU nodata, harness checks passing).
- [x] **Phase 3: Transect & Signature Engine** (`ElevationTransect.swift`, Gaussian smoothing, along-track slope, curvature, platform mound and ditch-and-berm detectors, tests passing).
- [x] **Phase 4: Provider Integration & Shading Options** (Wire `TerrainTileProvider` to micro-pipeline, 4 micro styles, 3×3 neighbor stitching, 500 MB LRU cache, settings UI, harness & live checks passing).
- [ ] **Phase 5: Interactive Analysis UI (Transect Drawing, Signatures & Viewshed)** *(Next)*.
- [ ] **Phase 6: Historical Overlays & SSURGO Soils Engine**.
- [ ] **Phase 7: Optimization, Hardening & Ship Readiness**.

---

## Phase 5: Interactive Analysis UI (Transect Drawing, Signatures & Viewshed)

### Task 19: Modal Interaction State Machine & Gesture Arbitration (Blocker 1 Fix)
- **Goal:** Prevent gesture collisions between MapKit camera manipulation (pan, pinch, 3D tilt) and interactive analysis tools.
- **Files:**
  - Modify: [`LidarExplorer/Presentation/TerrainViewerModel.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Presentation/TerrainViewerModel.swift)
  - Modify: [`LidarExplorer/MapLayer/TerrainMapView.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/TerrainMapView.swift)
  - Create: `LidarExplorer/MapLayer/TransectGestureRecognizer.swift`
- [ ] **Step 1: Add interaction mode enum to `TerrainViewerModel`**
  ```swift
  public enum ViewerInteractionMode: String, Sendable, CaseIterable {
      case navigate
      case transectDrawing
      case viewshedObserver
      case historicalWipe
  }
  @Published public var interactionMode: ViewerInteractionMode = .navigate
  ```
- [ ] **Step 2: Create `TransectGestureRecognizer` with Pencil filtering**
  - Subclass `UIPanGestureRecognizer`.
  - Configure `allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]` by default.
  - When pencil touches are detected, set `cancelsTouchesInView = true` to prevent MapKit from processing palm or pencil contact as pan/tilt.
- [ ] **Step 3: Update `TerrainMapView.Coordinator` gesture handling**
  - Implement `UIGestureRecognizerDelegate`.
  - When `interactionMode == .transectDrawing` (finger mode), set `mapView.isScrollEnabled = false`, `mapView.isPitchEnabled = false`, and `mapView.isRotateEnabled = false`.
  - Re-enable MapKit navigation gestures when `interactionMode == .navigate`.

### Task 20: Dual-Rate Transect Engine & Decimated Chart View (Blocker 2 Fix)
- **Goal:** Maintain 120 FPS UI responsiveness during continuous Apple Pencil drag by decoupling screen-space preview from analytical signature detection.
- **Files:**
  - Modify: [`LidarExplorer/Domain/ElevationTransect.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Domain/ElevationTransect.swift)
  - Modify: [`LidarExplorer/Presentation/TerrainViewerModel.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Presentation/TerrainViewerModel.swift)
- [ ] **Step 1: Implement fast interactive preview decimation in `ElevationTransectEngine`**
  - Add `previewProfile(from:to:maxPoints: 256)`: samples the current visible elevation grid with linear interpolation without calculating 2nd derivatives or signatures.
- [ ] **Step 2: Implement throttled analytical pipeline in `TerrainViewerModel`**
  - On touch move (`.changed`): update start/end coordinates, evaluate `previewProfile`, and push to `@Published var interactiveProfile` at 120 Hz.
  - Debounce full analytical evaluation (`sampleProfile(from:to:stepDistance: 0.5)` + `detectSignatures`) using a 100 ms trailing debounce task during drag.
  - On touch end (`.ended`): cancel debounce task and immediately execute full-fidelity analytical profile with platform mound and ditch-and-berm signature detection.

### Task 21: Floating Resizable Swift Charts Analysis Panel
- **Goal:** Display cross-sectional profile with slope, curvature, and archaeological earthwork annotations without occluding the active survey area.
- **Files:**
  - Modify: [`LidarExplorer/Presentation/ElevationProfileView.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Presentation/ElevationProfileView.swift)
  - Modify: [`LidarExplorer/Presentation/TerrainViewerView.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Presentation/TerrainViewerView.swift)
- [ ] **Step 1: Add signature annotations to `ElevationProfileView`**
  - Render detected platform mounds with `RectangleMark` highlights and `PointMark` summit markers.
  - Render ditch-and-berm complexes with alternating inverted highlights.
  - Add segmented control to toggle between Elevation ($z$), Slope ($dz/dx$), and Curvature ($d^2z/dx^2$).
- [ ] **Step 2: Constrain Swift Charts data point count**
  - Decimate display points passed into `Chart` to a maximum of 384 points using Min-Max decimation, preventing SwiftUI layout stalls.
- [ ] **Step 3: Embed as a draggable, collapsible floating panel**
  - Present as a floating card over `MKMapView` anchored to the top-trailing or bottom-trailing corner, allowing the user to reposition it away from their drawing hand.

### Task 22: Multi-Resolution Viewshed Coordinator & Pin Drag (Major 6 Fix)
- **Goal:** Surface the 720-ray radial sweep viewshed kernel with interactive observer pin placement and radius slider, adhering strictly to the 192 MB surface pool budget.
- **Files:**
  - Modify: [`LidarExplorer/Presentation/TerrainViewerModel.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Presentation/TerrainViewerModel.swift)
  - Modify: [`LidarExplorer/MapLayer/TerrainMapView.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/TerrainMapView.swift)
  - Modify: [`LidarExplorer/Core/Raster/MetalTerrainPipelineActor.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Core/Raster/MetalTerrainPipelineActor.swift)
- [ ] **Step 1: Implement Tiered Viewshed Grid Request in `ElevationTileCoordinator`**
  - If radius $\le 1000\text{ m}$: request $2000 \times 2000$ grid at 1.0 m step.
  - If $1000\text{ m} < \text{radius} \le 2500\text{ m}$: request $2000 \times 2000$ grid at 2.5 m step.
  - If $2500\text{ m} < \text{radius} \le 5000\text{ m}$: request $2000 \times 2000$ grid at 5.0 m step.
  - Enforce maximum dimensions of $2048 \times 2048$ in `MetalTerrainPipelineActor.viewshed`.
- [ ] **Step 2: Add interactive observer pin annotation and overlay renderer**
  - Add draggable `MKPointAnnotation` for the observer eye position.
  - Render viewshed mask as a custom `MKOverlay` backed by `ViewshedResult.display.makeImage()`.

### Task 23: Phase 5 Automated Harness & Verification Checks
- **Files:**
  - Modify: [`Tools/ViewerHarness/main.swift`](file:///Users/herren/dev/LidarExplorer/Tools/ViewerHarness/main.swift)
  - Create: `Tools/ViewerHarness/InteractiveAnalysisChecks.swift`
- [ ] **Step 1: Add automated checks for:**
  - `previewProfile` vs `sampleProfile` decimation accuracy and point bounding ($N \le 256$).
  - Transect gesture arbitration state transitions.
  - Tiered viewshed grid dimension clamping ($\le 2048$).
  - Decimated chart point count bounds ($\le 384$).
- [ ] **Step 2: Run test suite**
  ```bash
  Tools/run-harness.sh
  ```

---

## Phase 6: Historical Overlays & SSURGO Soils Engine

### Task 24: Georeferenced Historical Map Importer (Major 3 & 20 Fix)
- **Goal:** Import scanned historical maps and world files (TFW/JGW, EPSG:3857 or 4326) with memory-safe dimensions.
- **Files:**
  - Create: `LidarExplorer/Services/Historical/HistoricalMapImporter.swift`
  - Create: `LidarExplorer/Domain/HistoricalMap.swift`
- [ ] **Step 1: Document picker and world file parser**
  - Support image files (PNG, JPEG, TIFF) accompanied by a 6-parameter world file (`.tfw`, `.jgw`, `.pgw`).
  - Calculate affine transform to geographic coordinates.
- [ ] **Step 2: Texture dimension clamping and downsampling**
  - If image dimensions exceed $2048 \times 2048$, downsample on background thread using vImage / ImageIO thumbnailing before allocating Metal textures, preventing Jetsam crashes.

### Task 25: Split-Wipe Shader & Interactive Slider
- **Goal:** Provide seamless comparison between modern LiDAR micro-topography and historical maps via a draggable split-wipe curtain.
- **Files:**
  - Modify: `LidarExplorer/Core/Shaders/TerrainKernels.metal`
  - Modify: [`LidarExplorer/Core/Raster/MetalTerrainPipelineActor.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Core/Raster/MetalTerrainPipelineActor.swift)
  - Modify: [`LidarExplorer/Presentation/ViewerBottomDockView.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Presentation/ViewerBottomDockView.swift)
- [ ] **Step 1: Add split-wipe composite fragment shader**
  - Pass split position ($0 \dots 1$) and wipe angle ($0^\circ \dots 180^\circ$) as uniforms.
  - Blend micro-relief on side A and historical georeferenced raster on side B with a 2-pixel anti-aliased dividing line.
- [ ] **Step 2: Add split-wipe UI slider in dock**
  - Use slider for precise one-finger control, avoiding 2-finger gesture collisions with MapKit 3D camera tilt.

### Task 26: SSURGO Soil Data Access (SDA) Ingestion Actor (Major 7 Fix)
- **Goal:** Ingest USDA NRCS SSURGO soil polygons without freezing the main thread or failing during offline survey.
- **Files:**
  - Create: `LidarExplorer/Services/Soils/SSURGOService.swift`
  - Create: `LidarExplorer/Domain/SoilSurvey.swift`
- [ ] **Step 1: Build `actor SSURGOService`**
  - Query USDA Soil Data Access POST REST API (`https://sdmdataaccess.nrcs.usda.gov/Tabular/post.rest`) with spatial query:
    ```sql
    SELECT m.mukey, m.musym, m.muname, c.drclassdcd, c.hydclprs, Geometry::STGeomFromText(m.mupolygonWkt, 4326)
    FROM mapunit m JOIN component c ON c.mukey = m.mukey
    ```
  - Parse WKT polygons on background cooperative threads.
  - Implement negative query caching and persistent disk cache in Application Support directory.

### Task 27: Metal Procedural Soil Hatching
- **Goal:** Render hydric clay vs well-drained sandy loam soil hatching via Metal fragment shaders without expensive CPU polygon triangulation.
- **Files:**
  - Modify: `LidarExplorer/Core/Shaders/TerrainKernels.metal`
  - Modify: [`LidarExplorer/Core/Raster/MetalTerrainPipelineActor.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Core/Raster/MetalTerrainPipelineActor.swift)
- [ ] **Step 1: Screen-space procedural hatch shader**
  - Stencil soil polygons into an integer mask texture.
  - Fragment shader renders diagonal cross-hatching for hydric clays (wet ground/paleochannels) and stippling for sandy loams (mound-building fills).

### Task 28: Phase 6 Automated Harness & Verification Checks
- **Files:**
  - Create: `Tools/ViewerHarness/SoilAndHistoricalChecks.swift`
- [ ] **Step 1: Add tests for:**
  - World file affine coordinate calculation.
  - Historical image downsampling to $\le 2048\text{ px}$.
  - SSURGO SDA query generation and WKT parsing.
- [ ] **Step 2: Run test suite**
  ```bash
  Tools/run-harness.sh
  ```

---

## Phase 7: Optimization, Hardening & Ship Readiness

### Task 29: Coordinator Hardening & Safe Math (Major 4, 5 & Minor 8 Fixes)
- **Goal:** Eliminate runtime traps, unbounded memory leaks, and query hammering in `ElevationTileCoordinator`.
- **Files:**
  - Modify: [`LidarExplorer/Services/Elevation/ElevationTileCoordinator.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Elevation/ElevationTileCoordinator.swift)
- [ ] **Step 1: Replace forced unwraps in `COGResampler.resample`**
  - Safely guard `.isFinite` and handle empty corner sets gracefully:
    ```swift
    guard let minX = corners.map(\.x).filter({ $0.isFinite }).min(),
          let maxX = corners.map(\.x).filter({ $0.isFinite }).max()
    else { return 0 }
    ```
- [ ] **Step 2: Replace raw dictionaries with bounded LRU caches**
  - Implement `LRUCache<URL, COGGeoreference>` (cap 64).
  - Implement `LRUCache<URL, COGByteReader>` (cap 16). Evict single oldest reader on capacity; eliminate `readers.removeAll()`.
- [ ] **Step 3: Implement negative query caching for TNM API**
  - Cache empty product listings for 1 hour to prevent request storms over regions lacking 1m DEM coverage.

### Task 30: Tile Boundary Artifact Rejection Filter (Blocker 3 Fix)
- **Goal:** Eliminate false-positive platform mound and ditch signatures caused by tile edge clamping.
- **Files:**
  - Modify: [`LidarExplorer/Domain/ElevationTransect.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Domain/ElevationTransect.swift)
- [ ] **Step 1: Tile boundary coordinate cross-referencing**
  - Calculate if a detected signature inflection point falls within $1.5\text{ m}$ of a Web Mercator tile grid boundary line ($x = k \cdot 256\text{ px}$).
  - Flag such candidate signatures as `.boundaryArtifact` and suppress them from active archaeological reporting unless corroborated by an unsegmented stitched raster.

### Task 31: Metal System Trace & 60/120 FPS Profiling on iPadOS
- **Goal:** Verify compliance with all non-functional performance and memory limits on physical iPad hardware.
- **Verification Gates:**
  1. Metal System Trace: Zero wait bubbles on GPU timeline; command buffer execution $< 8\text{ ms}$ for 1024² LRM/RRIM.
  2. Frame Rate: Stable 60 FPS (standard iPad) / 120 FPS (iPad Pro ProMotion) during active pencil transect dragging and dynamic lighting sweeps.
  3. Memory Footprint: Peak resident memory $< 500\text{ MB}$ under continuous multi-tile pan and zoom.

### Task 32: Final App Verification, Release Compilation & Documentation
- **Goal:** Validate end-to-end user workflows and produce updated status documentation.
- [ ] Run full test harness:
  ```bash
  Tools/run-harness.sh
  ```
- [ ] Run live 3DEP streaming checks:
  ```bash
  Tools/run-harness.sh --live
  ```
- [ ] Clean release build:
  ```bash
  xcodebuild -scheme LidarExplorer -destination "generic/platform=iOS" -configuration Release CODE_SIGNING_ALLOWED=NO clean build
  ```
- [ ] Update `docs/STATUS.md` with complete Phase 1–7 micro-topography engine verification results.
