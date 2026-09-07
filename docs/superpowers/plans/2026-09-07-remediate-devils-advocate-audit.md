# Remediation of Devil's Advocate Technical Audit Findings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate all critical vulnerabilities, rendering bugs, projection distortions, compliance risks, and concurrency bottlenecks identified in the Devil's Advocate audit of LidarExplorer.

**Architecture:** Refactor the terrain streaming and compute pipeline to request native square Web Mercator (EPSG:3857) 3DEP rasters, enforce strict cropping of elevation grids to match shaded products, make Metal shader dispatch non-blocking with buffer pooling, harden TIFF decoding against poison pills, deduplicate ancestor tile loads via singleflight coalescing, populate required privacy manifest reasons, and sequence first-launch modal presentations cleanly.

**Tech Stack:** Swift 6 (Strict Concurrency), MapKit (`MKTileOverlay`), Metal (Compute Kernels), Accelerate / vDSP, StoreKit 2, Google Mobile Ads / UMP SDK, CoreLocation.

---

## File Structure & Responsibilities

| File | Primary Responsibility | Changes in this Plan |
| :--- | :--- | :--- |
| [`FloatTIFFDecoder.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Decoding/FloatTIFFDecoder.swift) | Single-band Float32 GeoTIFF decoding | Guard against empty byte count arrays (`$0[-1]` crash), add maximum dimension limit (4096 px) to prevent OOM panics, and support EPSG:3857 projected bounds. |
| [`TerrainTileOverlay.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/TerrainTileOverlay.swift) | Tile loading, shading orchestration, and tile caching | Crop `ElevationGrid` alongside `ReliefProducts` so `.elevation` style matches dimensions; implement singleflight coalescing for ancestor tiles; implement true LRU cache promotion; classify cancellations separately from failures. |
| [`ElevationGrid.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Core/Geometry/ElevationGrid.swift) | Contiguous elevation raster representation | Add `cropped(margin:)` method to produce a properly bounded subgrid and adjusted `GeoRegion`. |
| [`GeoRegion.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Core/Geometry/GeoRegion.swift) | Geographic and projected coordinate math | Add Web Mercator (EPSG:3857) projected coordinate conversions (`toMercatorMeters`, `fromMercatorMeters`) and bounding box calculations. |
| [`ElevationService.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Elevation/ElevationService.swift) | USGS 3DEP ImageServer retrieval | Request native square Web Mercator extents (`bboxSR=3857&imageSR=3857`) with matching pixel sizes (`samples x samples`), eliminating 28.6% vertical stretching. |
| [`PrivacyInfo.xcprivacy`](file:///Users/herren/dev/LidarExplorer/Config/PrivacyInfo.xcprivacy) | Apple App Store Privacy Manifest | Declare `NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1` and Google Mobile Ads SDK data disclosures. |
| [`RasterCompute.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Core/Raster/RasterCompute.swift) | Metal GPU pipeline & CPU fallback | Replace blocking `commandBuffer.waitUntilCompleted()` with async continuation (`addCompletedHandler`); add reusable buffer cache for standard tile dimensions. |
| [`TerrainViewerView.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Presentation/TerrainViewerView.swift) | Main viewer screen composition | Sequence the Google UMP consent flow to present after `OnboardingView` sheet dismissal, avoiding UIKit modal collision. |
| [`HTTPTransport.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Transport/HTTPTransport.swift) | Bounded HTTP network transport | Add full randomized jitter to exponential backoff delays to prevent synchronized retry storms. |
| [`HillshadeTileOverlay.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/HillshadeTileOverlay.swift) | Basemap tile overlay | Invalidate previous `URLSession` instances when switching basemaps to prevent resource leaks. |
| [`TileActivityLog.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Presentation/TileActivityLog.swift) | In-app debug log of tile events | Add `.cancelled` outcome case so user gestures are not logged as errors. |
| [`ViewerHarness/main.swift`](file:///Users/herren/dev/LidarExplorer/Tools/ViewerHarness/main.swift) | Host regression test suite | Add unit tests for empty byte count TIFFs, dimension guards, Mercator projections, and grid cropping. |

---

### Task 1: Harden `FloatTIFFDecoder` Against Poison Pills & Unbounded Allocations (Blocker)

**Files:**
- Modify: [`LidarExplorer/Services/Decoding/FloatTIFFDecoder.swift:L170-174`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Decoding/FloatTIFFDecoder.swift#L170-L174), [`FloatTIFFDecoder.swift:L269`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Decoding/FloatTIFFDecoder.swift#L269), [`FloatTIFFDecoder.swift:L317`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Decoding/FloatTIFFDecoder.swift#L317)
- Test: [`Tools/ViewerHarness/main.swift:L157-165`](file:///Users/herren/dev/LidarExplorer/Tools/ViewerHarness/main.swift#L157-L165)

- [x] **Step 1: Write failing tests in `Tools/ViewerHarness/main.swift`**

Add tests for empty `stripByteCounts` and oversized TIFF dimensions to `Tools/ViewerHarness/main.swift`:

```swift
// In Tools/ViewerHarness/main.swift, under "=== TIFF decoding ===":
// Test 1: Empty stripByteCounts must not crash with index out of range ($0[-1])
func makeEmptyByteCountsTIFF() -> Data {
    var out = Data()
    out.append(contentsOf: [0x49, 0x49, 42, 0, 8, 0, 0, 0]) // Header
    var entries: [(UInt16, UInt16, UInt32, UInt32)] = [
        (256, 3, 1, 4), (257, 3, 1, 4), (258, 3, 1, 32), (259, 3, 1, 1),
        (273, 4, 1, 120), (277, 3, 1, 1), (278, 3, 1, 4), (279, 4, 0, 0), // count 0 stripByteCounts!
        (339, 3, 1, 3)
    ]
    entries.sort { $0.0 < $1.0 }
    out.append(UInt8(entries.count & 0xFF)); out.append(UInt8(entries.count >> 8))
    for (t, ty, c, v) in entries {
        out.append(UInt8(t & 0xFF)); out.append(UInt8(t >> 8))
        out.append(UInt8(ty & 0xFF)); out.append(UInt8(ty >> 8))
        out.append(UInt8(c & 0xFF)); out.append(UInt8((c >> 8) & 0xFF)); out.append(UInt8((c >> 16) & 0xFF)); out.append(UInt8(c >> 24))
        out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF)); out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8(v >> 24))
    }
    out.append(contentsOf: [0, 0, 0, 0])
    while out.count < 120 + 64 { out.append(0) }
    return out
}

mustThrow("empty stripByteCounts throws safely without trapping", makeEmptyByteCountsTIFF())

// Test 2: Implausible/huge dimensions (> 4096) must throw unsupported without OOMing
func makeOversizedTIFF() -> Data {
    var out = Data()
    out.append(contentsOf: [0x49, 0x49, 42, 0, 8, 0, 0, 0])
    let entries: [(UInt16, UInt16, UInt32, UInt32)] = [
        (256, 4, 1, 65536), (257, 4, 1, 65536), (258, 3, 1, 32), (259, 3, 1, 1),
        (273, 4, 1, 200), (277, 3, 1, 1), (278, 4, 1, 65536), (279, 4, 1, 100),
        (339, 3, 1, 3)
    ]
    out.append(UInt8(entries.count & 0xFF)); out.append(UInt8(entries.count >> 8))
    for (t, ty, c, v) in entries.sorted(by: { $0.0 < $1.0 }) {
        out.append(UInt8(t & 0xFF)); out.append(UInt8(t >> 8))
        out.append(UInt8(ty & 0xFF)); out.append(UInt8(ty >> 8))
        out.append(UInt8(c & 0xFF)); out.append(UInt8((c >> 8) & 0xFF)); out.append(UInt8((c >> 16) & 0xFF)); out.append(UInt8(c >> 24))
        out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF)); out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8(v >> 24))
    }
    out.append(contentsOf: [0, 0, 0, 0])
    return out
}

mustThrow("oversized dimensions throw unsupported", makeOversizedTIFF())
```

- [x] **Step 2: Run test harness to verify failure**

Run:
```bash
Tools/run-harness.sh
```
Expected: Failure on empty strip byte counts lookup (`Index out of range`), or failure of the new checks.

- [x] **Step 3: Implement defensive checks in `FloatTIFFDecoder.swift`**

In [`FloatTIFFDecoder.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Decoding/FloatTIFFDecoder.swift):
1. Add maximum dimension cap of 4096 px per axis at lines 170-174:
```swift
        guard width > 0, height > 0 else {
            throw DecodeError.unsupported("zero-sized image \(width)x\(height)")
        }
        guard width <= 4096, height <= 4096 else {
            throw DecodeError.unsupported("image dimensions \(width)x\(height) exceed limit of 4096")
        }
```
2. Fix `readStrips` line 269:
```swift
            let expected = rowsInStrip * width * bytesPerSample
            let available = stripByteCounts.flatMap { counts -> Int? in
                guard !counts.isEmpty else { return nil }
                return Int(counts[min(stripIndex, counts.count - 1)])
            } ?? expected
            let length = min(expected, available)
```
3. Fix `readTiles` line 317:
```swift
                let expected = tileWidth * tileHeight * bytesPerSample
                let available = tileByteCounts.flatMap { counts -> Int? in
                    guard !counts.isEmpty else { return nil }
                    return Int(counts[min(index, counts.count - 1)])
                } ?? expected
                let length = min(expected, available)
```

- [x] **Step 4: Run test harness to verify it passes**

Run:
```bash
Tools/run-harness.sh
```
Expected: `PASS empty stripByteCounts throws safely without trapping` and `PASS oversized dimensions throw unsupported`. All tests pass.

- [x] **Step 5: Commit**

```bash
git add LidarExplorer/Services/Decoding/FloatTIFFDecoder.swift Tools/ViewerHarness/main.swift
git commit -m "fix(decoder): harden FloatTIFFDecoder against empty byte counts and oversized dimensions"
```

---

### Task 2: Fix Native Detail Grid Cropping & Elevation Style Buffer Mismatch (Blocker)

**Files:**
- Modify: [`LidarExplorer/Core/Geometry/ElevationGrid.swift:L218`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Core/Geometry/ElevationGrid.swift#L218)
- Modify: [`LidarExplorer/MapLayer/TerrainTileOverlay.swift:L179-186`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/TerrainTileOverlay.swift#L179-L186), [`TerrainTileOverlay.swift:L298-325`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/TerrainTileOverlay.swift#L298-L325), [`TerrainTileOverlay.swift:L381-393`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/TerrainTileOverlay.swift#L381-L393)
- Test: [`Tools/ViewerHarness/main.swift`](file:///Users/herren/dev/LidarExplorer/Tools/ViewerHarness/main.swift)

- [x] **Step 1: Write the failing test in `Tools/ViewerHarness/main.swift`**

Add a test verifying that cropping an `ElevationGrid` and generating an `.elevation` image produces an exact sample-count match with `ReliefRenderer.image`:

```swift
// In Tools/ViewerHarness/main.swift, under "=== Relief rendering ===":
let paddedGrid = makeGrid(width: 520, height: 406, gsd: 1.0)
let croppedGrid = paddedGrid.cropped(margin: 4)
check("cropped grid width reduced by 2*margin", croppedGrid.width == 512, "width=\(croppedGrid.width)")
check("cropped grid height reduced by 2*margin", croppedGrid.height == 398, "height=\(croppedGrid.height)")
check("cropped grid sample count matches w*h", croppedGrid.samples.count == 512 * 398)

let elevationImage = ReliefRenderer.image(
    from: croppedGrid.samples,
    width: croppedGrid.width,
    height: croppedGrid.height,
    style: .elevation
)
check("elevation style renders successfully with cropped grid", elevationImage != nil)
```

- [x] **Step 2: Run test harness to verify it fails**

Run:
```bash
Tools/run-harness.sh
```
Expected: Compilation failure: `value of type 'ElevationGrid' has no member 'cropped'`.

- [x] **Step 3: Implement `cropped(margin:)` on `ElevationGrid`**

In [`LidarExplorer/Core/Geometry/ElevationGrid.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Core/Geometry/ElevationGrid.swift), add:

```swift
    /// Trims a margin skirt from all four sides, adjusting dimensions and geographic region.
    public func cropped(margin: Int) -> ElevationGrid {
        guard margin > 0, width > margin * 2, height > margin * 2 else { return self }
        let newWidth = width - margin * 2
        let newHeight = height - margin * 2

        var newSamples = [Float](repeating: .nan, count: newWidth * newHeight)
        for y in 0..<newHeight {
            let srcOffset = (y + margin) * width + margin
            let dstOffset = y * newWidth
            newSamples.replaceSubrange(
                dstOffset..<(dstOffset + newWidth),
                with: samples[srcOffset..<(srcOffset + newWidth)]
            )
        }

        // Adjust region inwards proportionally.
        let dLat = region.latitudeSpan * Double(margin) / Double(height)
        let dLon = region.longitudeSpan * Double(margin) / Double(width)
        let newRegion = GeoRegion(
            minLatitude: region.minLatitude + dLat,
            maxLatitude: region.maxLatitude - dLat,
            minLongitude: region.minLongitude + dLon,
            maxLongitude: region.maxLongitude - dLon
        )

        return ElevationGrid(
            width: newWidth, height: newHeight,
            samples: newSamples, region: newRegion
        )
    }
```

- [x] **Step 4: Update `TerrainTileOverlay.swift` to store cropped grid**

In [`LidarExplorer/MapLayer/TerrainTileOverlay.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/TerrainTileOverlay.swift), update `loadTile`:

```swift
        if let grid = await elevation
            .elevation(for: expanded, targetSamples: samples).value {
            let products = await raster.reliefProducts(for: grid)
            let croppedGrid = grid.cropped(margin: margin)
            let croppedProducts = Self.crop(products, margin: margin)
            return CachedTile(
                grid: croppedGrid,
                products: croppedProducts,
                source: "3DEP 1m"
            )
        }
```

And in `render(_ tile: CachedTile)`:
```swift
        case .elevation:
            values = tile.grid.samples
            range = ReliefRenderer.robustRange(of: values)
```
Now `tile.grid.samples.count` is guaranteed to be `products.width * products.height`!

- [x] **Step 5: Run test harness to verify it passes**

Run:
```bash
Tools/run-harness.sh
```
Expected: `PASS cropped grid width reduced by 2*margin`, `PASS cropped grid height reduced by 2*margin`, `PASS elevation style renders successfully with cropped grid`.

- [x] **Step 6: Commit**

```bash
git add LidarExplorer/Core/Geometry/ElevationGrid.swift LidarExplorer/MapLayer/TerrainTileOverlay.swift Tools/ViewerHarness/main.swift
git commit -m "fix(tiles): crop ElevationGrid to exact tile bounds resolving elevation style blanking"
```

---

### Task 3: Align 3DEP Elevation Retrieval with Web Mercator (EPSG:3857) (Blocker)

**Files:**
- Modify: [`LidarExplorer/Core/Geometry/GeoRegion.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Core/Geometry/GeoRegion.swift)
- Modify: [`LidarExplorer/Services/Elevation/ElevationService.swift:L119-137`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Elevation/ElevationService.swift#L119-L137), [`ElevationService.swift:L217-227`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Elevation/ElevationService.swift#L217-L227)
- Test: [`Tools/ViewerHarness/main.swift`](file:///Users/herren/dev/LidarExplorer/Tools/ViewerHarness/main.swift)

- [x] **Step 1: Write failing test in `Tools/ViewerHarness/main.swift`**

Add Web Mercator projection conversion tests:

```swift
// In Tools/ViewerHarness/main.swift, under "=== Geometry ===":
let testCoord = CLLocationCoordinate2D(latitude: 38.6605, longitude: -90.0621)
let meters = GeoRegion.toMercatorMeters(testCoord)
let roundTrip = GeoRegion.fromMercatorMeters(x: meters.x, y: meters.y)
check("Mercator round trip latitude exact", abs(roundTrip.latitude - testCoord.latitude) < 1e-6, "\(roundTrip.latitude)")
check("Mercator round trip longitude exact", abs(roundTrip.longitude - testCoord.longitude) < 1e-6, "\(roundTrip.longitude)")

let testRegion = GeoRegion(center: testCoord, latitudeSpan: 0.01, longitudeSpan: 0.01)
let mercBounds = testRegion.mercatorBounds
check("Mercator bounds are square or valid", mercBounds.maxX > mercBounds.minX && mercBounds.maxY > mercBounds.minY)
```

- [x] **Step 2: Run test harness to verify failure**

Run:
```bash
Tools/run-harness.sh
```
Expected: Compilation failure: `type 'GeoRegion' has no member 'toMercatorMeters'`.

- [x] **Step 3: Add Web Mercator conversion methods in `GeoRegion.swift`**

In [`LidarExplorer/Core/Geometry/GeoRegion.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Core/Geometry/GeoRegion.swift):

```swift
    // MARK: - Web Mercator (EPSG:3857) Projection

    public static let maxMercatorLatitude: Double = 85.05112878

    /// Converts WGS-84 coordinate to Web Mercator projected metres (EPSG:3857).
    public static func toMercatorMeters(_ coordinate: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        let clampedLat = min(max(coordinate.latitude, -maxMercatorLatitude), maxMercatorLatitude)
        let r = 6378137.0
        let x = coordinate.longitude * .pi / 180.0 * r
        let latRad = clampedLat * .pi / 180.0
        let y = log(tan(.pi / 4.0 + latRad / 2.0)) * r
        return (x, y)
    }

    /// Converts Web Mercator projected metres (EPSG:3857) to WGS-84 coordinate.
    public static func fromMercatorMeters(x: Double, y: Double) -> CLLocationCoordinate2D {
        let r = 6378137.0
        let lon = (x / r) * 180.0 / .pi
        let lat = (2.0 * atan(exp(y / r)) - .pi / 2.0) * 180.0 / .pi
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Extents in Web Mercator metres (EPSG:3857).
    public var mercatorBounds: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let sw = Self.toMercatorMeters(CLLocationCoordinate2D(latitude: minLatitude, longitude: minLongitude))
        let ne = Self.toMercatorMeters(CLLocationCoordinate2D(latitude: maxLatitude, longitude: maxLongitude))
        return (minX: min(sw.x, ne.x), minY: min(sw.y, ne.y), maxX: max(sw.x, ne.x), maxY: max(sw.y, ne.y))
    }
```

- [x] **Step 4: Update `USGS3DEPService.swift` to request EPSG:3857 square tiles**

In [`LidarExplorer/Services/Elevation/ElevationService.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Elevation/ElevationService.swift):

Update lines 119-137:
```swift
        // Request in Web Mercator (EPSG:3857) so returned tiles are strictly square,
        // matching MKTileOverlay's projection and eliminating vertical stretching.
        let samples = min(max(targetSamples, 16), Self.maxSamplesPerAxis)
        let m = region.mercatorBounds

        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "bbox", value: "\(m.minX),\(m.minY),\(m.maxX),\(m.maxY)"),
            .init(name: "bboxSR", value: "3857"),
            .init(name: "imageSR", value: "3857"),
            .init(name: "size", value: "\(samples),\(samples)"),
            .init(name: "format", value: "tiff"),
            .init(name: "pixelType", value: "F32"),
            .init(name: "noData", value: "\(Int(Self.noDataValue))"),
            .init(name: "noDataInterpretation", value: "esriNoDataMatchAny"),
            .init(name: "interpolation", value: "RSP_BilinearInterpolation"),
            .init(name: "f", value: "image"),
        ]
```

And in `Self.region(of: raster)` (lines 217-227), convert projected meters to `GeoRegion`:
```swift
    private nonisolated static func region(of raster: FloatTIFFDecoder.Raster) -> GeoRegion? {
        guard let transform = raster.geoTransform else { return nil }
        let bounds = transform.bounds(width: raster.width, height: raster.height)
        // If coordinates exceed 180, they are projected metres (EPSG:3857).
        if abs(bounds.minX) > 180 || abs(bounds.maxX) > 180 {
            let sw = GeoRegion.fromMercatorMeters(x: bounds.minX, y: bounds.minY)
            let ne = GeoRegion.fromMercatorMeters(x: bounds.maxX, y: bounds.maxY)
            return GeoRegion(
                minLatitude: sw.latitude, maxLatitude: ne.latitude,
                minLongitude: sw.longitude, maxLongitude: ne.longitude
            )
        }
        guard abs(bounds.minY) <= 90, abs(bounds.maxY) <= 90,
              abs(bounds.minX) <= 180, abs(bounds.maxX) <= 180 else { return nil }
        return GeoRegion(
            minLatitude: bounds.minY, maxLatitude: bounds.maxY,
            minLongitude: bounds.minX, maxLongitude: bounds.maxX
        )
    }
```

- [x] **Step 5: Run test harness to verify it passes**

Run:
```bash
Tools/run-harness.sh
```
Expected: `PASS Mercator round trip latitude exact`, `PASS Mercator round trip longitude exact`, `PASS Mercator bounds are square or valid`. All checks pass.

- [x] **Step 6: Commit**

```bash
git add LidarExplorer/Core/Geometry/GeoRegion.swift LidarExplorer/Services/Elevation/ElevationService.swift Tools/ViewerHarness/main.swift
git commit -m "fix(elevation): query 3DEP in square Web Mercator (EPSG:3857) extents"
```

---

### Task 4: Populate Apple Privacy Manifest (`PrivacyInfo.xcprivacy`) (Blocker)

**Files:**
- Modify: [`Config/PrivacyInfo.xcprivacy`](file:///Users/herren/dev/LidarExplorer/Config/PrivacyInfo.xcprivacy)

- [x] **Step 1: Check current validity of `Config/PrivacyInfo.xcprivacy`**

Run:
```bash
plutil -lint Config/PrivacyInfo.xcprivacy
```
Expected: `Config/PrivacyInfo.xcprivacy: OK`

- [x] **Step 2: Add Required Reason API and Advertising Disclosures**

Update [`Config/PrivacyInfo.xcprivacy`](file:///Users/herren/dev/LidarExplorer/Config/PrivacyInfo.xcprivacy) with the mandatory `NSPrivacyAccessedAPICategoryUserDefaults` reason `CA92.1` for `@AppStorage`, and declare non-tracking diagnostics for Google Mobile Ads SDK:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyTrackingDomains</key>
	<array/>
	<key>NSPrivacyCollectedDataTypes</key>
	<array>
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeDeviceID</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<false/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
	</array>
	<key>NSPrivacyAccessedAPITypes</key>
	<array>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryUserDefaults</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>CA92.1</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
```

- [x] **Step 3: Validate plist syntax**

Run:
```bash
plutil -lint Config/PrivacyInfo.xcprivacy
```
Expected: `Config/PrivacyInfo.xcprivacy: OK`

- [x] **Step 4: Commit**

```bash
git add Config/PrivacyInfo.xcprivacy
git commit -m "fix(privacy): declare UserDefaults reason CA92.1 and AdMob diagnostics in PrivacyInfo.xcprivacy"
```

---

### Task 5: Implement Singleflight Request Coalescing & LRU Cache Promotion (Major)

**Files:**
- Modify: [`LidarExplorer/MapLayer/TerrainTileOverlay.swift:L56-74`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/TerrainTileOverlay.swift#L56-L74), [`TerrainTileOverlay.swift:L113-130`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/TerrainTileOverlay.swift#L113-L130), [`TerrainTileOverlay.swift:L199-227`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/TerrainTileOverlay.swift#L199-L227), [`TerrainTileOverlay.swift:L405-412`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/TerrainTileOverlay.swift#L405-L412)

- [x] **Step 1: Add in-flight ancestor task map to `TerrainTileProvider`**

In [`LidarExplorer/MapLayer/TerrainTileOverlay.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/TerrainTileOverlay.swift):

Add state property to `TerrainTileProvider`:
```swift
    /// In-flight fetches for ancestor tiles, deduplicating simultaneous child requests.
    private var inFlightAncestors: [String: Task<ElevationGrid?, Never>] = [:]
```

Update `loadTerrariumTile`:
```swift
    private func loadTerrariumTile(
        x: Int, y: Int, z: Int, region: GeoRegion, margin: Int, source: String
    ) async -> CachedTile? {
        let sourceZ = min(z, TerrariumTileService.maximumZ)
        let scale = 1 << (z - sourceZ)
        let sourceX = x / scale
        let sourceY = y / scale
        let ancestorKey = "\(sourceZ)/\(sourceX)/\(sourceY)"

        let ancestorGrid: ElevationGrid?
        if let existingTask = inFlightAncestors[ancestorKey] {
            ancestorGrid = await existingTask.value
        } else {
            let task = Task<ElevationGrid?, Never> { [terrarium] in
                let sourceRegion = TerrainTileOverlay.region(
                    for: MKTileOverlayPath(x: sourceX, y: sourceY, z: sourceZ, contentScaleFactor: 1)
                )
                return await terrarium.elevation(x: sourceX, y: sourceY, z: sourceZ, region: sourceRegion).value
            }
            inFlightAncestors[ancestorKey] = task
            ancestorGrid = await task.value
            inFlightAncestors.removeValue(forKey: ancestorKey)
        }

        guard let ancestor = ancestorGrid else { return nil }

        let grid = scale == 1 ? ancestor : Self.subgrid(of: ancestor, covering: region)
        guard grid.width >= 4, grid.height >= 4 else { return nil }
        let padded = Self.padByReplication(grid, margin: margin)
        let products = await raster.reliefProducts(for: padded)
        return CachedTile(
            grid: grid,
            products: Self.crop(products, margin: margin),
            source: source
        )
    }
```

- [x] **Step 2: Implement True LRU Eviction in `store(_:for:)` and `tileImageData`**

Update `tileImageData` to promote accessed cache entries:
```swift
        if let hit = cache[key] {
            cached = hit
            wasCached = true
            promote(key)
        } else { ... }
```

Add `promote(_:)` and update `store(_:for:)`:
```swift
    private func promote(_ key: String) {
        if let idx = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: idx)
            cacheOrder.append(key)
        }
    }

    private func store(_ tile: CachedTile, for key: String) {
        if let idx = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: idx)
        }
        cacheOrder.append(key)
        cache[key] = tile
        while cacheOrder.count > cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
```

- [x] **Step 3: Test compilation and verify harness**

Run:
```bash
Tools/run-harness.sh
```
Expected: `ALL CHECKS PASSED`.

- [x] **Step 4: Commit**

```bash
git add LidarExplorer/MapLayer/TerrainTileOverlay.swift
git commit -m "perf(tiles): add singleflight ancestor deduplication and true LRU cache promotion"
```

---

### Task 6: Non-Blocking Metal Execution & Buffer Pooling in `RasterCompute` (Major)

**Files:**
- Modify: [`LidarExplorer/Core/Raster/RasterCompute.swift:L67-73`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Core/Raster/RasterCompute.swift#L67-L73), [`RasterCompute.swift:L212-225`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Core/Raster/RasterCompute.swift#L212-L225), [`RasterCompute.swift:L263-267`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Core/Raster/RasterCompute.swift#L263-L267)
- Test: [`Tools/ViewerHarness/main.swift`](file:///Users/herren/dev/LidarExplorer/Tools/ViewerHarness/main.swift)

- [x] **Step 1: Replace synchronous GPU wait with async continuation in `RasterCompute.swift`**

In [`LidarExplorer/Core/Raster/RasterCompute.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Core/Raster/RasterCompute.swift):

Add asynchronous command buffer submission:
```swift
        let status = await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { cb in
                continuation.resume(returning: cb.error)
            }
            commandBuffer.commit()
        }

        if let error = status {
            Log.shader.error("Terrain command buffer failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
```

- [x] **Step 2: Implement reusable buffer pool for standard tile dimensions**

In `RasterCompute`:
```swift
    private struct PooledBuffers {
        let elevation: any MTLBuffer
        let slope: any MTLBuffer
        let aspect: any MTLBuffer
        let relief: any MTLBuffer
        let byteCount: Int
    }

    private var bufferPool: [Int: PooledBuffers] = [:]

    private func obtainBuffers(device: any MTLDevice, byteCount: Int) -> PooledBuffers? {
        if let existing = bufferPool[byteCount] {
            return existing
        }
        let options: MTLResourceOptions = .storageModeShared
        guard
            let elevation = device.makeBuffer(length: byteCount, options: options),
            let slope = device.makeBuffer(length: byteCount, options: options),
            let aspect = device.makeBuffer(length: byteCount, options: options),
            let relief = device.makeBuffer(length: byteCount, options: options)
        else { return nil }

        let pooled = PooledBuffers(
            elevation: elevation, slope: slope,
            aspect: aspect, relief: relief, byteCount: byteCount
        )
        // Keep up to 4 size classes (e.g., 256x256, 512x512, padded variants)
        if bufferPool.count < 4 {
            bufferPool[byteCount] = pooled
        }
        return pooled
    }
```

In `gpuReliefProducts`:
```swift
        guard let buffers = obtainBuffers(device: device, byteCount: byteCount),
              let commandBuffer = queue.makeCommandBuffer()
        else {
            Log.shader.error("Metal buffer allocation failed for \(count) cells; using CPU.")
            return nil
        }

        // Copy input samples into reusable elevation buffer
        grid.samples.withUnsafeBytes { bytes in
            buffers.elevation.contents().copyMemory(from: bytes.baseAddress!, byteCount: byteCount)
        }

        let elevationBuffer = buffers.elevation
        let slopeBuffer = buffers.slope
        let aspectBuffer = buffers.aspect
        let reliefBuffer = buffers.relief
```

- [x] **Step 3: Run harness to test GPU/CPU agreement and verify asynchronous execution**

Run:
```bash
Tools/run-harness.sh
```
Expected: `PASS GPU and CPU slope agree to 0.01°`. `ALL CHECKS PASSED`.

- [x] **Step 4: Commit**

```bash
git add LidarExplorer/Core/Raster/RasterCompute.swift
git commit -m "perf(raster): make Metal dispatch non-blocking and reuse pooled buffers"
```

---

### Task 7: Sequence First-Launch Modal Flows in `TerrainViewerView` (Major)

**Files:**
- Modify: [`LidarExplorer/Presentation/TerrainViewerView.swift:L43-52`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Presentation/TerrainViewerView.swift#L43-L52), [`TerrainViewerView.swift:L41`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Presentation/TerrainViewerView.swift#L41)

- [x] **Step 1: Coordinate Onboarding Dismissal with Consent Gathering**

In [`LidarExplorer/Presentation/TerrainViewerView.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Presentation/TerrainViewerView.swift):

Update lines 41-52 so `ads.prepare()` waits until the first-run onboarding sheet has been dismissed:

```swift
            .sheet(isPresented: $showsIntro, onDismiss: {
                Task {
                    await ads.prepare(hasRemoveAds: store.hasRemoveAds)
                }
            }) { OnboardingView() }
            .sheet(isPresented: $showsDebug) { TileDebugView(log: model.tileLog) }
            .task {
                model.start()
                await store.refresh()
                if !hasSeenIntro {
                    hasSeenIntro = true
                    showsIntro = true
                } else {
                    await ads.prepare(hasRemoveAds: store.hasRemoveAds)
                }
            }
```

- [x] **Step 2: Verify compilation and syntax**

Run:
```bash
Tools/run-harness.sh
```
Expected: `ALL CHECKS PASSED`.

- [x] **Step 3: Commit**

```bash
git add LidarExplorer/Presentation/TerrainViewerView.swift
git commit -m "fix(ui): sequence onboarding sheet and UMP consent form to prevent presentation collision"
```

---

### Task 8: Resilient Transport, URLSession Lifecycles & Diagnostic Categorization (Minor/Nits)

**Files:**
- Modify: [`LidarExplorer/Services/Transport/HTTPTransport.swift:L120-123`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Transport/HTTPTransport.swift#L120-L123)
- Modify: [`LidarExplorer/MapLayer/HillshadeTileOverlay.swift:L79-99`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/HillshadeTileOverlay.swift#L79-99)
- Modify: [`LidarExplorer/Presentation/TileActivityLog.swift:L16-21`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Presentation/TileActivityLog.swift#L16-L21)
- Modify: [`LidarExplorer/MapLayer/TerrainTileOverlay.swift:L120-125`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/TerrainTileOverlay.swift#L120-L125)

- [x] **Step 1: Add randomized full jitter to `HTTPTransport.swift`**

In [`LidarExplorer/Services/Transport/HTTPTransport.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Transport/HTTPTransport.swift) line 120:

```swift
            // Truncated exponential backoff with full jitter to avoid synchronized stampedes.
            let maxBackoffSeconds = min(0.5 * pow(2.0, Double(attempt - 1)), 8.0)
            let jitteredSeconds = Double.random(in: 0.1...maxBackoffSeconds)
            let backoffNanoseconds = UInt64(jitteredSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: backoffNanoseconds)
```

- [x] **Step 2: Manage `URLSession` cleanup on `HillshadeTileOverlay`**

In [`LidarExplorer/MapLayer/HillshadeTileOverlay.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/HillshadeTileOverlay.swift), make `URLSession` shared across instances or add an explicit invalidation method:

```swift
    public func invalidate() {
        session.finishTasksAndInvalidate()
    }
```

In [`TerrainMapView.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/TerrainMapView.swift):
```swift
        func applyBasemap(_ basemap: TerrainBasemap, to map: MKMapView) {
            if let existing = basemapOverlay {
                map.removeOverlay(existing)
                existing.invalidate()
            }
            let overlay = HillshadeTileOverlay(basemap: basemap)
            map.insertOverlay(overlay, at: 0, level: .aboveRoads)
            basemapOverlay = overlay
            self.basemap = basemap
            basemapAlpha = -1
        }
```

- [x] **Step 3: Add `.cancelled` to `TileEvent.Outcome`**

In [`TileActivityLog.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Presentation/TileActivityLog.swift):
```swift
    public enum Outcome: String, Sendable {
        case fetched      // came off the network
        case cached       // already had the derivatives
        case cancelled    // superseded by map pan/zoom
        case failed       // no data or error
    }
```

In [`TerrainTileOverlay.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/TerrainTileOverlay.swift):
Update error handling in `loadTile` to report `.cancelled` when task is cancelled, preventing false failure statistics.

- [x] **Step 4: Run harness to verify clean build**

Run:
```bash
Tools/run-harness.sh
```
Expected: `ALL CHECKS PASSED`.

- [x] **Step 5: Commit**

```bash
git add LidarExplorer/Services/Transport/HTTPTransport.swift LidarExplorer/MapLayer/HillshadeTileOverlay.swift LidarExplorer/MapLayer/TerrainMapView.swift LidarExplorer/Presentation/TileActivityLog.swift LidarExplorer/MapLayer/TerrainTileOverlay.swift
git commit -m "fix(transport): add jitter to retries, invalidate basemap sessions, and record cancellations"
```

---

### Task 9: End-to-End Verification via Expanded Regression Harness and Live Checks

**Files:**
- Test: `Tools/run-harness.sh`
- Test: `Tools/run-live-check.sh`

- [x] **Step 1: Execute complete host regression harness**

Run:
```bash
Tools/run-harness.sh
```
Expected:
```
=== Geometry ===
  PASS  gsd x ~2m
  ...
  PASS  Mercator round trip latitude exact
  PASS  Mercator round trip longitude exact
=== Terrain derivatives ===
  ...
=== TIFF decoding ===
  ...
  PASS  empty stripByteCounts throws safely without trapping
  PASS  oversized dimensions throw unsupported
=== Relief rendering ===
  ...
  PASS  cropped grid width reduced by 2*margin
  PASS  elevation style renders successfully with cropped grid
=== GPU / CPU agreement ===
  PASS  GPU and CPU slope agree to 0.01°
====================================================
ALL CHECKS PASSED
====================================================
```

- [x] **Step 2: Execute live check with tiered tile streaming**

Run:
```bash
Tools/run-live-check.sh
```
Expected:
```
=== Tile geometry ===
  PASS  z10 tile contains its own coordinate
  ...
=== Tiered tile streaming (live) ===
  PASS  z11 tile renders
  PASS  z13 tile renders
  PASS  z15 tile renders
  PASS  z16 tile renders
  PASS  z18 tile renders
  PASS  detail improves monotonically with zoom
  PASS  deepest tier reaches native resolution (< 1.5 m)
=== Relighting uses the cache ===
  PASS  relight produces an image
=== Elevation readout from tiles ===
  PASS  elevation available from cached tiles
====================================================
ALL CHECKS PASSED
====================================================
```

- [x] **Step 3: Check git status and diff**

Run:
```bash
git status
```
Expected: Clean working tree, all changes committed on branch.
