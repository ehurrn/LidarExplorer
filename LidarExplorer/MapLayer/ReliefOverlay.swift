//
//  ReliefOverlay.swift
//  LidarExplorer
//
//  Displays a locally computed terrain raster over its geographic extent.
//

import MapKit
import os

/// A rendered terrain raster pinned to the region it was computed for.
///
/// `nonisolated` for the same reason as ``HillshadeTileOverlay``: `MKOverlay`
/// and `MKOverlayRenderer` declare their members nonisolated, and MapKit draws
/// on a background queue. Under this target's `SWIFT_DEFAULT_ACTOR_ISOLATION
/// = MainActor` a subclass would otherwise infer `@MainActor` and fail to
/// override.
public nonisolated final class ReliefOverlay: NSObject, MKOverlay {

    public let image: CGImage
    public let region: GeoRegion
    public let coordinate: CLLocationCoordinate2D
    public let boundingMapRect: MKMapRect

    public init(image: CGImage, region: GeoRegion) {
        self.image = image
        self.region = region
        self.coordinate = region.center

        // MKMapRect is built from the north-west and south-east corners.
        let northWest = MKMapPoint(
            CLLocationCoordinate2D(latitude: region.maxLatitude, longitude: region.minLongitude)
        )
        let southEast = MKMapPoint(
            CLLocationCoordinate2D(latitude: region.minLatitude, longitude: region.maxLongitude)
        )
        self.boundingMapRect = MKMapRect(
            x: min(northWest.x, southEast.x),
            y: min(northWest.y, southEast.y),
            width: abs(southEast.x - northWest.x),
            height: abs(southEast.y - northWest.y)
        )
        super.init()
    }
}

/// Draws a ``ReliefOverlay``'s image into the map.
public nonisolated final class ReliefOverlayRenderer: MKOverlayRenderer {

    private let image: CGImage

    public init(overlay: ReliefOverlay) {
        self.image = overlay.image
        super.init(overlay: overlay)
    }

    public override func draw(
        _ mapRect: MKMapRect,
        zoomScale: MKZoomScale,
        in context: CGContext
    ) {
        let rect = rect(for: overlay.boundingMapRect)

        context.saveGState()
        // CGImage origin is top-left; the map context is bottom-left. Flip
        // once here rather than inverting the raster on the CPU every frame.
        context.translateBy(x: 0, y: rect.maxY + rect.minY)
        context.scaleBy(x: 1, y: -1)
        // Terrain rasters are far coarser than the screen at high zoom, so
        // interpolate rather than showing hard sample edges.
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        context.restoreGState()
    }
}
