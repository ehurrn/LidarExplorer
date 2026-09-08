//
//  HillshadeTileOverlay.swift
//  LidarExplorer
//
//  USGS raster basemap layers as MapKit tile overlays.
//

import CoreGraphics
import ImageIO
import MapKit
import UniformTypeIdentifiers
import os

/// A USGS raster tile service that can back the map.
public nonisolated enum TerrainBasemap: String, Sendable, CaseIterable, Identifiable {
    case shadedRelief
    case imageryTopo
    case imagery
    case topographic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .shadedRelief: "Shaded relief"
        case .imageryTopo: "Imagery + labels"
        case .imagery: "Imagery"
        case .topographic: "Topographic"
        }
    }

    /// XYZ template for the service. All are public USGS/National Map endpoints.
    var urlTemplate: String {
        switch self {
        case .shadedRelief:
            "https://basemap.nationalmap.gov/arcgis/rest/services/USGSShadedReliefOnly/MapServer/tile/{z}/{y}/{x}"
        case .imageryTopo:
            "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryTopo/MapServer/tile/{z}/{y}/{x}"
        case .imagery:
            "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}"
        case .topographic:
            "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}"
        }
    }

    /// Highest zoom level the service actually has tiles for.
    ///
    /// Measured against the live services rather than assumed: requesting
    /// beyond these returns 404, and MapKit then draws nothing, so the
    /// basemap appeared to vanish once you zoomed past it. With the correct
    /// value MapKit upsamples the deepest available tile instead.
    ///
    /// Shaded relief is much shallower than the others — it is a
    /// small-scale context layer, which is fine here because the app renders
    /// its own relief from 1 m elevation at high zoom.
    var maximumZ: Int {
        switch self {
        case .shadedRelief: 13
        case .imageryTopo: 16
        case .imagery: 16
        case .topographic: 16
        }
    }
}

/// Tile overlay for the USGS raster basemaps.
///
/// ## Swift 6 isolation
///
/// `MKTileOverlay`'s members are `nonisolated`. Under this target's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, a subclass would otherwise
/// infer `@MainActor` on its `init` and its `loadTile(at:result:)` override,
/// which is an error: "has different actor isolation from nonisolated
/// overridden declaration". That single mismatch accounted for a large share
/// of the errors in the code this replaces.
///
/// Declaring the whole class `nonisolated` is the correct fix rather than
/// annotating each member — the type genuinely has no main-actor state, and
/// MapKit calls `loadTile` from a background queue.
public nonisolated final class HillshadeTileOverlay: MKTileOverlay, @unchecked Sendable {

    private let session: URLSession
    /// Retained so loadTile knows how deep this service goes.
    private let overlayBasemap: TerrainBasemap?
    /// In-memory cache of decoded ancestor tiles so sibling sub-tiles avoid duplicate fetches and decodes.
    private let ancestorImageCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 64
        return cache
    }()
    /// Singleflight coalescing map for in-flight ancestor fetches across concurrent threads.
    private let inFlightLock = OSAllocatedUnfairLock<[String: Task<CGImage, any Error>]>(initialState: [:])

    public init(basemap: TerrainBasemap) {
        self.overlayBasemap = basemap
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .returnCacheDataElseLoad
        // A 128 MB on-disk tile cache keeps panning responsive and cuts
        // repeat load on the National Map service.
        config.urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 128 * 1024 * 1024,
            diskPath: "usgs-tiles"
        )
        config.httpAdditionalHeaders = [
            "User-Agent": "LidarExplorer/1.0 (github.com/ehurrn/LidarExplorer)"
        ]
        self.session = URLSession(configuration: config)

        super.init(urlTemplate: basemap.urlTemplate)

        self.canReplaceMapContent = basemap != .shadedRelief
        // Maximum zoom supported on retina displays without dropping out.
        // Requests beyond the service's depth are sliced and upscaled from
        // the deepest ancestor tile in loadTile so child tiles never repeat.
        self.maximumZ = 21
        self.tileSize = CGSize(width: 256, height: 256)
    }

    /// Fetches one basemap tile.
    ///
    /// The async form, for the reason documented on ``TerrainTileOverlay``:
    /// MapKit dispatches through it, and the completion-handler override is
    /// silently never called.
    public override func loadTile(at path: MKTileOverlayPath) async throws -> Data {
        let deepest = (overlayBasemap ?? .shadedRelief).maximumZ

        if path.z <= deepest {
            let (data, response) = try await session.data(
                for: URLRequest(url: url(forTilePath: path))
            )
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  !data.isEmpty else {
                throw CocoaError(.fileNoSuchFile)
            }
            return data
        }

        // Overzoom: slice and upscale the sub-quadrant from the deepest ancestor tile.
        // Returning the full ancestor tile directly would replicate it into every child
        // tile frame, causing a repeating grid of identical duplicate tiles across the view.
        let deltaZ = path.z - deepest
        let scale = 1 << deltaZ
        let ancestorX = path.x >> deltaZ
        let ancestorY = path.y >> deltaZ
        let keyString = "\(deepest)/\(ancestorX)/\(ancestorY)"

        let ancestorImage: CGImage
        if let cached = ancestorImageCache.object(forKey: keyString as NSString) {
            ancestorImage = cached
        } else {
            let task: Task<CGImage, any Error> = inFlightLock.withLock { inFlight in
                if let existing = inFlight[keyString] {
                    return existing
                }
                let ancestorPath = MKTileOverlayPath(
                    x: ancestorX,
                    y: ancestorY,
                    z: deepest,
                    contentScaleFactor: 1
                )
                let tileUrl = self.url(forTilePath: ancestorPath)
                let newTask = Task<CGImage, any Error> { [session] in
                    defer {
                        self.inFlightLock.withLock { _ = $0.removeValue(forKey: keyString) }
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
                    self.ancestorImageCache.setObject(decoded, forKey: keyString as NSString)
                    return decoded
                }
                inFlight[keyString] = newTask
                return newTask
            }
            ancestorImage = try await task.value
        }

        let subX = path.x & (scale - 1)
        let subY = path.y & (scale - 1)
        let outPixels = Int(tileSize.width * max(path.contentScaleFactor, 1))

        guard let subTileData = Self.subTile(
            from: ancestorImage,
            subX: subX,
            subY: subY,
            scale: scale,
            targetPixels: outPixels
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return subTileData
    }

    /// Slices and upscales the sub-rectangle of an ancestor image covering a child tile.
    nonisolated static func subTile(
        from fullImage: CGImage,
        subX: Int,
        subY: Int,
        scale: Int,
        targetPixels: Int
    ) -> Data? {
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

    /// Finishes outstanding tasks and invalidates the session so basemap switches do not leak.
    public func invalidate() {
        inFlightLock.withLock { inFlight in
            for task in inFlight.values {
                task.cancel()
            }
            inFlight.removeAll()
        }
        ancestorImageCache.removeAllObjects()
        session.finishTasksAndInvalidate()
    }
}
