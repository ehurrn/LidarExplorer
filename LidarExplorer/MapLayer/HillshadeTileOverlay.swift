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

    var maximumZ: Int {
        switch self {
        case .imagery: 16
        default: 15
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

    public init(basemap: TerrainBasemap) {
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
        self.maximumZ = basemap.maximumZ
        self.tileSize = CGSize(width: 256, height: 256)
    }

    public override func loadTile(
        at path: MKTileOverlayPath,
        result: @escaping @Sendable (Data?, (any Error)?) -> Void
    ) {
        let request = URLRequest(url: url(forTilePath: path))
        session.dataTask(with: request) { data, response, error in
            if let error {
                result(nil, error)
                return
            }
            // A 200 with an error body renders as a grey square; treat any
            // non-200 as a miss so MapKit leaves the tile blank instead.
            guard
                let http = response as? HTTPURLResponse, http.statusCode == 200,
                let data, !data.isEmpty
            else {
                result(nil, nil)
                return
            }
            result(data, nil)
        }.resume()
    }
}
