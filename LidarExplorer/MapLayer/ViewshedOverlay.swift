//
//  ViewshedOverlay.swift
//  LidarExplorer
//
//  The visible-ground mask drawn over the map.
//

import CoreGraphics
import MapKit

/// One viewshed result, placed over the Mercator extent it was computed on.
///
/// Immutable after init, which is what makes handing it to MapKit's
/// background drawing threads safe.
public nonisolated final class ViewshedOverlay: NSObject, MKOverlay, @unchecked Sendable {
    public let image: CGImage
    public let boundingMapRect: MKMapRect

    public var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
    }

    public init(image: CGImage, region: GeoRegion) {
        self.image = image
        let northWest = MKMapPoint(CLLocationCoordinate2D(latitude: region.maxLatitude, longitude: region.minLongitude))
        let southEast = MKMapPoint(CLLocationCoordinate2D(latitude: region.minLatitude, longitude: region.maxLongitude))
        self.boundingMapRect = MKMapRect(
            x: northWest.x, y: northWest.y,
            width: southEast.x - northWest.x, height: southEast.y - northWest.y
        )
    }
}

/// Draws the mask's pixels straight into the map's context, nearest-neighbour
/// so a visibility edge stays an edge rather than a smear.
public nonisolated final class ViewshedOverlayRenderer: MKOverlayRenderer {
    public override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let viewshed = overlay as? ViewshedOverlay else { return }
        let rect = self.rect(for: viewshed.boundingMapRect)
        context.saveGState()
        // Core Graphics draws images bottom-up; the overlay context is top-down.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(viewshed.image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}
