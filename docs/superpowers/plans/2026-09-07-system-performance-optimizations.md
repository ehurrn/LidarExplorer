# Systems Engineering & Performance Optimizations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the 6 architectural performance optimizations identified in the Apple systems engineering audit: pure Swift 6 concurrency safety in `HillshadeTileOverlay`, explicit `autoreleasepool` scoping across CoreGraphics/ImageIO codecs, SwiftUI view invalidation isolation in `TerrainViewerView`, SIMD/`__sincosf` math acceleration in `TerrainDerivatives`, zero-copy preallocated strip ingestion in `FloatTIFFDecoder`, and bounded LRU disk caching for `USGS3DEPService`.

**Architecture:** Resolve concurrency diagnostics structurally rather than with escape hatches (`@unchecked Sendable`); eliminate transient heap memory accumulation during rapid tile streaming by bounding Objective-C autorelease lifecycles; isolate reactive `@Observable` state reads to prevent 120Hz ProMotion view invalidation cascades onto `MKMapView`; accelerate transcendental math pipelines using hardware-fused trigonometric instructions; eliminate repeated buffer allocation in TIFF decoding; and enforce a strict 128 MB high-watermark LRU eviction policy for persistent raster storage.

**Tech Stack:** Swift 6.0 (Strict Concurrency), MapKit (`MKTileOverlay`, `MKMapView`), Metal, Accelerate / Darwin `__sincosf`, CoreGraphics / ImageIO, SwiftUI (Observation framework).

---

## File Structure & Responsibilities

| File | Primary Responsibility | Changes in this Plan |
| :--- | :--- | :--- |
| [`HillshadeTileOverlay.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/HillshadeTileOverlay.swift) | Basemap tile overlay & ancestor overzoom | Remove `@unchecked Sendable`; pass sendable primitives to background task; wrap `subTile` in `autoreleasepool`. |
| [`TerrainTileOverlay.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/TerrainTileOverlay.swift) | Terrain shading overlay & tile cache | Wrap `renderPNG` and `pngData` in `autoreleasepool` to immediately release CoreGraphics destination buffers. |
| [`TerrariumTileService.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Elevation/TerrariumTileService.swift) | AWS Terrain Tile decode pipeline | Wrap `decode` in `autoreleasepool` to eliminate transient `CGImageSource` and `CGContext` heap leaks. |
| [`TerrainViewerView.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Presentation/TerrainViewerView.swift) | Main UI composition & controls | Extract `TerrainControlPanelView` and `ElevationReadoutCapsule` into dedicated subviews to prevent 120Hz slider redraw cascades on `TerrainMapView`. |
| [`TerrainDerivatives.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Core/Raster/TerrainDerivatives.swift) | CPU terrain derivatives & hillshading | Factor light azimuth constants outside the cell loop; evaluate $(\sin, \cos)$ pairs with Apple Silicon `__sincosf` hardware instructions. |
| [`FloatTIFFDecoder.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Decoding/FloatTIFFDecoder.swift) | GeoTIFF raster decoder | Pre-allocate destination buffer with `unsafeUninitializedCapacity` and borrow source byte buffer once outside the strip loop. |
| [`ElevationService.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Elevation/ElevationService.swift) | USGS 3DEP retrieval & disk cache | Implement an out-of-band LRU cache pruning pass with a 128 MB quota to prevent unbounded disk accumulation. |

---

### Task 1: Swift 6 Concurrency Safety in `HillshadeTileOverlay`

**Files:**
- Modify: [`LidarExplorer/MapLayer/HillshadeTileOverlay.swift:L80-L190`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/HillshadeTileOverlay.swift#L80-L190)

- [x] **Step 1: Refactor ancestor fetch task closure and remove `@unchecked Sendable`**

In `LidarExplorer/MapLayer/HillshadeTileOverlay.swift`:
1. Change class declaration from `public nonisolated final class HillshadeTileOverlay: MKTileOverlay, @unchecked Sendable` to `public nonisolated final class HillshadeTileOverlay: MKTileOverlay`.
2. In `loadTile(at:)`, compute `tileUrl` outside the task.
3. Capture only Sendable primitives (`[session, inFlightLock]`) inside `newTask`.
4. Populate `ancestorImageCache.setObject(ancestorImage, forKey: keyString as NSString)` on the caller thread after awaiting `task.value`.

```swift
// In LidarExplorer/MapLayer/HillshadeTileOverlay.swift:
public nonisolated final class HillshadeTileOverlay: MKTileOverlay {
    ...
    // In loadTile(at:):
        let keyString = "\(deepest)/\(ancestorX)/\(ancestorY)"

        let ancestorImage: CGImage
        if let cached = ancestorImageCache.object(forKey: keyString as NSString) {
            ancestorImage = cached
        } else {
            let task: Task<CGImage, any Error> = inFlightLock.withLock { inFlight in
                if let existing = inFlight[keyString] {
                    return existing
                }
                let inFlightLock = self.inFlightLock
                let ancestorPath = MKTileOverlayPath(
                    x: ancestorX,
                    y: ancestorY,
                    z: deepest,
                    contentScaleFactor: 1
                )
                let tileUrl = self.url(forTilePath: ancestorPath)
                let newTask = Task<CGImage, any Error> { [session, inFlightLock] in
                    defer {
                        inFlightLock.withLock { _ = $0.removeValue(forKey: keyString) }
                    }
                    let (ancestorData, response) = try await session.data(
                        for: URLRequest(url: tileUrl)
                    )
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                          !ancestorData.isEmpty,
                          let source = CGImageSourceCreateWithData(ancestorData as CFData, nil),
                          let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
                    else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    return decoded
                }
                inFlight[keyString] = newTask
                return newTask
            }
            ancestorImage = try await task.value
            ancestorImageCache.setObject(ancestorImage, forKey: keyString as NSString)
        }
```

- [x] **Step 2: Verify compilation and tests**

Run: `./Tools/run-live-check.sh`  
Expected: All checks pass; clean compile under `-strict-concurrency=complete`.

- [x] **Step 3: Commit**

```bash
git commit -am "refactor: eliminate @unchecked Sendable in HillshadeTileOverlay"
```

---

### Task 2: Autorelease Pool Scoping for CoreGraphics/ImageIO Codecs

**Files:**
- Modify: [`LidarExplorer/MapLayer/TerrainTileOverlay.swift:L531-L550`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/TerrainTileOverlay.swift#L531-L550)
- Modify: [`LidarExplorer/MapLayer/HillshadeTileOverlay.swift:L205-L256`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/MapLayer/HillshadeTileOverlay.swift#L205-L256)
- Modify: [`LidarExplorer/Services/Elevation/TerrariumTileService.swift:L94-L130`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Elevation/TerrariumTileService.swift#L94-L130)

- [x] **Step 1: Enclose `renderPNG` and `pngData` in `autoreleasepool`**

In `LidarExplorer/MapLayer/TerrainTileOverlay.swift`:
```swift
    private nonisolated static func renderPNG(
        products: ReliefProducts,
        samples: [Float],
        settings: TerrainStyleSettings
    ) -> Data? {
        autoreleasepool {
            guard let image = render(products: products, samples: samples, settings: settings) else {
                return nil
            }
            return pngData(from: image)
        }
    }

    private nonisolated static func pngData(from image: CGImage) -> Data? {
        autoreleasepool {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil
            ) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data as Data
        }
    }
```

- [x] **Step 2: Enclose `subTile` in `autoreleasepool`**

In `LidarExplorer/MapLayer/HillshadeTileOverlay.swift`:
```swift
    nonisolated static func subTile(
        from fullImage: CGImage,
        subX: Int,
        subY: Int,
        scale: Int,
        targetPixels: Int
    ) -> Data? {
        autoreleasepool {
            let width = fullImage.width
            let height = fullImage.height
            guard width > 0, height > 0, scale > 0 else { return nil }

            let tileW = CGFloat(width) / CGFloat(scale)
            let tileH = CGFloat(height) / CGFloat(scale)
            let cropRect = CGRect(
                x: CGFloat(subX) * tileW,
                y: CGFloat(subY) * tileH,
                width: tileW,
                height: tileH
            )

            guard let cropped = fullImage.cropping(to: cropRect) else { return nil }

            let outSize = max(targetPixels, 256)
            let colorSpace = fullImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

            guard let ctx = CGContext(
                data: nil,
                width: outSize,
                height: outSize,
                bitsPerComponent: 8,
                bytesPerRow: outSize * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return nil }

            ctx.interpolationQuality = .medium
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outSize, height: outSize))
            guard let scaledImage = ctx.makeImage() else { return nil }

            let destData = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(
                destData,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else { return nil }

            CGImageDestinationAddImage(dest, scaledImage, nil)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return destData as Data
        }
    }
```

- [x] **Step 3: Enclose `TerrariumTileService.decode` in `autoreleasepool`**

In `LidarExplorer/Services/Elevation/TerrariumTileService.swift`:
```swift
    nonisolated static func decode(_ data: Data, region: GeoRegion) -> ElevationGrid? {
        autoreleasepool {
            guard
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }

            let width = image.width
            let height = image.height
            guard width > 0, height > 0 else { return nil }

            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let ok: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress,
                    width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard ok else { return nil }

            let count = width * height
            let samples = [Float](unsafeUninitializedCapacity: count) { sampleBuffer, initializedCount in
                pixels.withUnsafeBufferPointer { pixelBuffer in
                    guard let pixBase = pixelBuffer.baseAddress,
                          let sampleBase = sampleBuffer.baseAddress else { return }
                    for i in 0..<count {
                        let o = i * 4
                        let r = Float(pixBase[o])
                        let g = Float(pixBase[o + 1])
                        let b = Float(pixBase[o + 2])
                        sampleBase[i] = (r * 256.0 + g + b * (1.0 / 256.0)) - 32768.0
                    }
                }
                initializedCount = count
            }

            return ElevationGrid(
                width: width, height: height, samples: samples, region: region
            )
        }
    }
```

- [x] **Step 4: Verify test suites**

Run: `./Tools/run-harness.sh && ./Tools/run-live-check.sh`  
Expected: ALL CHECKS PASSED.

- [x] **Step 5: Commit**

```bash
git commit -am "perf: wrap CoreGraphics and ImageIO codecs in explicit autorelease pools"
```

---

### Task 3: SwiftUI View Invalidation Isolation in `TerrainViewerView`

**Files:**
- Modify: [`LidarExplorer/Presentation/TerrainViewerView.swift`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Presentation/TerrainViewerView.swift)

- [x] **Step 1: Extract `TerrainControlPanelView` and `ElevationReadoutCapsule` into dedicated `View` structs**

In `LidarExplorer/Presentation/TerrainViewerView.swift`:
1. Keep `TerrainViewerView` focused on the container, overlay placement, sheets, and ad slot.
2. Define `struct TerrainControlPanelView: View` taking `@Bindable var model: TerrainViewerModel`, `@Bindable var store: StoreService`, `@Bindable var ads: AdService`, `@Binding var showsPrimer: Bool`, `@Binding var showsDebug: Bool`.
3. Define `struct ElevationReadoutCapsule: View` taking `@Bindable var model: TerrainViewerModel`.
4. In `TerrainViewerView.body`, replace inlined properties with the new component structs.

```swift
// In TerrainViewerView.swift:

public struct TerrainViewerView: View {
    @State private var model = TerrainViewerModel()
    @State private var store = StoreService()
    @State private var ads = AdService()
    @State private var showsPrimer = false
    @State private var showsDebug = false
    @State private var showsPanel = true
    @AppStorage("hasSeenTerrainIntro") private var hasSeenIntro = false

    public init() {}

    public var body: some View {
        TerrainMapView(
            model: model,
            basemap: model.basemap,
            showsTerrain: model.showsTerrain,
            basemapOpacity: model.basemapOpacity,
            terrainOpacity: model.terrainOpacity,
            reloadToken: model.terrainVersion,
            locationAuthorization: model.locationAuthorization,
            pendingRecenter: model.pendingRecenter
        )
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) { panelToggle }
        .overlay(alignment: .topTrailing) {
            if showsPanel {
                TerrainControlPanelView(
                    model: model,
                    store: store,
                    ads: ads,
                    showsPrimer: $showsPrimer,
                    showsDebug: $showsDebug
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomLeading) {
            ElevationReadoutCapsule(model: model)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BannerAdSlot(isActive: ads.canShowAds && !store.hasRemoveAds)
        }
        .animation(.snappy, value: showsPanel)
        .sheet(isPresented: $showsPrimer, onDismiss: {
            Task { await ads.prepare(hasRemoveAds: store.hasRemoveAds) }
        }) {
            VisualPrimerView()
        }
        .sheet(isPresented: $showsDebug) {
            TileDebugView(log: model.tileLog)
        }
        .onChange(of: store.hasRemoveAds) { _, hasRemove in
            Task { await ads.prepare(hasRemoveAds: hasRemove) }
        }
        .task {
            model.start()
            await store.refresh()
            if !hasSeenIntro {
                hasSeenIntro = true
                showsPrimer = true
            } else {
                await ads.prepare(hasRemoveAds: store.hasRemoveAds)
            }
        }
    }

    private var panelToggle: some View {
        Button {
            showsPanel.toggle()
        } label: {
            Image(systemName: showsPanel ? "sidebar.trailing" : "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
                .frame(width: 40, height: 40)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
        .padding()
    }
}

private struct TerrainControlPanelView: View {
    @Bindable var model: TerrainViewerModel
    @Bindable var store: StoreService
    @Bindable var ads: AdService
    @Binding var showsPrimer: Bool
    @Binding var showsDebug: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                basemapSection
                Divider()
                terrainSection
                Divider()
                unitsSection
                actionsSection
                if let resolution = model.currentResolution {
                    detailRow(resolution)
                }
                Divider()
                supportSection
                attribution
            }
            .padding(16)
        }
        .frame(width: 300)
        .frame(maxHeight: 680)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .padding()
    }
    // header, basemapSection, terrainSection, unitsSection, etc...
}

private struct ElevationReadoutCapsule: View {
    @Bindable var model: TerrainViewerModel

    var body: some View {
        if let text = readoutText {
            HStack(spacing: 8) {
                if case .loading = model.inspectionState {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "mountain.2.fill").font(.caption2).foregroundStyle(.tint)
                }
                Text(text).font(.callout.monospacedDigit())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .padding()
        }
    }

    private var readoutText: String? {
        switch model.inspectionState {
        case .idle: nil
        case .loading: "Reading ground…"
        case .elevation(let e, _): model.formattedElevation(e)
        case .noCoverage: "No coverage here"
        case .failed: "Elevation unavailable"
        }
    }
}
```

- [x] **Step 2: Build Xcode scheme to verify view compilation**

Run: `xcodebuild -scheme LidarExplorer -destination "platform=iOS Simulator,name=iPhone 17 Pro" build`  
Expected: BUILD SUCCEEDED.

- [x] **Step 3: Commit**

```bash
git commit -am "perf: isolate SwiftUI control panel subviews to prevent map invalidation cascades"
```

---

### Task 4: Hardware `__sincosf` & Vectorized Trigonometry in `TerrainDerivatives`

**Files:**
- Modify: [`LidarExplorer/Core/Raster/TerrainDerivatives.swift:L126-L170`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Core/Raster/TerrainDerivatives.swift#L126-L170)

- [x] **Step 1: Factor out light azimuth constants and evaluate angles with `__sincosf`**

In `LidarExplorer/Core/Raster/TerrainDerivatives.swift`:
1. Calculate `cosLightAzimuth = cos(lightAzimuth)` and `sinLightAzimuth = sin(lightAzimuth)` outside the loop.
2. In the per-pixel loop, replace independent `cos(slope)`, `sin(slope)`, and `cos(lightAzimuth - aspect)` calls with hardware-paired `__sincosf` evaluations and trigonometric angle addition.

```swift
    public static func hillshade(
        _ derivatives: TerrainDerivatives,
        azimuthDegrees: Double = 315,
        altitudeDegrees: Double = 45
    ) -> [Float] {
        let zenith = Float((90 - altitudeDegrees) * .pi / 180)
        let lightAzimuth = Float(
            azimuthDegrees.truncatingRemainder(dividingBy: 360) * .pi / 180
        )
        let cosZenith = cos(zenith)
        let sinZenith = sin(zenith)
        let cosLightAzimuth = cos(lightAzimuth)
        let sinLightAzimuth = sin(lightAzimuth)
        let degToRad: Float = .pi / 180
        let count = derivatives.slopeDegrees.count
        guard count > 0 else { return [] }

        return [Float](unsafeUninitializedCapacity: count) { outBuf, initializedCount in
            let outPtr = outBuf.baseAddress!
            derivatives.slopeDegrees.withUnsafeBufferPointer { sBuf in
                derivatives.aspectDegrees.withUnsafeBufferPointer { aBuf in
                    let sPtr = sBuf.baseAddress!, aPtr = aBuf.baseAddress!
                    for i in 0..<count {
                        let slopeDeg = sPtr[i]
                        let aspectDeg = aPtr[i]
                        if slopeDeg.isNaN || aspectDeg.isNaN { outPtr[i] = .nan; continue }
                        let slope = slopeDeg * degToRad
                        let aspect = aspectDeg * degToRad

                        var sinSlope: Float = 0
                        var cosSlope: Float = 0
                        __sincosf(slope, &sinSlope, &cosSlope)

                        var sinAspect: Float = 0
                        var cosAspect: Float = 0
                        __sincosf(aspect, &sinAspect, &cosAspect)

                        // cos(lightAzimuth - aspect) = cos(lightAzimuth)*cos(aspect) + sin(lightAzimuth)*sin(aspect)
                        let cosAspectDiff = cosLightAzimuth * cosAspect + sinLightAzimuth * sinAspect
                        let value = cosZenith * cosSlope + sinZenith * sinSlope * cosAspectDiff
                        outPtr[i] = max(0, min(1, value))
                    }
                }
            }
            initializedCount = count
        }
    }
```

- [x] **Step 2: Run test harness to ensure mathematical accuracy and GPU agreement**

Run: `./Tools/run-harness.sh`  
Expected: 
`PASS  GPU and CPU slope agree to 0.01°`  
`PASS  hillshade within 0...1`  
`ALL CHECKS PASSED`.

- [x] **Step 3: Commit**

```bash
git commit -am "perf: vectorize hillshading with __sincosf and trigonometric factoring"
```

---

### Task 5: Zero-Copy Preallocated Strip Ingestion in `FloatTIFFDecoder`

**Files:**
- Modify: [`LidarExplorer/Services/Decoding/FloatTIFFDecoder.swift:L254-L303`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Decoding/FloatTIFFDecoder.swift#L254-L303)

- [x] **Step 1: Refactor `readStrips` to pre-allocate capacity and hoist buffer locks**

In `LidarExplorer/Services/Decoding/FloatTIFFDecoder.swift`:
Replace per-strip `samples.append(contentsOf: repeatElement(...))` and inner `withUnsafeMutableBufferPointer` / `withUnsafeBytes` calls with a single outer allocation and buffer pointer binding:

```swift
    private static func readStrips(
        reader: ByteReader, byteCount: Int,
        width: Int, height: Int, rowsPerStrip: Int,
        stripOffsets: [UInt32], stripByteCounts: [UInt32]?,
        bytesPerSample: Int, sampleFormat: UInt32
    ) throws -> [Float] {
        if let counts = stripByteCounts, counts.isEmpty {
            throw DecodeError.truncated("empty stripByteCounts")
        }

        let isNativeFloat32 = bytesPerSample == 4 && sampleFormat == 3 && reader.littleEndian
        if isNativeFloat32 {
            return try [Float](unsafeUninitializedCapacity: width * height) { dstBuf, initializedCount in
                guard let dstBase = dstBuf.baseAddress else { return }
                try reader.bytes.withUnsafeBytes { srcRaw in
                    guard let srcBase = srcRaw.baseAddress else { return }
                    var written = 0
                    for (stripIndex, offset32) in stripOffsets.enumerated() {
                        let offset = Int(offset32)
                        let rowsInStrip = min(rowsPerStrip, height - stripIndex * rowsPerStrip)
                        guard rowsInStrip > 0 else { break }

                        let expected = rowsInStrip * width * bytesPerSample
                        let available = stripByteCounts.map { Int($0[min(stripIndex, $0.count - 1)]) } ?? expected
                        let length = min(expected, available)

                        guard offset >= 0, offset + length <= byteCount else {
                            throw DecodeError.truncated(
                                "strip \(stripIndex) wants bytes \(offset)..<\(offset + length) of \(byteCount)"
                            )
                        }
                        let sampleCount = length / 4
                        let dstRaw = UnsafeMutableRawPointer(dstBase.advanced(by: written))
                        let srcPtr = srcBase.advanced(by: reader.bytes.startIndex + offset)
                        dstRaw.copyMemory(from: srcPtr, byteCount: sampleCount * 4)
                        written += sampleCount
                    }
                    initializedCount = written
                }
            }
        } else {
            var samples = [Float]()
            samples.reserveCapacity(width * height)
            for (stripIndex, offset32) in stripOffsets.enumerated() {
                let offset = Int(offset32)
                let rowsInStrip = min(rowsPerStrip, height - stripIndex * rowsPerStrip)
                guard rowsInStrip > 0 else { break }

                let expected = rowsInStrip * width * bytesPerSample
                let available = stripByteCounts.map { Int($0[min(stripIndex, $0.count - 1)]) } ?? expected
                let length = min(expected, available)

                guard offset >= 0, offset + length <= byteCount else {
                    throw DecodeError.truncated(
                        "strip \(stripIndex) wants bytes \(offset)..<\(offset + length) of \(byteCount)"
                    )
                }
                for s in 0..<(length / bytesPerSample) {
                    samples.append(try reader.sample(
                        at: offset + s * bytesPerSample,
                        bytesPerSample: bytesPerSample, sampleFormat: sampleFormat
                    ))
                }
            }
            return samples
        }
    }
```

- [x] **Step 2: Run TIFF unit tests in harness**

Run: `./Tools/run-harness.sh`  
Expected: All tests under `=== TIFF decoding ===` pass.

- [x] **Step 3: Commit**

```bash
git commit -am "perf: preallocate TIFF strip buffer and hoist pointer locks"
```

---

### Task 6: Bounded LRU Disk Cache with Quota Eviction for USGS 3DEP

**Files:**
- Modify: [`LidarExplorer/Services/Elevation/ElevationService.swift:L82-L95, L184-L190`](file:///Users/herren/dev/LidarExplorer/LidarExplorer/Services/Elevation/ElevationService.swift#L82-L95)

- [x] **Step 1: Implement `pruneDiskCacheIfNeeded()` with 128 MB quota**

In `LidarExplorer/Services/Elevation/ElevationService.swift`:
1. Add `private static let maxDiskCacheBytes: Int64 = 128 * 1024 * 1024`.
2. Add `pruneDiskCacheIfNeeded()` to scan files, sum sizes, and delete oldest files when total size exceeds 128 MB (pruning down to 75% watermark).
3. Call `Self.pruneDiskCacheIfNeeded()` within the background `Task.detached(priority: .utility)` where `data.write` executes.

```swift
// In USGS3DEPService:
    private static let maxDiskCacheBytes: Int64 = 128 * 1024 * 1024 // 128 MB

    private static func pruneDiskCacheIfNeeded() {
        guard let dir = diskCacheDirectory else { return }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return }

        var fileDetails: [(url: URL, date: Date, size: Int64)] = []
        var totalSize: Int64 = 0

        for file in urls {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = values?.contentModificationDate ?? .distantPast
            let size = Int64(values?.fileSize ?? 0)
            fileDetails.append((url: file, date: date, size: size))
            totalSize += size
        }

        if totalSize > maxDiskCacheBytes {
            fileDetails.sort { $0.date < $1.date } // Oldest first
            for file in fileDetails where totalSize > (maxDiskCacheBytes * 3 / 4) {
                try? fm.removeItem(at: file.url)
                totalSize -= file.size
            }
        }
    }
```

- [x] **Step 2: Verify compilation and tests**

Run: `./Tools/run-harness.sh && ./Tools/run-live-check.sh`  
Expected: ALL CHECKS PASSED.

- [x] **Step 3: Commit**

```bash
git commit -am "feat: add 128MB bounded LRU disk cache eviction to USGS 3DEP service"
```

---

## Final Verification Checklist

- [x] `./Tools/run-harness.sh` passes 100% with zero regressions.
- [x] `./Tools/run-live-check.sh` passes 100% with zero regressions.
- [x] `xcodebuild -scheme LidarExplorer -destination "platform=iOS Simulator,name=iPhone 17 Pro" build` passes cleanly.
- [x] Git working tree is clean with atomic commits for all 6 tasks.
