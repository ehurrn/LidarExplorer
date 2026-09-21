//
//  TileComposite.swift
//  LidarExplorer
//
//  Stitches shaded map tiles into one image of a region, north up, for draping over a 3D mesh.
//

import CoreGraphics
import Foundation

public nonisolated enum TileComposite {

    /// A shaded tile and the ground it covers.
    public struct Tile: @unchecked Sendable {
        public let image: CGImage
        public let region: GeoRegion
        public let zoom: Int

        public init(image: CGImage, region: GeoRegion, zoom: Int) {
            self.image = image
            self.region = region
            self.zoom = zoom
        }
    }

    /// An image of `region` in Web Mercator, north at the top, at most `maxPixels` on its longer side, with each
    /// tile drawn where its ground is. Coarser tiles go down first so a finer one over the same ground wins.
    ///
    /// With a `background`, that is painted first, so the shading tiles (translucent overlays meant to sit over a
    /// basemap) land on it and ground no tile has drawn is the background rather than nothing. Without one, such
    /// ground is transparent. `nil` for an empty region or no tile that touches it.
    public static func render(tiles: [Tile], region: GeoRegion, maxPixels: Int, background: CGColor? = nil) -> CGImage? {
        let bounds = region.mercatorBounds
        let spanX = bounds.maxX - bounds.minX, spanY = bounds.maxY - bounds.minY
        guard spanX.isFinite, spanY.isFinite, spanX > 0, spanY > 0, maxPixels >= 2 else { return nil }

        let width = spanX >= spanY ? maxPixels : max(2, Int((Double(maxPixels) * spanX / spanY).rounded()))
        let height = spanX >= spanY ? max(2, Int((Double(maxPixels) * spanY / spanX).rounded())) : maxPixels
        let touching = tiles.filter { tile in
            let t = tile.region.mercatorBounds
            return t.maxX > bounds.minX && t.minX < bounds.maxX && t.maxY > bounds.minY && t.minY < bounds.maxY
        }
        guard !touching.isEmpty,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        if let background {
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }

        for tile in touching.sorted(by: { $0.zoom < $1.zoom }) {
            let t = tile.region.mercatorBounds
            // Core Graphics puts the origin at the bottom left, so Mercator's y-up maps straight across.
            context.draw(tile.image, in: CGRect(
                x: (t.minX - bounds.minX) / spanX * Double(width), y: (t.minY - bounds.minY) / spanY * Double(height),
                width: (t.maxX - t.minX) / spanX * Double(width), height: (t.maxY - t.minY) / spanY * Double(height)))
        }
        return context.makeImage()
    }
}
