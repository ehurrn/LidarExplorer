//
//  HistoricalMapOverlay.swift
//  LidarExplorer
//

import CoreGraphics
import MapKit

public nonisolated final class HistoricalMapOverlay: NSObject, MKOverlay, @unchecked Sendable {
    public let imported: HistoricalMapImporter.Imported
    public var boundingMapRect: MKMapRect { imported.boundingMapRect }
    public var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: imported.boundingMapRect.midX, y: imported.boundingMapRect.midY).coordinate
    }

    public init(imported: HistoricalMapImporter.Imported) {
        self.imported = imported
    }
}

/// Draws the scan through its affine placement; west of `wipeMapX` only, when set.
public nonisolated final class HistoricalMapRenderer: MKOverlayRenderer {
    private let lock = NSLock()
    private var wipeMapX: Double?

    public func setWipe(mapX: Double?) {
        lock.withLock { wipeMapX = mapX }
        setNeedsDisplay()
    }

    public override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let historical = overlay as? HistoricalMapOverlay else { return }
        let image = historical.imported.image
        let wipe = lock.withLock { wipeMapX }
        context.saveGState()
        if let wipe {
            let b = historical.boundingMapRect
            context.clip(to: rect(for: MKMapRect(x: b.minX, y: b.minY, width: max(wipe - b.minX, 0), height: b.height)))
        }
        let origin = point(for: MKMapPoint(x: 0, y: 0))
        let unit = point(for: MKMapPoint(x: 1, y: 1))
        let mapToRenderer = CGAffineTransform(a: unit.x - origin.x, b: 0, c: 0, d: unit.y - origin.y, tx: origin.x, ty: origin.y)
        context.concatenate(historical.imported.imageToMap.concatenating(mapToRenderer))
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.restoreGState()
    }
}
