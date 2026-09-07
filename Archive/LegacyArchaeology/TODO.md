# LidarExplorer — TODO

> Last reviewed: 2026-03-20
> Overall completion: ~70% core functionality, ~0% advanced features

---

## Priority Definitions

| Priority | Description |
|----------|-------------|
| **P0** | Break/fix, core functionality, existing feature improvements |
| **P1** | New feature implementation that unblocks major capability |
| **P2** | Polish, UX improvements, developer experience |
| **P3** | Nice-to-have enhancements |
| **P4** | Work when you have free time / long-term vision |

---

## P0 — Critical / Core Functionality

### 1. Sentinel-2 Fallback Data Producing Unreliable Validation Scores

**Problem:** When the Sentinel Hub API is unavailable (no credentials, network error, or auth failure), `SatelliteImageryService.swift` falls back to `generateFallbackData()` (line ~793) which returns hardcoded band values (`B02=0.08, B03=0.10, B04=0.08, B08=0.30`). These fake values flow into `MultiSourceValidationService.validateAgainstSatellite()` and `validateVegetation()`, which together account for 50% of the composite validation weight (30% satellite + 20% vegetation). This means half the validation system is producing scores based on fiction.

**How to fix:**

1. **Short-term — Make fallback honest:** In `MultiSourceValidationService.swift`, detect when satellite data is fallback/synthetic. Add a `isRealData: Bool` field to `SatelliteImageData`. When `isRealData == false`, skip the satellite and vegetation validation sources entirely and re-weight the composite score across only OSM (35%) and geometric (15%) — normalized to 70%/30%. This way the system doesn't pretend to have satellite data it doesn't have. The key change is in `calculateCompositeScore()` (line ~325): only include sources that have real data.

2. **Long-term — Fix the TIFF parsing chain:** The actual API integration (`fetchFromSentinelHub`, line ~294) is mostly built — it constructs the correct Process API request with evalscript for B02/B03/B04/B08 in FLOAT32 TIFF format. The failure point is usually authentication (`getAccessToken()` returning nil) or TIFF parsing (`parseTiffFloatBands`). Steps:
   - Ensure Copernicus credentials are configured (see `SENTINEL_HUB_SETUP.md`). Credentials load from `COPERNICUS_CLIENT_ID` / `COPERNICUS_CLIENT_SECRET` env vars or `AppSettings`.
   - Add integration test: hit the Process API with known coordinates (e.g., a parking lot at `38.8977, -77.0365`) and verify parsed bands are reasonable (blue ~0.05-0.15, NIR ~0.1-0.4 for vegetation).
   - The `parseRawTiffFloats` and `extractFirstPixelValues` fallback chain (line ~467) has been through multiple iterations — test each branch with a real 1x1 FLOAT32 TIFF to find which parser path succeeds.

**Files:** `SatelliteImageryService.swift` (lines 286-291, 793-808, 419-509), `MultiSourceValidationService.swift` (lines 59-65, 238-261, 325-345)

---

### 2. Re-enable Disabled Detection Algorithms (Linear, Circular, Terrace)

**Problem:** In `HistoricalAnalysisEngine.swift` lines 294-308, three of four detection algorithms are commented out because they were producing ~90% of false positives. Only mound detection (via `detectMounds` + `detectLargeFeatures`) is active.

**How to fix — approach each detector independently:**

**Linear Features** (`detectLinearFeatures`, line ~840):
- The current thresholds (line ~47) are already "ultra strict" — `minimumClusterPoints: 35`, `minimumAlignmentScore: 3.0`. The problem is that roads, fences, and drainage ditches all trigger this detector.
- Fix: Add a **post-detection OSM cross-reference**. After detecting a linear candidate, query OSM within a 50m buffer around the feature's line. If OSM returns a road/highway/fence/wall/pipeline within 20m parallel to the detected line, discard it. The `OpenStreetMapService.queryRegion()` already returns roads; you just need to check angular alignment (dot product of feature direction vs. road direction > 0.9 = parallel = modern).
- Also add a **curvature check**: historical trails/walls tend to follow terrain contours with gentle curves. Perfectly straight features (straightness > 0.6, line ~54) are almost always modern. Currently there's a penalty, but it's not enough — make straightness > 0.55 an outright disqualification.

**Circular Patterns** (`detectCircularPatterns`, line ~984):
- False positives come from water tanks, roundabouts, silos, retention ponds.
- Fix: After detection, query OSM for `man_made=*`, `landuse=reservoir`, `amenity=*` tags within the circle's radius. If found, discard.
- Add an **elevation profile check**: historical circular features (henges, ring forts) should show a bank-and-ditch elevation signature — elevated ring with depression inside or outside. Modern circles (tanks, ponds) are either perfectly flat or uniformly elevated. Sample 8 points around the circumference and 1 center point. If center elevation ≈ circumference elevation (< 0.3m difference), likely modern.

**Terraces** (`detectTerraces`, line ~1103):
- False positives come from graded construction pads, parking lots, sports fields.
- Fix: The `minimumVariance: 0.20` (line ~91) threshold tries to exclude "too flat" areas but isn't enough. Add an **area regularity check**: historical terraces have irregular boundaries that follow hillside contours. Modern grading has straight edges. Analyze the terrace boundary points for angular regularity — if >60% of boundary segments are within 5° of 0°/90°/180°/270°, it's a modern rectangular pad.
- Cross-reference with satellite data: a terrace covered in dense vegetation (NDVI > 0.6) is much more likely historical than one with bare earth or artificial surface.

**Re-enable strategy:** Uncomment one detector at a time. Test against 5 known archaeological sites and 5 known modern areas. Only keep it enabled if false positive rate is < 20%.

**Files:** `HistoricalAnalysisEngine.swift` (lines 294-308 for enable/disable, 840-982 for linear, 984-1101 for circular, 1103+ for terrace)

---

### 3. Current Location Button Bug

**Problem:** On first app launch after granting location permission, the "go to my location" button requires 2 taps. Partially fixed in commit 2a904d3.

**How to fix:** The root cause is a race condition. When `CLLocationManager` receives authorization, there's a delay before the first `didUpdateLocations` callback fires. The button handler likely reads `locationManager.location` before it's populated.

- In `LocationManager.swift`, add a `@Published var hasReceivedFirstLocation: Bool = false` flag. Set it `true` in `didUpdateLocations`.
- In the button handler (likely in `ContentView.swift` or `ContentViewModel.swift`), if `hasReceivedFirstLocation` is false, call `locationManager.requestLocation()` and `await` the first update before animating the map, rather than reading the (nil) cached location.
- Alternative simpler fix: in the button tap handler, if `locationManager.location == nil`, add a 0.5s delay + retry before giving up.

**Files:** `LocationManager.swift`, `ContentView.swift` or `ContentViewModel.swift`

---

### 4. Detection Accuracy Validation

**Problem:** No quantitative metrics exist. The claimed "85-95% false positive reduction" is unverified.

**How to fix:**

1. **Create a test dataset.** Build a JSON file (`test_sites.json`) with two arrays:
   - `known_archaeological`: Coordinates of verified sites (pull from the app's existing `archaeological_sites.json` + publicly known mound sites like Cahokia `38.6553, -90.0621`, Poverty Point `32.6348, -91.4073`, Serpent Mound `39.0256, -83.4305`)
   - `known_modern`: Coordinates of obvious non-archaeological features (parking lots, highway interchanges, residential neighborhoods, golf courses)

2. **Create a validation script** (can be a Swift test or standalone):
   - For each coordinate, run `HistoricalAnalysisEngine.analyzeRegion()` with a 500m region
   - Record: detected features count, max confidence, feature types
   - Calculate:
     - **True Positive Rate**: % of known sites where a feature is detected with confidence > medium
     - **False Positive Rate**: % of known modern sites where a feature is incorrectly detected
     - **Precision**: TP / (TP + FP)
     - **Recall**: TP / (TP + FN)

3. **Establish baseline** with current mound-only detection, then re-measure as you re-enable other detectors.

**Files:** New file `LidarExplorer/Data/test_sites.json`, new XCTest file or script

---

## P1 — Major New Capabilities

### 5. Add Automated Test Suite

**Problem:** Zero test coverage. Every refactor is a gamble.

**How to fix:**

1. **Add XCTest target** in Xcode: File → New → Target → Unit Testing Bundle → "LidarExplorerTests".

2. **Priority test targets** (in order of value):

   **`HistoricalAnalysisEngine` tests:**
   - Test `detectMounds` with synthetic elevation data: create a 25x25 grid of flat terrain (`200.0`), place a Gaussian bump at center (+3m), verify exactly 1 mound detected.
   - Test that flat terrain produces 0 detections.
   - Test that a grid of uniform peaks (spacing < `minimumPeakSeparation`) produces ≤ 1 detection (NMS working).
   - Test that a peak below `minimumElevationChange` (2.0m) is not detected.

   **`MultiSourceValidationService` tests:**
   - Test `calculateCompositeScore` with known inputs: all 1.0 → expect 1.0; all 0.0 → expect 0.0; OSM=0.0, rest=1.0 → expect ~0.65 (OSM weight is 0.35).
   - Test `validateGeometry` with a mound that has height/diameter ratio of 0.5 (too steep) → expect score < 0.6.

   **`DEMDataService` tests:**
   - Mock the USGS API response. Test that a valid JSON point query response parses correctly.
   - Test that a malformed response doesn't crash (returns error gracefully).

   **`SatelliteImageryService` tests:**
   - Create a minimal valid TIFF file (8-byte header + IFD + 16 bytes of FLOAT32 data for 4 bands). Test that `parseTiffFloatBands` extracts the correct values.
   - Test that invalid TIFF data returns nil (not crash).

3. **How to mock actor dependencies:** Since services use `static let shared` singletons, consider adding protocol abstractions (e.g., `protocol DEMDataProviding`) and inject via initializer for testability. Start with pure-logic tests that don't need mocking (geometry validation, score calculation, TIFF parsing).

**Files:** New `LidarExplorerTests/` directory with test files per service

---

### 6. Complete Temporal Analysis Service

**Problem:** `TemporalAnalysisService.swift` has a working `analyzeTemporalStability()` method that samples a single time snapshot, but `detectVolumetricChanges()` returns `nil` and the `DataFusionFramework` struct (line ~289) is entirely placeholder.

**How to fix:**

1. **True temporal comparison requires multi-date DEM data.** USGS 3DEP doesn't provide historical snapshots via point query — it returns the latest available elevation. For actual temporal analysis, you'd need:
   - Option A: Use USGS National Map's WCS (Web Coverage Service) to request elevation from different LIDAR collection dates. The 3DEP data has collection metadata; query `https://elevation.nationalmap.gov/arcgis/rest/services/3DEPElevation/ImageServer` with a `time` parameter.
   - Option B: Use Sentinel-2 time series. Request the same pixel at monthly intervals over 2+ years. Vegetation changes (NDVI delta) are a proxy for ground disturbance.

2. **Implement `detectVolumetricChanges` (line ~115):**
   - Fetch elevation grids for the region at 2+ time points (if available)
   - Subtract grids to produce a change surface
   - Sum absolute changes × cell area = volume change
   - Classify: positive volume = fill, negative = cut, spatially diffuse = erosion

3. **Implement NDVI calculation** in `DataFusionFramework.analyzeVegetationPatterns` (line ~318):
   - NDVI = (NIR - Red) / (NIR + Red) = (B08 - B04) / (B08 + B04)
   - This calculation is trivial once real Sentinel-2 data is flowing (depends on P0 item #1)
   - NDVI > 0.6 = dense vegetation (likely undisturbed), NDVI 0.2-0.6 = sparse, NDVI < 0.2 = bare/artificial

4. **Weather integration** (line ~341): Use NOAA's Climate Data Online API (`https://www.ncdc.noaa.gov/cdo-web/api/v2/`). Free API key required. Fetch precipitation data for the region and correlate with erosion patterns. This is a nice-to-have within temporal analysis — lower priority than the DEM/NDVI items.

**Files:** `TemporalAnalysisService.swift` (all), `SatelliteImageryService.swift` (for NDVI data source)

---

### 7. Offline Mode

**Problem:** The app requires internet for USGS elevation queries, OSM queries, and satellite data. Useless in the field at remote sites.

**How to fix:**

1. **Elevation tile caching** — `TileCacheManager.swift` already exists. Extend it to:
   - After any successful `DEMDataService.fetchElevationData()` call, persist the raw grid to disk (e.g., `FileManager.default.urls(for: .cachesDirectory)` + region key).
   - On fetch, check disk cache before hitting the network.
   - Format: simple binary file — write grid dimensions (2x Int32) + flattened Double array. Fast to read/write.

2. **Region pre-download:** Add a "Download for offline" button in `SettingsView.swift`. When tapped:
   - Take the current visible map region
   - Subdivide into ~500m tiles
   - Fetch elevation data for each tile sequentially (respect USGS rate limits — 1 req/sec)
   - Show progress bar
   - Store tile count + bounding box in UserDefaults so the app knows what's cached

3. **OSM data caching:** After `OpenStreetMapService.queryRegion()`, persist `OSMQueryResult` to disk as JSON. Cache key = rounded bounding box. Check cache on query.

4. **Network detection:** Use `NWPathMonitor` to detect connectivity. When offline:
   - Skip satellite and OSM validation sources
   - Re-weight composite score to only use geometric validation
   - Show a "Offline mode — limited validation" banner in the UI

**Files:** `TileCacheManager.swift`, `DEMDataService.swift`, `OpenStreetMapService.swift`, `SettingsView.swift`, new `NetworkMonitor.swift`

---

## P2 — Polish & UX

### 8. Historical Overlay Rendering

**Problem:** Trail overlays look ugly when complexity increases. Civil War sites are incomplete.

**How to fix:**

- **Trail rendering:** In `USGSMapView.swift`, trails are likely rendered as `MKPolyline` overlays. The issue is probably rendering every segment at every zoom level. Fix: implement **level-of-detail rendering** — at low zoom, show simplified polylines (Ramer-Douglas-Peucker algorithm with tolerance ~0.01°). At high zoom, show full detail. MapKit's `MKPolylineRenderer` supports `lineWidth` and `alpha` — decrease both at low zoom for complex trails.
- **Civil War sites:** The `civil_war_sites.json` data file needs more entries. Good sources: National Park Service's ABPP (American Battlefield Protection Program) database at `https://www.nps.gov/subjects/battlefields/`. Add 50-100 smaller engagements with coordinates.
- **Colonial settlements:** Create `colonial_settlements.json`. Sources: NPS National Historic Landmarks list, Library of Congress geographic data.

**Files:** `USGSMapView.swift` (rendering), `Data/civil_war_sites.json`, new `Data/colonial_settlements.json`, `HistoricalOverlayService.swift`

---

### 9. User-Facing Confidence Tuning

**Problem:** Users can't adjust detection sensitivity. The `minimumConfidence` setting exists in `AnalysisSettings` but isn't easily tweakable.

**How to fix:** In `SettingsView.swift`, add a slider:
```swift
Slider(value: $sensitivityValue, in: 0.3...0.95, step: 0.05)
```
Map slider value to `ConfidenceLevel` thresholds. Label it clearly: "Higher = fewer results but more accurate. Lower = more results but more false positives." Persist via `AppSettings`.

**Files:** `SettingsView.swift`, `AppSettings.swift`

---

### 10. Error Reporting & Analytics

**Problem:** No visibility into production crashes or API failure rates.

**How to fix:**
- Add Firebase Crashlytics (free tier). `pod 'Firebase/Crashlytics'` or SPM. Initialize in `LidarExplorerApp.swift`.
- Add lightweight telemetry: log each analysis run's result (region, feature count, validation scores) to Firebase Analytics custom events. This gives you real accuracy data from the field.
- Add API health tracking: count sequential failures per service (USGS, OSM, Sentinel). After 3 consecutive failures, show user a degraded-mode banner instead of silently falling back.

**Files:** `LidarExplorerApp.swift`, `Podfile` or `Package.swift`, `HistoricalAnalysisEngine.swift`

---

### 11. Multi-Angle Hillshade

**Problem:** Single-angle hillshade misses features aligned with the light direction.

**How to fix:** In the DEM analysis step (inside `analyzeRegion` or as a pre-processing step):
- Compute hillshade from 4 azimuths (45°, 135°, 225°, 315°) at a fixed altitude angle (30°).
- For each cell: `hillshade = cos(zenith) * cos(slope) + sin(zenith) * sin(slope) * cos(azimuth - aspect)`.
- Combine by taking the **standard deviation** across the 4 hillshades at each cell. High std dev = feature visible from some angles but not others = subtle terrain anomaly worth investigating.
- Feed the std-dev grid into `detectMounds`/`detectLinearFeatures` as an additional signal (multiply confidence by a factor based on hillshade variance).

**Files:** `HistoricalAnalysisEngine.swift` (new private method `calculateMultiAngleHillshade`)

---

## P3 — Enhancements

### 12. Machine Learning Detection

**How to fix:** Start small with Core ML.

1. **Training data:** Export 500+ labeled 50x50 elevation grids from the app. Labels: `mound`, `natural_hill`, `modern_construction`, `flat`. Use the test dataset from item #4 plus manual labeling.
2. **Model:** Train a simple CNN (3 conv layers + dense) in Python with TensorFlow/PyTorch. Input: 50x50 single-channel (elevation). Output: 4-class softmax. Export to `.mlmodel` via `coremltools`.
3. **Integration:** Load model in `HistoricalAnalysisEngine.swift` via `MLModel(contentsOf:)`. For each candidate region, extract the 50x50 grid, run inference, use the `mound` probability as a confidence multiplier alongside the existing rule-based score.
4. **Iteration:** As users validate/invalidate detections, log the data for retraining.

---

### 13. Field Tools

**How to fix:**

- **GPS waypoint navigation:** When user taps a detected feature, show a "Navigate" button. Use `MKDirections` for walking directions, or simpler: show bearing + distance from current location using the haversine formula. Update in real-time via `CLLocationManager`.
- **Distance display:** In the feature detail sheet (likely `HistoricalFeaturesView.swift`), compute `CLLocation.distance(from:)` between user location and feature coordinate. Display as "X.X km away, bearing NNE".
- **AR overlay:** Use ARKit's `ARGeoTrackingConfiguration` (iOS 14+). Place `ARAnchor` at each detected feature's coordinate. Render a semi-transparent 3D shape matching the feature type (dome for mound, cylinder for circular). This is a larger effort — estimate 2-3 weeks.

---

### 14. Drainage Pattern Detection

**How to fix:** From the DEM grid:
1. Compute flow direction: for each cell, find the steepest downhill neighbor (D8 algorithm).
2. Compute flow accumulation: count upstream cells draining through each cell.
3. Cells with flow accumulation > threshold = drainage channels.
4. Look for **anomalous interruptions** in drainage patterns — a mound or wall will divert flow, creating a distinctive pattern where channels split and rejoin. This is a strong archaeological signal.

**Files:** New method in `HistoricalAnalysisEngine.swift` or new `DrainageAnalysisService.swift`

---

## P4 — Long-term Vision

### 15. Community & Collaboration
- Share discoveries: export feature as GeoJSON, share via standard iOS share sheet.
- Crowdsourced verification: requires a backend (Firebase Realtime Database or similar). Each feature gets up/down votes from other users.
- Field reports: structured form (date, conditions, photos, notes) → store in CloudKit or Firebase.

### 16. Geographic Expansion
- USGS 3DEP only covers the US. For international support, integrate with Copernicus DEM (30m global, free) via `https://spacedata.copernicus.eu/`. The `DEMDataService` would need a second provider path that activates based on coordinate bounds (lat outside 24°-50°N or lon outside 66°-125°W → use Copernicus).

### 17. Spectral Analysis
- Depends on Sentinel-2 real data (P0 item #1) being fully working.
- Beyond NDVI, compute: NDWI (water index) = (B03 - B08) / (B03 + B08), BSI (bare soil index) = ((B04 + B11) - (B03 + B08)) / ((B04 + B11) + (B03 + B08)). Note: B11 (SWIR) requires adding it to the evalscript band list.

---

## Completed

- [x] ~~Real DEM Integration~~ — USGS 3DEP with 1m resolution, caching, batch point queries
- [x] ~~OpenStreetMap Integration~~ — Overpass API queries for modern infrastructure proximity filtering
- [x] ~~Sentinel Hub Framework~~ — OAuth flow, Process API request construction, TIFF parsing chain (real data pending)
- [x] ~~Multi-Source Validation Framework~~ — Weighted composite scoring from 4 sources (OSM 35%, satellite 30%, vegetation 20%, geometric 15%)
- [x] ~~Historical Overlays~~ — 49 curated sites across Native American territories, Civil War, trails, archaeological sites
- [x] ~~Contextual Intelligence~~ — Wikidata SPARQL + OSM historic feature queries inform regional detection context
- [x] ~~Mound Detection~~ — Local maxima + large feature detection with sub-pixel refinement, NMS, prominence filtering
- [x] ~~Edge Sharpness Analysis~~ — Geometric validation for detected feature boundaries
- [x] ~~Spatial Search Service~~ — Efficient coordinate-based querying
- [x] ~~Tile Cache Manager~~ — In-memory elevation data caching layer
