//
//  HillshadeTileOverlay.swift
//  LidarExplorer
//
//  USGS raster basemap layers as MapKit tile overlays.
//

import MapKit
import os

/// A USGS raster tile service that can back the map.
public nonisolated enum TerrainBasemap: String, Sendable, CaseIterable, Identifiable {
    case shadedRelief
    case elevationTinted
    case imagery
    case topographic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .shadedRelief: "Shaded relief"
        case .elevationTinted: "Tinted elevation"
        case .imagery: "Imagery"
        case .topographic: "Topographic"
        }
    }

    /// XYZ template for the service. All are public USGS/National Map endpoints.
    var urlTemplate: String {
        switch self {
        case .shadedRelief:
            "https://basemap.nationalmap.gov/arcgis/rest/services/USGSShadedReliefOnly/MapServer/tile/{z}/{y}/{x}"
        case .elevationTinted:
            "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTNMBlank/MapServer/tile/{z}/{y}/{x}"
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
        case .elevationTinted: 13
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
public nonisolated final class HillshadeTileOverlay: MKTileOverlay {

    private let session: URLSession
    /// Retained so loadTile knows how deep this service goes.
    private let overlayBasemap: TerrainBasemap?

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
        // Deliberately not set to the service's own depth. maximumZ is a hard
        // cutoff: when MapKit needs a deeper tile it draws nothing rather
        // than scaling what exists, which is why the basemap vanished on
        // zoom-in. Requests beyond the service's depth are served from the
        // deepest ancestor tile in loadTile instead.
        self.maximumZ = 20
        self.tileSize = CGSize(width: 256, height: 256)
    }

    /// Fetches one basemap tile.
    ///
    /// The async form, for the reason documented on ``TerrainTileOverlay``:
    /// MapKit dispatches through it, and the completion-handler override is
    /// silently never called.
    public override func loadTile(at path: MKTileOverlayPath) async throws -> Data {
        // Clamp to what the service actually publishes; MapKit will happily
        // ask deeper than that.
        let deepest = (overlayBasemap ?? .shadedRelief).maximumZ
        let requestPath = path.z <= deepest
            ? path
            : MKTileOverlayPath(
                x: path.x >> (path.z - deepest),
                y: path.y >> (path.z - deepest),
                z: deepest,
                contentScaleFactor: path.contentScaleFactor
              )

        let (data, response) = try await session.data(
            for: URLRequest(url: url(forTilePath: requestPath))
        )
        // A non-200 renders as a grey square; treat it as a miss so MapKit
        // leaves the tile blank instead.
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              !data.isEmpty else {
            throw CocoaError(.fileNoSuchFile)
        }
        return data
    }

    /// Finishes outstanding tasks and invalidates the session so basemap switches do not leak.
    public func invalidate() {
        session.finishTasksAndInvalidate()
    }
}
