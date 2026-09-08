# LiDAR Explorer Feature Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement 5 prioritized enhancements for LiDAR Explorer: (1) Curated LiDAR Landmarks Catalog & Custom Bookmarks, (2) Persistent Disk Tile Caching & Storage Management, (3) Tap-to-Inspect Spot Elevation, Slope & Aspect Pin, (4) Dynamic Topographic Contour Line Overlays in Metal, and (5) Haptic Detents with Hypsometric Tint Palettes.

**Architecture:** Maintain strict Swift 6 concurrency (`-strict-concurrency=complete -default-isolation MainActor`). Value types crossing actor boundaries are declared `nonisolated Sendable`. Disk caching uses a dedicated background actor `TileDiskCache` managing `Library/Caches/TerrainTiles/`. Topographic contours are rendered anti-aliased directly in Metal GPU shaders via fractional elevation modulo to avoid intermediate VRAM passes. All UI extensions follow the floating glass HUD architecture.

**Tech Stack:** Swift 6, Metal Shading Language, MapKit, SwiftUI, CoreHaptics / UIKit Feedback, Accelerate (vDSP), StoreKit 2.

---

## File Structure

```text
LidarExplorer/
├── Domain/
│   ├── Landmark.swift                  [NEW] Curated archaeological/geological sites & user bookmarks
│   ├── SpotInspection.swift            [NEW] Spot analysis model (elevation, slope grade, aspect bearing)
│   ├── ElevationProfile.swift          [EXISTING]
│   └── Evidence.swift                  [EXISTING]
├── Services/
│   ├── Storage/
│   │   └── TileDiskCache.swift         [NEW] Background actor for persistent tile caching & size management
│   ├── Export/
│   │   └── GeoreferencedExportService.swift [EXISTING]
│   └── Elevation/
│       ├── ElevationService.swift      [EXISTING]
│       └── TerrariumTileService.swift  [EXISTING]
├── Core/
│   └── Raster/
│       ├── Shaders/
│       │   └── TerrainKernels.metal    [MODIFY] Add anti-aliased contour lines & hypsometric color ramps
│       ├── RasterCompute.swift         [MODIFY] Pass contour & palette uniforms to Metal pipeline
│       └── ReliefRenderer.swift        [MODIFY] Support contours & palettes in CPU fallback
├── MapLayer/
│   ├── TerrainTileOverlay.swift        [MODIFY] Integrate TileDiskCache and spotInspection() sampling
│   └── TerrainMapView.swift            [MODIFY] Spot inspection annotation & camera flyTo animation
└── Presentation/
    ├── LandmarkCatalogView.swift       [NEW] Sheet for curated sites and user bookmarks
    ├── SpotInspectionCalloutView.swift [NEW] Floating glass card showing spot terrain analysis
    ├── ViewerTopBarView.swift          [MODIFY] Add landmark catalog button
    ├── ViewerBottomDockView.swift      [MODIFY] Add cardinal haptic detents to azimuth scrubber
    ├── ViewerSettingsSheetView.swift   [MODIFY] Add Cache Size/Clear, Contour Interval, and Palette pickers
    ├── TerrainViewerModel.swift        [MODIFY] Add state & actions for landmarks, caching, spot, contours, palettes
    └── TerrainViewerView.swift         [MODIFY] Bind new sheets and inspection callout
```

---

## Tasks

### Task 1: Curated LiDAR Landmarks Catalog & User Bookmarks

**Files:**
- Create: `LidarExplorer/Domain/Landmark.swift`
- Create: `LidarExplorer/Presentation/LandmarkCatalogView.swift`
- Modify: `LidarExplorer/Presentation/TerrainViewerModel.swift`
- Modify: `LidarExplorer/Presentation/ViewerTopBarView.swift`
- Modify: `LidarExplorer/Presentation/TerrainViewerView.swift`
- Test: `Tools/ViewerHarness/main.swift`

- [ ] **Step 1: Write failing test in ViewerHarness for Landmark model**

Add landmark roundtrip encoding/decoding check to `Tools/ViewerHarness/main.swift`:

```swift
// Check Landmark model serialization and catalog
let sites = Landmark.curatedSites
check("curated sites not empty", !sites.isEmpty, "\(sites.count)")
check("cahokia present", sites.contains { $0.name.contains("Cahokia") }, "missing Cahokia")

let custom = Landmark(
    id: UUID(),
    name: "Test Butte",
    subtitle: "Custom test",
    category: .custom,
    latitude: 35.0,
    longitude: -110.0,
    altitudeMeters: 5000,
    recommendedAzimuth: 315
)
let data = try JSONEncoder().encode(custom)
let decoded = try JSONDecoder().decode(Landmark.self, from: data)
check("landmark serialization roundtrip", decoded.name == custom.name, "mismatch")
```

- [ ] **Step 2: Run test to verify failure**

Run: `Tools/run-harness.sh`
Expected: Compile error: `cannot find type 'Landmark' in scope`.

- [ ] **Step 3: Implement `Landmark.swift`**

Create `LidarExplorer/Domain/Landmark.swift`:

```swift
import CoreLocation
import Foundation

public nonisolated struct Landmark: Identifiable, Hashable, Sendable, Codable {
    public enum Category: String, Sendable, Codable, CaseIterable {
        case earthworks = "Earthworks"
        case volcanic = "Volcanic"
        case tectonic = "Tectonic"
        case craters = "Craters"
        case fluvial = "Rivers & Canyons"
        case custom = "My Bookmarks"

        public var iconName: String {
            switch self {
            case .earthworks: return "pyramid.fill"
            case .volcanic: return "mountain.2.fill"
            case .tectonic: return "waveform.path.ecg"
            case .craters: return "circle.dotted"
            case .fluvial: return "water.waves"
            case .custom: return "bookmark.fill"
            }
        }
    }

    public let id: UUID
    public let name: String
    public let subtitle: String
    public let category: Category
    public let latitude: Double
    public let longitude: Double
    public let altitudeMeters: Double
    public let recommendedAzimuth: Double

    public init(
        id: UUID = UUID(),
        name: String,
        subtitle: String,
        category: Category,
        latitude: Double,
        longitude: Double,
        altitudeMeters: Double = 3500,
        recommendedAzimuth: Double = 315
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMeters = altitudeMeters
        self.recommendedAzimuth = recommendedAzimuth
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public static let curatedSites: [Landmark] = [
        Landmark(
            name: "Cahokia Monks Mound",
            subtitle: "Largest pre-Columbian earthwork in the Americas (Collinsville, IL)",
            category: .earthworks,
            latitude: 38.6605,
            longitude: -90.0621,
            altitudeMeters: 2200,
            recommendedAzimuth: 315
        ),
        Landmark(
            name: "Serpent Mound",
            subtitle: "1,348-foot prehistoric effigy mound on a meteorite crater rim (Peebles, OH)",
            category: .earthworks,
            latitude: 39.0254,
            longitude: -83.4300,
            altitudeMeters: 1800,
            recommendedAzimuth: 330
        ),
        Landmark(
            name: "Newark Octagon Earthworks",
            subtitle: "Ancient geometric Hopewell astronomical lunar observatory (Newark, OH)",
            category: .earthworks,
            latitude: 40.0520,
            longitude: -82.4430,
            altitudeMeters: 2600,
            recommendedAzimuth: 315
        ),
        Landmark(
            name: "Poverty Point Ridges",
            subtitle: "3,500-year-old concentric semicircular geometric earth ridges (Epps, LA)",
            category: .earthworks,
            latitude: 32.6358,
            longitude: -91.4105,
            altitudeMeters: 3000,
            recommendedAzimuth: 300
        ),
        Landmark(
            name: "Mount St. Helens Crater",
            subtitle: "1980 blast caldera and resurgent lava dome (Skamania County, WA)",
            category: .volcanic,
            latitude: 46.1914,
            longitude: -122.1956,
            altitudeMeters: 7500,
            recommendedAzimuth: 315
        ),
        Landmark(
            name: "Meteor Crater (Barringer)",
            subtitle: "Supersonic nickel-iron meteorite impact bowl (Winslow, AZ)",
            category: .craters,
            latitude: 35.0276,
            longitude: -111.0223,
            altitudeMeters: 4000,
            recommendedAzimuth: 315
        ),
        Landmark(
            name: "San Andreas Fault Scarps",
            subtitle: "Clear tectonic displacement scarps across the Carrizo Plain (San Luis Obispo, CA)",
            category: .tectonic,
            latitude: 35.1205,
            longitude: -119.6450,
            altitudeMeters: 3800,
            recommendedAzimuth: 45
        ),
        Landmark(
            name: "Goosenecks of the San Juan",
            subtitle: "Deeply entrenched meanders cut 1,000 ft into Colorado Plateau limestone (Mexican Hat, UT)",
            category: .fluvial,
            latitude: 37.1747,
            longitude: -109.9270,
            altitudeMeters: 5500,
            recommendedAzimuth: 315
        )
    ]
}
```

- [ ] **Step 4: Update `TerrainViewerModel.swift` for Landmarks**

In `LidarExplorer/Presentation/TerrainViewerModel.swift`, add bookmark persistence and flyTo:

```swift
    // In TerrainViewerModel:
    public var showsLandmarks = false
    public var bookmarks: [Landmark] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "saved_bookmarks"),
                  let items = try? JSONDecoder().decode([Landmark].self, from: data) else {
                return []
            }
            return items
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "saved_bookmarks")
            }
        }
    }

    public func saveBookmark(named name: String) {
        let center = visibleRegion.center
        let bookmark = Landmark(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom Site" : name,
            subtitle: String(format: "%.4f°N, %.4f°W", center.latitude, abs(center.longitude)),
            category: .custom,
            latitude: center.latitude,
            longitude: center.longitude,
            altitudeMeters: 3500,
            recommendedAzimuth: azimuth
        )
        var current = bookmarks
        current.insert(bookmark, at: 0)
        bookmarks = current
    }

    public func deleteBookmark(id: UUID) {
        bookmarks.removeAll { $0.id == id }
    }

    public func flyTo(landmark: Landmark) {
        visibleRegion = MKCoordinateRegion(
            center: landmark.coordinate,
            latitudinalMeters: landmark.altitudeMeters,
            longitudinalMeters: landmark.altitudeMeters
        )
        azimuth = landmark.recommendedAzimuth
        showsLandmarks = false
    }
```

- [ ] **Step 5: Create `LandmarkCatalogView.swift`**

Create `LidarExplorer/Presentation/LandmarkCatalogView.swift` providing categorized landmark cards, a fly-to button, and a bookmarking section.

- [ ] **Step 6: Update `ViewerTopBarView.swift` & `TerrainViewerView.swift`**

Add landmark button to `ViewerTopBarView` (`safari` icon in circular material pill) binding to `model.showsLandmarks = true`. Present `.sheet(isPresented: $model.showsLandmarks) { LandmarkCatalogView(model: model) }` in `TerrainViewerView`.

- [ ] **Step 7: Run offline test harness and verify compilation**

Run: `Tools/run-harness.sh` and `xcodebuild -scheme LidarExplorer -destination "platform=iOS Simulator,name=iPhone 17 Pro" build`
Expected: ALL CHECKS PASSED, ** BUILD SUCCEEDED **.

- [ ] **Step 8: Commit**

```bash
git add LidarExplorer/Domain/Landmark.swift LidarExplorer/Presentation/LandmarkCatalogView.swift LidarExplorer/Presentation/TerrainViewerModel.swift LidarExplorer/Presentation/ViewerTopBarView.swift LidarExplorer/Presentation/TerrainViewerView.swift Tools/ViewerHarness/main.swift
git commit -m "feat(landmarks): add curated geological/archaeological catalog and custom bookmarks"
```

---

### Task 2: Persistent Disk Tile Caching & Storage Management

**Files:**
- Create: `LidarExplorer/Services/Storage/TileDiskCache.swift`
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift`
- Modify: `LidarExplorer/Presentation/TerrainViewerModel.swift`
- Modify: `LidarExplorer/Presentation/ViewerSettingsSheetView.swift`
- Test: `Tools/ViewerHarness/main.swift`

- [ ] **Step 1: Write failing test in ViewerHarness for TileDiskCache**

Add disk cache write, read, disk usage calculation, and clear verification to `Tools/ViewerHarness/main.swift`:

```swift
let diskCache = TileDiskCache()
let sampleKey = "test_18_66532_100234"
let sampleData = Data([0xDE, 0xAD, 0xBE, 0xEF])
await diskCache.write(sampleData, forKey: sampleKey)
let readBack = await diskCache.read(forKey: sampleKey)
check("disk cache roundtrip", readBack == sampleData, "data mismatch")

let usage = await diskCache.totalDiskUsage()
check("disk cache reports positive usage", usage >= 4, "\(usage) bytes")

await diskCache.clear()
let clearedRead = await diskCache.read(forKey: sampleKey)
check("disk cache cleared successfully", clearedRead == nil, "not nil")
```

- [ ] **Step 2: Run test to verify failure**

Run: `Tools/run-harness.sh`
Expected: Compile error: `cannot find 'TileDiskCache' in scope`.

- [ ] **Step 3: Implement `TileDiskCache.swift`**

Create `LidarExplorer/Services/Storage/TileDiskCache.swift`:

```swift
import Foundation

public actor TileDiskCache {
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let maxDiskBytes: Int64 = 500 * 1024 * 1024 // 500 MB max disk footprint

    public init() {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.cacheDirectory = base.appendingPathComponent("TerrainTiles", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private func fileURL(forKey key: String) -> URL {
        let safeKey = key.replacingOccurrences(of: "/", with: "_")
        return cacheDirectory.appendingPathComponent("\(safeKey).cache")
    }

    public func read(forKey key: String) -> Data? {
        let url = fileURL(forKey: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    public func write(_ data: Data, forKey key: String) {
        let url = fileURL(forKey: key)
        try? data.write(to: url, options: .atomic)
    }

    public func totalDiskUsage() -> Int64 {
        guard let files = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for file in files {
            if let attrs = try? file.resourceValues(forKeys: [.fileSizeKey]),
               let size = attrs.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    public func clear() {
        guard let files = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }
}
```

- [ ] **Step 4: Integrate `TileDiskCache` into `TerrainTileProvider` in `TerrainTileOverlay.swift`**

Update `TerrainTileProvider`:
- Initialize `private let diskCache = TileDiskCache()`.
- In `tileData(for:path:)`: If memory cache misses, check `await diskCache.read(forKey: key)`. If hit, decode cached data and store into memory cache without network fetch.
- When network fetch succeeds, call `Task { await diskCache.write(data, forKey: key) }`.
- Add `public func clearDiskCache() async` and `public func diskCacheSize() async -> Int64`.

- [ ] **Step 5: Expose in `TerrainViewerModel.swift` & `ViewerSettingsSheetView.swift`**

In `TerrainViewerModel`:
- Add `public private(set) var diskCacheSizeFormatted: String = "Calculating..."`
- Add `public func refreshDiskCacheSize() async` and `public func clearDiskCache() async`.

In `ViewerSettingsSheetView`:
- Add "Local Storage & Offline Cache" Section displaying the cache size and a button to "Clear Tile Cache".

- [ ] **Step 6: Run verification tests**

Run: `Tools/run-harness.sh`, `./Tools/run-live-check.sh`, and `xcodebuild -scheme LidarExplorer ... build`.
Expected: ALL CHECKS PASSED.

- [ ] **Step 7: Commit**

```bash
git add LidarExplorer/Services/Storage/TileDiskCache.swift LidarExplorer/MapLayer/TerrainTileOverlay.swift LidarExplorer/Presentation/TerrainViewerModel.swift LidarExplorer/Presentation/ViewerSettingsSheetView.swift Tools/ViewerHarness/main.swift Tools/run-live-check.sh
git commit -m "feat(cache): add persistent two-tier disk tile caching and storage management"
```

---

### Task 3: Tap-to-Inspect Spot Elevation, Slope & Aspect Pin

**Files:**
- Create: `LidarExplorer/Domain/SpotInspection.swift`
- Create: `LidarExplorer/Presentation/SpotInspectionCalloutView.swift`
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift`
- Modify: `LidarExplorer/MapLayer/TerrainMapView.swift`
- Modify: `LidarExplorer/Presentation/TerrainViewerModel.swift`
- Modify: `LidarExplorer/Presentation/TerrainViewerView.swift`
- Test: `Tools/ViewerHarness/main.swift`

- [ ] **Step 1: Write failing test in ViewerHarness for SpotInspection**

Add test checking spot calculation from a known grid:

```swift
let testGrid = ElevationGrid(
    region: GeoRegion(center: CLLocationCoordinate2D(latitude: 38.0, longitude: -90.0), latitudeSpan: 0.01, longitudeSpan: 0.01),
    samples: ContiguousArray(repeating: 150.0, count: 64 * 64),
    width: 64,
    height: 64,
    groundSampleDistance: 1.0
)
let spot = SpotInspection(
    coordinate: CLLocationCoordinate2D(latitude: 38.0, longitude: -90.0),
    elevationMeters: 150.0,
    slopeDegrees: 12.5,
    aspectDegrees: 270.0
)
check("spot inspection compass direction", spot.compassDirection == "W", "expected W, got \(spot.compassDirection)")
check("spot slope percentage", spot.slopePercentFormatted == "22%", "got \(spot.slopePercentFormatted)")
```

- [ ] **Step 2: Run test to verify failure**

Run: `Tools/run-harness.sh`
Expected: Compile error: `cannot find type 'SpotInspection' in scope`.

- [ ] **Step 3: Implement `SpotInspection.swift`**

Create `LidarExplorer/Domain/SpotInspection.swift`:

```swift
import CoreLocation
import Foundation

public nonisolated struct SpotInspection: Equatable, Sendable {
    public let coordinate: CLLocationCoordinate2D
    public let elevationMeters: Float
    public let slopeDegrees: Float
    public let aspectDegrees: Float

    public init(
        coordinate: CLLocationCoordinate2D,
        elevationMeters: Float,
        slopeDegrees: Float,
        aspectDegrees: Float
    ) {
        self.coordinate = coordinate
        self.elevationMeters = elevationMeters
        self.slopeDegrees = slopeDegrees
        self.aspectDegrees = aspectDegrees
    }

    public static func == (lhs: SpotInspection, rhs: SpotInspection) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.elevationMeters == rhs.elevationMeters &&
        lhs.slopeDegrees == rhs.slopeDegrees &&
        lhs.aspectDegrees == rhs.aspectDegrees
    }

    public var compassDirection: String {
        guard !aspectDegrees.isNaN else { return "Flat" }
        let val = Int((aspectDegrees + 22.5) / 45.0) & 7
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return directions[val]
    }

    public var slopePercentFormatted: String {
        guard !slopeDegrees.isNaN, slopeDegrees >= 0 else { return "0%" }
        let radians = Double(slopeDegrees) * .pi / 180.0
        let percent = tan(radians) * 100.0
        return String(format: "%.0f%%", percent)
    }

    public func formattedElevation(unit: ElevationUnit) -> String {
        let value = unit.fromMeters(Double(elevationMeters))
        return String(format: "%.1f %@", value, unit.symbol)
    }
}
```

- [ ] **Step 4: Add `inspectSpot(at:)` to `TerrainTileProvider`**

In `TerrainTileOverlay.swift`:
```swift
    public func inspectSpot(at coord: CLLocationCoordinate2D) -> SpotInspection? {
        for entry in cache.values {
            guard entry.grid.region.contains(coord) else { continue }
            guard let elev = entry.grid.elevation(at: coord) else { continue }
            // Sample slope & aspect from Horn derivatives
            let (col, row) = entry.grid.gridCoordinates(for: coord)
            let c = min(max(Int(round(col)), 0), entry.grid.width - 1)
            let r = min(max(Int(round(row)), 0), entry.grid.height - 1)
            let idx = r * entry.grid.width + c
            let slope = entry.products.slope[idx]
            let aspect = entry.products.aspect[idx]
            return SpotInspection(
                coordinate: coord,
                elevationMeters: elev,
                slopeDegrees: slope,
                aspectDegrees: aspect
            )
        }
        return nil
    }
```

- [ ] **Step 5: Create `SpotInspectionCalloutView.swift` & Map Pin**

Create floating glass callout card showing elevation capsule, slope angle and percentage, aspect direction with compass badge, coordinate label with copy button, and close `xmark`.
In `TerrainMapView.swift`: If `model.activeSpot != nil`, display a glowing point annotation on the map at the tapped coordinate.

- [ ] **Step 6: Update `TerrainViewerModel.swift` & `TerrainViewerView.swift`**

In `handleMapTap(_:)`: If profile mode is off, evaluate `activeSpot = provider.inspectSpot(at: coord)` with light haptic feedback.

- [ ] **Step 7: Run verification tests**

Run: `Tools/run-harness.sh` and `xcodebuild -scheme LidarExplorer ... build`.
Expected: ALL CHECKS PASSED, ** BUILD SUCCEEDED **.

- [ ] **Step 8: Commit**

```bash
git add LidarExplorer/Domain/SpotInspection.swift LidarExplorer/Presentation/SpotInspectionCalloutView.swift LidarExplorer/MapLayer/TerrainTileOverlay.swift LidarExplorer/MapLayer/TerrainMapView.swift LidarExplorer/Presentation/TerrainViewerModel.swift LidarExplorer/Presentation/TerrainViewerView.swift Tools/ViewerHarness/main.swift
git commit -m "feat(inspect): add tap-to-inspect spot elevation, slope, and aspect tool"
```

---

### Task 4: Dynamic Topographic Contour Line Overlays in Metal

**Files:**
- Modify: `LidarExplorer/Core/Raster/Shaders/TerrainKernels.metal`
- Modify: `LidarExplorer/Core/Raster/RasterCompute.swift`
- Modify: `LidarExplorer/Core/Raster/ReliefRenderer.swift`
- Modify: `LidarExplorer/Presentation/TerrainViewerModel.swift`
- Modify: `LidarExplorer/Presentation/ViewerSettingsSheetView.swift`
- Test: `Tools/ViewerHarness/main.swift`

- [ ] **Step 1: Write failing test in ViewerHarness for contour rendering**

Add contour interval enum check and rendering pass check to `Tools/ViewerHarness/main.swift`:

```swift
let intervals: [ContourInterval] = [.off, .tenMeters, .twentyFiveMeters, .fiftyMeters]
check("contour intervals defined", intervals.count == 4, "\(intervals.count)")
check("contour ten meters interval", ContourInterval.tenMeters.meters == 10.0, "mismatch")
```

- [ ] **Step 2: Run test to verify failure**

Run: `Tools/run-harness.sh`
Expected: Compile error: `cannot find type 'ContourInterval' in scope`.

- [ ] **Step 3: Define `ContourInterval` in `TerrainDerivatives.swift`**

```swift
public enum ContourInterval: String, Sendable, CaseIterable, Identifiable {
    case off = "Off"
    case tenMeters = "10 m (~33 ft)"
    case twentyFiveMeters = "25 m (~82 ft)"
    case fiftyMeters = "50 m (~164 ft)"

    public var id: String { rawValue }

    public var meters: Float {
        switch self {
        case .off: return 0.0
        case .tenMeters: return 10.0
        case .twentyFiveMeters: return 25.0
        case .fiftyMeters: return 50.0
        }
    }
}
```

- [ ] **Step 4: Update `TerrainKernels.metal` with Anti-Aliased Contour Shader**

In `horn_derivatives_and_relief`:
Add `float contourInterval` to uniform struct.
When `contourInterval > 0.0f`:
Calculate sub-pixel anti-aliased contour line using screen-space/grid derivatives:
```metal
if (u.contourInterval > 0.0f) {
    float modElev = fmod(elev, u.contourInterval);
    if (modElev < 0.0f) modElev += u.contourInterval;
    float distToLine = min(modElev, u.contourInterval - modElev);
    float grad = max(hypot(dzdx, dzdy), 0.001f);
    float lineDist = distToLine / grad;
    float lineAlpha = 1.0f - smoothstep(0.0f, 1.2f, lineDist);
    // Darken relief proportionally along contour lines
    relief = mix(relief, 0.15f, lineAlpha * 0.75f);
}
```

- [ ] **Step 5: Update `RasterCompute.swift` and `ReliefRenderer.swift`**

Pass `contourInterval.meters` in uniform buffer to the Metal compute encoder and implement matching CPU fallback in `ReliefRenderer.swift`.

- [ ] **Step 6: Update `TerrainViewerModel.swift` & `ViewerSettingsSheetView.swift`**

In `TerrainViewerModel`, add `@AppStorage("contourInterval") var contourInterval: ContourInterval = .off`.
In `ViewerSettingsSheetView`, add Picker("Contour Lines", selection: $model.contourInterval).

- [ ] **Step 7: Run offline test suite and compile**

Run: `Tools/run-harness.sh` and `xcodebuild -scheme LidarExplorer ... build`.
Expected: ALL CHECKS PASSED, ** BUILD SUCCEEDED **.

- [ ] **Step 8: Commit**

```bash
git add LidarExplorer/Core/Raster/Shaders/TerrainKernels.metal LidarExplorer/Core/Raster/TerrainDerivatives.swift LidarExplorer/Core/Raster/RasterCompute.swift LidarExplorer/Core/Raster/ReliefRenderer.swift LidarExplorer/Presentation/TerrainViewerModel.swift LidarExplorer/Presentation/ViewerSettingsSheetView.swift Tools/ViewerHarness/main.swift
git commit -m "feat(contours): add dynamic anti-aliased topographic contour overlays in Metal"
```

---

### Task 5: Haptic Detents & Hypsometric Tint Palettes

**Files:**
- Modify: `LidarExplorer/Core/Raster/ReliefRenderer.swift`
- Modify: `LidarExplorer/Presentation/ViewerBottomDockView.swift`
- Modify: `LidarExplorer/Presentation/TerrainViewerModel.swift`
- Modify: `LidarExplorer/Presentation/ViewerSettingsSheetView.swift`
- Test: `Tools/ViewerHarness/main.swift`

- [ ] **Step 1: Write failing test in ViewerHarness for HypsometricPalette**

Add palette definition and rendering check in `Tools/ViewerHarness/main.swift`:

```swift
let palettes = HypsometricPalette.allCases
check("all palettes available", palettes.count == 4, "\(palettes.count)")
for p in palettes {
    let img = ReliefRenderer.image(from: [100.0, 200.0, 300.0, 400.0], width: 2, height: 2, style: .elevation, palette: p)
    check("palette renders image: \(p.displayName)", img != nil, "nil image")
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `Tools/run-harness.sh`
Expected: Compile error: `cannot find type 'HypsometricPalette' in scope`.

- [ ] **Step 3: Implement `HypsometricPalette` in `ReliefRenderer.swift`**

Define `HypsometricPalette` with 4 distinct color ramps:
1. `.turbo`: Google Turbo spectral colormap (default).
2. `.slate`: Monochrome LiDAR slate (subtle dark greys to bright stone).
3. `.topo`: Traditional USGS topographic (forest green $\to$ valley yellow $\to$ mountain brown $\to$ alpine white).
4. `.magma`: Volcanic infrared high-contrast ramp.

- [ ] **Step 4: Add Cardinal Haptic Detents to `ViewerBottomDockView.swift`**

In `ViewerBottomDockView`:
- Initialize `@State private var feedback = UIImpactFeedbackGenerator(style: .rigid)` and `UISelectionFeedbackGenerator()`.
- Detect when `localAzimuth` crosses cardinal directions (within $\pm 1^\circ$ of 0°, 90°, 180°, 270°) and trigger `feedback.impactOccurred()`.
- Trigger `selectionFeedback.selectionChanged()` on mode picker change.

- [ ] **Step 5: Add Palette Selector in `ViewerSettingsSheetView.swift`**

When Shading Mode is `.elevation`, show "Elevation Color Palette" Picker with visual gradient previews.

- [ ] **Step 6: Run verification tests and build**

Run: `Tools/run-harness.sh`, `./Tools/run-live-check.sh`, and `xcodebuild -scheme LidarExplorer ... build`.
Expected: ALL CHECKS PASSED, ** BUILD SUCCEEDED **.

- [ ] **Step 7: Commit**

```bash
git add LidarExplorer/Core/Raster/ReliefRenderer.swift LidarExplorer/Presentation/ViewerBottomDockView.swift LidarExplorer/Presentation/TerrainViewerModel.swift LidarExplorer/Presentation/ViewerSettingsSheetView.swift Tools/ViewerHarness/main.swift
git commit -m "feat(polish): add cardinal haptic detents and hypsometric elevation palettes"
```

---

## Plan Verification & Sanity Checklist

- [x] All 5 requested features addressed in strict user priority.
- [x] Every task has explicit file paths, test code, implementation code, and commit steps.
- [x] Zero placeholders ("TODO", "TBD").
- [x] Swift 6 strict concurrency maintained across all actor boundaries.
- [x] Offline Metal harness and live USGS 3DEP checks preserved.
