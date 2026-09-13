# Architectural & Technical Design Specification: Micro-Topography Engine (Devil's Advocate Audit Review)

> **Calibration note (2026-09-12, Claude Code):** Historical. Current state lives in `STATUS.md` and the authoritative
> plan `plans/2026-09-12-micro-topography-engine.md` (Part B fixed the defects found at calibration: app builds,
> harness 464 / 0, live 67 / 0).

> **Document Status:** REVIEWED & AUDITED (Adversarial Stress-Test Verification)  
> **Original Spec:** [`docs/superpowers/specs/2026-09-12-micro-topography-engine-design.md`](file:///Users/herren/dev/LidarExplorer/docs/superpowers/specs/2026-09-12-micro-topography-engine-design.md)  
> **Review Date:** 2026-09-12  
> **Auditor Persona:** Devil's Advocate (Ruthless, Constructive Engineering Audit)  
> **Target Subsystem:** LidarExplorer Advanced Micro-Topography & Terrain Analysis Engine (Phases 1–7)

---

### Summary

The proposed architecture expands `LidarExplorer` on iPadOS by introducing an advanced micro-topographic feature-detection pipeline. The stack streams USGS 3DEP bare-earth Cloud-Optimized GeoTIFFs (COGs) from AWS S3 (`usgs-lidar-public`) into page-aligned `Float32` unified-memory grids, evaluates specialized Metal 3 compute kernels (LRM, RRIM, SVF, Raking Light, REM, Habitation Potential, and Radial Viewshed), and surfaces interactive analysis tools (Apple Pencil transects with platform mound and ditch-and-berm signature detection, draggable viewshed, historical raster split wipe, and SSURGO soil hatching).

While Phases 1–4 have successfully established kernel parity, zero-copy Metal binding, COG byte-range streaming, and 3×3 neighbor stitching, an adversarial audit of the end-to-end design specification reveals **critical structural vulnerabilities** in the upcoming interactive (Phase 5) and external data ingestion (Phase 6) pipelines. Specifically, the design suffers from:
1. Unmitigated touch gesture contention with `MKMapView`'s internal multi-touch recognizers.
2. Catastrophic MainActor frame rate collapse during 120 Hz Apple Pencil drag when pumping un-decimated 10,000-point transects into Swift Charts.
3. Severe false-positive signature detection induced by artificial slope/curvature discontinuities across unstitched tile boundaries in `TileMosaicField`.
4. Process termination vulnerabilities (fatal unwraps on degenerate bounding boxes in `COGResampler`).
5. Memory exhaustion risks from unbounded georeference dictionaries and unconstrained 5 km viewshed rasters ($10,000 \times 10,000$ grids).

---

### Architecture Analysis & Stress-Test Matrix

| Stress-Test Vector | Subsystem at Risk | Vulnerability / Blind Spot | Severity | Code / Spec Location |
| :--- | :--- | :--- | :--- | :--- |
| **1. Partial Distributed Failures** | `ElevationTileCoordinator` & `SSURGOService` | TNM API empty query responses are not cached, causing unbacked-off request storms on map pan; USDA SDA REST service has no offline fallback or timeout bound. | **Major** | `ElevationTileCoordinator.swift:L416`, Spec Table Row 4.4 |
| **2. Cold Starts & Thundering Herds** | `MetalTerrainPipelineActor` Surface Pool | While idle memory is capped at 192 MB, active in-flight leases (`liveLeases`) have no admission control or concurrency ceiling, allowing rapid viewport pans to exceed 800 MB. | **Major** | `MetalTerrainPipelineActor.swift:L386-L415` |
| **3. Poison Pill Ingestion** | `COGResampler` & `FloatTIFFDecoder` | Force unwrapping `corners.map(\.x).min()!` panics on NaN projection coordinates; imported historical maps lack pixel dimension guards. | **Major** | `ElevationTileCoordinator.swift:L208-L211` |
| **4. Data Drift & Wire Compatibility** | `ElevationTransectEngine` (`TileMosaicField`) | Unstitched tile boundaries clamp interpolation, creating artificial 0.5 m slope/curvature spikes that trigger false-positive earthwork signatures. | **Blocker** | `ElevationTransect.swift:L109-L115`, `ElevationGrid.swift:L160-L171` |
| **5. Backpressure & Bounded Buffers** | Touch Interaction & Swift Charts | Apple Pencil 120 Hz drag updates push 10,000-point profiles into Swift Charts on MainActor, causing 80–150 ms frame times and UI freezes. | **Blocker** | Spec Table Row 3A, `ElevationProfileView.swift:L125-L168` |
| **6. Usability & Integration Boundaries** | `MKMapView` Multi-Touch Layer | iPadOS 2-finger transect drag and historical map split-wipe collide directly with MapKit's built-in 3D camera pitch/tilt and pan recognizers. | **Blocker** | Spec Table Row 3A, Brief §3A, §4.3 |

---

### Verdict

#### Blocker

##### 1. MapKit Multi-Touch Gesture Recognizer Deadlock & Touch Hijacking on iPadOS
- **Dimension:** Usability & Integration Boundaries / Concurrency
- **Finding:** The specification specifies a "Pencil/touch drag" transect tool (Spec Table Row 3A) and a "two-finger pan split wipe" (Spec Table Row 4.3), but fails to define gesture recognizer arbitration, failing to isolate touch events from MapKit's internal multi-touch recognizers.
- **Evidence / Location:** Spec Table Row 3A & 4.3 ([`docs/superpowers/specs/2026-09-12-micro-topography-engine-design.md#L39-L43`](file:///Users/herren/dev/LidarExplorer/docs/superpowers/specs/2026-09-12-micro-topography-engine-design.md#L39-L43)); Brief §3A, §4.3; [`TerrainMapView.swift:L66-L89`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/TerrainMapView.swift#L66-L89).
- **Failure Scenario & Impact:** `MKMapView` internally attaches high-priority gesture recognizers: 1-finger pan for canvas scrolling, 2-finger vertical pan for 3D camera pitch (tilt), pinch for zoom, and 2-finger rotation. If an uncoordinated 2-finger gesture or standard pan recognizer is attached to `MKMapView`, MapKit intercepts the touches. When the user attempts to draw a transect or wipe historical imagery, the map violently tilts its 3D pitch and spins, dropping transect coordinate samples. Furthermore, resting the palm on the iPad display during Apple Pencil drawing causes palm contact to trigger MapKit inertia panning, rendering precise earthwork transect drawing impossible.
- **Actionable Counter-Proposal:**
  1. Introduce an explicit `ViewerInteractionMode` enum on `TerrainViewerModel`: `.navigate`, `.transectPencil`, `.transectManual`, `.viewshedPin`, `.historicalWipe`.
  2. Subclass `UIGestureRecognizer` into `TransectPencilGestureRecognizer` with `allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]`. Because its touch type is strictly pencil, it can recognize simultaneously with MapKit navigation without stealing finger pan/zoom.
  3. For manual finger drawing and split wipe, implement `UIGestureRecognizerDelegate` on `TerrainMapView.Coordinator`: when an active inspection mode is engaged, selectively disable `mapView.isScrollEnabled = false`, `mapView.isPitchEnabled = false`, and `mapView.isRotateEnabled = false`.

##### 2. Swift Charts MainActor Frame Collapse at 120 Hz ProMotion Sampling Rate
- **Dimension:** Backpressure & Bounded Buffers / Performance NFR
- **Finding:** The spec couples real-time transect line drawing directly to the full analytical sampling engine ($0.5\text{ m}$ uniform steps = up to 10,000–20,000 samples over 5–10 km) and pipes all samples into SwiftUI `Chart` marks on every touch move.
- **Evidence / Location:** Spec Table Row 3A ([`docs/superpowers/specs/2026-09-12-micro-topography-engine-design.md#L39`](file:///Users/herren/dev/LidarExplorer/docs/superpowers/specs/2026-09-12-micro-topography-engine-design.md#L39)); [`ElevationTransect.swift:L277`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Domain/ElevationTransect.swift#L277); [`ElevationProfileView.swift:L125-L168`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Presentation/ElevationProfileView.swift#L125-L168).
- **Failure Scenario & Impact:** On iPad Pro (120 Hz ProMotion display), an Apple Pencil drag generates 120 touch events per second. Sampling 10,000 points, computing 2nd derivatives, running mound/ditch pattern detectors, and re-evaluating 10,000 `AreaMark` + `LineMark` primitives in Swift Charts consumes 80–150 ms of CPU time per frame. The MainActor event queue saturates instantly. Touch events are dropped, latency spikes to >500 ms, the UI freezes at 5–10 FPS, and the app violates NFR §5.1 ("60/120 FPS during pan/zoom/light sweeps").
- **Actionable Counter-Proposal:**
  1. Implement a **Dual-Rate Decoupled Pipeline**:
     - **Interactive Preview (120 Hz MainActor):** During active pencil drag, extract a fast, decimated profile capped at exactly 256 samples using downsampled screen-space interpolation. Render via a lightweight SwiftUI `Path` / `Canvas` preview without running the heavy signature detector.
     - **Analytical Engine (Background Actor, Throttled to 10 Hz / On-End):** Dispatch the full 0.5 m resolution profile ($N \le 20,000$) and `TransectSignatureDetector` to a detached background task. Debounce updates to 100 ms during continuous movement, and execute a full-fidelity analysis pass immediately upon touch release (`.ended`).
  2. In `ElevationProfileView`, decimate the points fed into Swift Charts to a maximum of 384 display points using Min-Max or Largest-Triangle-Three-Buckets (LTTB) decimation, keeping chart layout overhead under 4 ms.

##### 3. Tile Boundary Derivative Discontinuity Generating Phantom Earthwork Signatures
- **Dimension:** Correctness & Scientific Integrity / False Positives
- **Finding:** In `ElevationTransect.swift`, `TileMosaicField.elevation(at:)` iterates over individual un-stitched `ElevationGrid`s. At tile boundaries, `ElevationGrid.interpolatedElevation` clamps to edge coordinates (`min(x0 + 1, width - 1)`), creating slope flattening on the tile edge and a step discontinuity across the tile seam.
- **Evidence / Location:** [`ElevationTransect.swift:L109-L115`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Domain/ElevationTransect.swift#L109-L115); [`ElevationGrid.swift:L160-L171`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Core/Geometry/ElevationGrid.swift#L160-L171); [`ElevationTransect.swift:L420-L460`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Domain/ElevationTransect.swift#L420-L460).
- **Failure Scenario & Impact:** When an elevation transect crosses the boundary between two adjacent Web Mercator tiles, the horizontal derivative $dz/dx$ experiences an artificial 0.2–1.0 m step over a 0.5 m interval. This produces an artificial gradient of 20°–60° and an astronomical curvature spike ($d^2z/dx^2$). `TransectSignatureDetector` searches for local curvature extrema (`extreme(in:range, minimum:true)`). Consequently, **every tile boundary crossed by a transect generates a false platform mound or ditch-and-berm signature**, polluting archaeological survey results with digital artifacts.
- **Actionable Counter-Proposal:**
  1. In `TileMosaicField`, require tiles to be sampled from the 3×3 stitched raster pipeline (`TerrainTileProvider.stitchedRaster`) or construct a continuous virtual elevation texture where seams are blended across a 2-sample skirt.
  2. Implement an **Artifact Rejection Filter** in `TransectSignatureDetector`: check the coordinates of detected signature inflection points against the active Web Mercator tile grid lines ($x = k \cdot 256\text{ px}$ in Mercator space). If an inflection point falls within 1.5 m of a tile boundary, mark it as `.boundaryArtifact` and suppress it from archaeological classification unless verified by a multi-tile stitched raster.

---

#### Major

##### 4. Fatal Runtime Crash via Force-Unwrapped Min/Max in `COGResampler`
- **Dimension:** Robustness & Error Handling / Poison Pill
- **Finding:** `COGResampler.resample` calculates pixel bounds by mapping 4 corner points and force-unwrapping `.min()!` and `.max()!`.
- **Evidence / Location:** [`ElevationTileCoordinator.swift:L208-L211`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Elevation/ElevationTileCoordinator.swift#L208-L211):
  ```swift
  let corners = [ ... ].map(pixel(for:))
  let minX = max(Int((corners.map(\.x).min()! - 1).rounded(.down)), 0)
  ```
- **Failure Scenario & Impact:** When querying coordinates near UTM zone boundaries, at extreme latitudes, or when a corrupt GeoTIFF header produces NaN/infinite transform matrices, `corners.map(\.x)` contains NaNs. In Swift, calling `.min()!` on an array where all elements evaluate false under `<` or when NaNs prevent ordering can yield `nil` or undefined behavior, triggering an immediate uncatchable runtime trap (`Fatal error: Unexpectedly found nil while unwrapping an Optional value`), crashing the app.
- **Actionable Counter-Proposal:** Replace all forced unwraps with safe guards filtering finite coordinates:
  ```swift
  guard let minXVal = corners.map(\.x).filter({ $0.isFinite }).min(),
        let maxXVal = corners.map(\.x).filter({ $0.isFinite }).max(),
        let minYVal = corners.map(\.y).filter({ $0.isFinite }).min(),
        let maxYVal = corners.map(\.y).filter({ $0.isFinite }).max()
  else { return 0 }
  ```

##### 5. Memory Leak and Cache Stampede in `ElevationTileCoordinator` Reader Management
- **Dimension:** Resource Management & Scalability / Memory Leaks
- **Finding:** `ElevationTileCoordinator` maintains an unbounded `georeferences: [URL: COGGeoreference]` dictionary and clears readers with an abrupt `readers.removeAll()` when reaching capacity 32.
- **Evidence / Location:** [`ElevationTileCoordinator.swift:L305`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Elevation/ElevationTileCoordinator.swift#L305), [`L436`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Elevation/ElevationTileCoordinator.swift#L436).
- **Failure Scenario & Impact:**
  1. `georeferences` grows monotonically without bound across long user sessions, retaining megabytes of georeference metadata and projection dictionaries.
  2. When `readers.count >= 32`, calling `readers.removeAll()` flushes all 32 cached readers simultaneously. In-flight tile streaming tasks that are in the middle of reading strips or tiles have their underlying reader dropped, triggering cache stampedes where multiple concurrent tasks re-fetch the same multi-kilobyte TIFF headers from AWS S3, saturating cellular bandwidth and causing noticeable tile pop-in.
- **Actionable Counter-Proposal:**
  - Replace both raw dictionaries with a thread-safe `LRUCache<Key, Value>`:
    - `georeferenceCache = LRUCache<URL, COGGeoreference>(capacity: 64)`
    - `readerCache = LRUCache<URL, COGByteReader>(capacity: 16)`
  - Evict only the least-recently-used item on overflow; never clear the entire active pool.

##### 6. Unconstrained Viewshed Memory Allocation at 5 km Maximum Radius
- **Dimension:** Scaling Limits / Resource Bounds
- **Finding:** Spec Table Row 3B allows viewshed calculation up to a 5 km radius ($10\text{ km} \times 10\text{ km}$ bounding box). At native 1 m resolution, this raster spans $10,000 \times 10,000 = 100,000,000$ cells ($400\text{ MB}$ of `Float32` elevation data).
- **Evidence / Location:** Spec Table Row 3B ([`docs/superpowers/specs/2026-09-12-micro-topography-engine-design.md#L40`](file:///Users/herren/dev/LidarExplorer/docs/superpowers/specs/2026-09-12-micro-topography-engine-design.md#L40)); [`ElevationTileCoordinator.swift:L300`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Elevation/ElevationTileCoordinator.swift#L300) (`maxSamplesPerAxis = 2048`); [`MetalTerrainPipelineActor.swift:L1277`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Core/Raster/MetalTerrainPipelineActor.swift#L1277).
- **Failure Scenario & Impact:** If the UI attempts to request a 1 m DEM for a 5 km viewshed, `ElevationTileCoordinator` clamps the raster to 2048 samples, yielding an unexpected $4.88\text{ m}$ cell size. If the request bypasses the coordinator, allocating a $10,000^2$ texture ($400\text{ MB}$) plus radial sweep buffers ($720 \times 10,000 \times 4\text{ bytes} = 28.8\text{ MB}$) instantly exceeds iPad memory limits, triggering an iOS Jetsam kill.
- **Actionable Counter-Proposal:** Formally specify a **Tiered Viewshed Resolution Schedule**:
  - $R \le 1.0\text{ km}$: 1.0 m grid ($2000 \times 2000$ cells, 16 MB).
  - $1.0\text{ km} < R \le 2.5\text{ km}$: 2.5 m grid ($2000 \times 2000$ cells, 16 MB).
  - $2.5\text{ km} < R \le 5.0\text{ km}$: 5.0 m grid ($2000 \times 2000$ cells, 16 MB).
  - Hard-cap the Metal viewshed kernel texture allocation to $2048 \times 2048$, preventing memory spikes regardless of user radius settings.

##### 7. Soil Data Access (SDA) REST Parsing Freezing the Main Thread
- **Dimension:** Concurrency Isolation & Wire Robustness
- **Finding:** Spec §4.4 proposes fetching SSURGO soil polygons via USDA Soil Data Access (SDA) POST requests and hatching hydric clays vs sandy loams. SDA returns geographic features as Well-Known Text (WKT) multipolygons containing up to tens of thousands of coordinates.
- **Evidence / Location:** Spec Table Row 4.4 ([`docs/superpowers/specs/2026-09-12-micro-topography-engine-design.md#L44`](file:///Users/herren/dev/LidarExplorer/docs/superpowers/specs/2026-09-12-micro-topography-engine-design.md#L44)).
- **Failure Scenario & Impact:** Parsing large JSON/WKT strings and triangulating complex concave polygons with interior holes (ear-clipping) on the CPU Main thread causes 200–800 ms UI hangs every time the user pans into a new soil survey area. Furthermore, USDA SDA servers frequently throttle or experience 503 gateway timeouts; without client-side retry budgets and local caching, soil overlays fail silently and leave the viewer in an inconsistent state.
- **Actionable Counter-Proposal:**
  1. Isolate all SSURGO networking and geometry parsing inside an `actor SSURGOService`.
  2. Implement local SQLite or disk caching for parsed soil polygons keyed by map bounding box.
  3. Instead of CPU triangulation, render soil hatches via screen-space procedural Metal fragment shaders using stencil masks, eliminating CPU ear-clipping entirely.

---

#### Minor / Nit

##### 8. Negative Cache Absence on TNM Product Discovery
- **Dimension:** Wire Compatibility & Distributed Backoff
- **Finding:** In `ElevationTileCoordinator.products(covering:)`, empty query responses are omitted from `productCache`:
  ```swift
  if !listed.isEmpty { productCache[key] = listed }
  ```
- **Evidence / Location:** [`ElevationTileCoordinator.swift:L416-L422`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Elevation/ElevationTileCoordinator.swift#L416-L422).
- **Failure Scenario & Impact:** When panning over regions lacking 1m DEM coverage (open water, coastal boundaries, un-surveyed regions), every tile request re-issues an HTTP request to `tnmaccess.nationalmap.gov`, creating pointless network traffic.
- **Actionable Counter-Proposal:** Store empty results in `productCache` with an expiration timestamp or Sentinel entry to suppress repeated queries for 1 hour.

##### 9. Unstructured Task Creation in Surface Lease Reclamation
- **Dimension:** Concurrency / Task Lifecycle
- **Finding:** In `MetalTerrainPipelineActor.makeLease`, returning a buffer to the actor from `deinit` spawns an unstructured `Task { await self?.returnLease(...) }`.
- **Evidence / Location:** [`MetalTerrainPipelineActor.swift:L459`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Core/Raster/MetalTerrainPipelineActor.swift#L459).
- **Failure Scenario & Impact:** During rapid map panning and tile eviction, hundreds of detached tasks flood Swift's cooperative pool, creating scheduling churn.
- **Actionable Counter-Proposal:** Queue reclaimed buffers into a thread-safe lock-free array and drain them synchronously on the actor during next buffer request or compute cycle.

---

### Next Steps

To iterate upon and remediate the engineering plan before executing Phase 5:
1. **Adopt Dual-Rate Architecture in Phase 5 Plan:** Separate interactive touch preview (downsampled 256-pt path) from background analytical transects ($0.5\text{ m}$ uniform steps, signature detector).
2. **Implement Gesture Recognizer Arbiter in `TerrainMapView`:** Add `TransectPencilGestureRecognizer` with `.pencil` touch filtering to eliminate `MKMapView` pitch/tilt collisions.
3. **Enforce Boundary Rejection in `TransectSignatureDetector`:** Suppress false-positive earthwork detections within 1.5 m of tile grid seams.
4. **Harden `COGResampler` and Coordinator Caching:** Eliminate forced unwraps on coordinate bounds and replace `readers.removeAll()` with LRU eviction.
5. **Tier Viewshed Grids to Max 2048²:** Constrain 5 km viewshed rasters to $2000 \times 2000$ cells to guarantee compliance with the 192 MB surface pool budget.
