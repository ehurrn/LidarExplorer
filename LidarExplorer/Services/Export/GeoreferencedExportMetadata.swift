//
//  GeoreferencedExportMetadata.swift
//  LidarExplorer
//
//  The georeferencing of a PNG + world file export: the image's footprint, the ESRI world file, the GeoJSON
//  footprint and the badge's text. No MapKit or UIKit here, so the harness checks what the files say; the
//  service that takes the snapshot and draws the image is GeoreferencedExportService.
//

import CoreGraphics
import CoreLocation
import Foundation

public nonisolated enum GeoreferencedExportMetadata {
    /// An image's footprint in Web Mercator metres (EPSG:3857) and its size in pixels: north up, no rotation.
    public struct ImageFrame: Sendable, Equatable {
        public let minX: Double
        public let minY: Double
        public let maxX: Double
        public let maxY: Double
        public let pixelsWide: Int
        public let pixelsHigh: Int

        public init(minX: Double, minY: Double, maxX: Double, maxY: Double, pixelsWide: Int, pixelsHigh: Int) {
            self.minX = minX
            self.minY = minY
            self.maxX = maxX
            self.maxY = maxY
            self.pixelsWide = pixelsWide
            self.pixelsHigh = pixelsHigh
        }

        /// Metres of Mercator ground a pixel spans, across and down.
        public var pixelWidth: Double { (maxX - minX) / Double(pixelsWide) }
        public var pixelHeight: Double { (maxY - minY) / Double(pixelsHigh) }

        /// The footprint in WGS84 degrees.
        public var region: GeoRegion {
            let sw = GeoRegion.fromMercatorMeters(x: minX, y: minY)
            let ne = GeoRegion.fromMercatorMeters(x: maxX, y: maxY)
            return GeoRegion(minLatitude: sw.latitude, maxLatitude: ne.latitude, minLongitude: sw.longitude, maxLongitude: ne.longitude)
        }

        public var center: CLLocationCoordinate2D {
            GeoRegion.fromMercatorMeters(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        }
    }

    /// A coordinate and the pixel a snapshot drew it at: x to the right and y down from the image's top-left corner.
    public struct Calibration: Sendable {
        public let coordinate: CLLocationCoordinate2D
        public let pixel: SIMD2<Double>

        public init(coordinate: CLLocationCoordinate2D, pixel: SIMD2<Double>) {
            self.coordinate = coordinate
            self.pixel = pixel
        }
    }

    /// The frame a `pixelsWide` x `pixelsHigh` image shows when fitted to `region` as MapKit fits a region to a
    /// view: the region's centre kept and its span widened along one axis until the image's aspect holds, so the
    /// whole region is in the image. Nil for a region or size with nothing in it.
    public static func frame(fitting region: GeoRegion, pixelsWide: Int, pixelsHigh: Int) -> ImageFrame? {
        let b = region.mercatorBounds
        let spanX = b.maxX - b.minX, spanY = b.maxY - b.minY
        guard spanX.isFinite, spanY.isFinite, spanX > 0, spanY > 0, pixelsWide > 0, pixelsHigh > 0 else { return nil }
        let aspect = Double(pixelsWide) / Double(pixelsHigh)
        var width = spanX, height = spanY
        if spanX / spanY > aspect { height = spanX / aspect } else { width = spanY * aspect }
        let cx = (b.minX + b.maxX) / 2, cy = (b.minY + b.maxY) / 2
        return ImageFrame(minX: cx - width / 2, minY: cy - height / 2, maxX: cx + width / 2, maxY: cy + height / 2,
                          pixelsWide: pixelsWide, pixelsHigh: pixelsHigh)
    }

    /// The frame a snapshot actually drew, from two of its coordinates and the pixels they landed on: Web Mercator
    /// is linear in the image, so two points fix the scale and the origin. Nil when the two lie on one row or
    /// column, or on one spot.
    public static func frame(pixelsWide: Int, pixelsHigh: Int, calibration a: Calibration, _ b: Calibration) -> ImageFrame? {
        let ma = GeoRegion.toMercatorMeters(a.coordinate), mb = GeoRegion.toMercatorMeters(b.coordinate)
        let dx = b.pixel.x - a.pixel.x, dy = b.pixel.y - a.pixel.y
        // Pixel rows run down the image as Mercator y falls.
        let dmx = mb.x - ma.x, dmy = ma.y - mb.y
        guard pixelsWide > 0, pixelsHigh > 0, abs(dx) > 1e-9, abs(dy) > 1e-9 else { return nil }
        let pixelWidth = dmx / dx, pixelHeight = dmy / dy
        guard pixelWidth.isFinite, pixelHeight.isFinite, pixelWidth > 0, pixelHeight > 0 else { return nil }
        let minX = ma.x - a.pixel.x * pixelWidth
        let maxY = ma.y + a.pixel.y * pixelHeight
        return ImageFrame(minX: minX, minY: maxY - Double(pixelsHigh) * pixelHeight,
                          maxX: minX + Double(pixelsWide) * pixelWidth, maxY: maxY,
                          pixelsWide: pixelsWide, pixelsHigh: pixelsHigh)
    }

    /// One slippy-map tile of a basemap to draw over the image, and where it lands in the image's pixels.
    public struct BasemapTile: Sendable, Equatable {
        public let x: Int
        public let y: Int
        public let z: Int
        public let pixelRect: CGRect
    }

    /// Web Mercator's extent in metres, the world's span at zoom 0.
    public static let mercatorWorldSpan = 2 * Double.pi * 6_378_137

    /// The basemap tiles that cover `frame`, at the zoom where a tile's `tilePixels` are as fine as the image's own
    /// (never finer than needed), no deeper than `maximumZ`, and never more than `maximumTiles` of them (a coarser
    /// zoom otherwise). Each tile with the pixel rect it is drawn into: together they tile the image edge to edge.
    public static func basemapTiles(
        for frame: ImageFrame, tilePixels: Int = 256, maximumZ: Int = 21, maximumTiles: Int = 144
    ) -> (zoom: Int, tiles: [BasemapTile]) {
        guard frame.pixelWidth.isFinite, frame.pixelWidth > 0, frame.pixelHeight > 0, tilePixels > 0 else { return (0, []) }
        let wanted = frame.pixelWidth * Double(tilePixels)
        var zoom = max(0, min(maximumZ, Int((log2(mercatorWorldSpan / wanted)).rounded(.up))))
        func tiles(at z: Int) -> [BasemapTile] {
            let span = mercatorWorldSpan / Double(1 << z)
            let half = mercatorWorldSpan / 2
            let x0 = Int(((frame.minX + half) / span).rounded(.down)), x1 = Int(((frame.maxX + half) / span).rounded(.up)) - 1
            let y0 = Int(((half - frame.maxY) / span).rounded(.down)), y1 = Int(((half - frame.minY) / span).rounded(.up)) - 1
            let count = 1 << z
            var out: [BasemapTile] = []
            for y in max(y0, 0)...max(min(y1, count - 1), max(y0, 0)) {
                for x in max(x0, 0)...max(min(x1, count - 1), max(x0, 0)) {
                    let region = ImageFrame(minX: Double(x) * span - half, minY: half - Double(y + 1) * span,
                                            maxX: Double(x + 1) * span - half, maxY: half - Double(y) * span,
                                            pixelsWide: tilePixels, pixelsHigh: tilePixels)
                    out.append(BasemapTile(x: x, y: y, z: z, pixelRect: pixelRect(of: region, in: frame)))
                }
            }
            return out
        }
        var chosen = tiles(at: zoom)
        while chosen.count > maximumTiles, zoom > 0 {
            zoom -= 1
            chosen = tiles(at: zoom)
        }
        return (zoom, chosen)
    }

    /// Where `region` lies in the image, in pixels from its top-left corner.
    public static func pixelRect(of region: GeoRegion, in frame: ImageFrame) -> CGRect {
        pixelRect(of: ImageFrame(minX: region.mercatorBounds.minX, minY: region.mercatorBounds.minY,
                                 maxX: region.mercatorBounds.maxX, maxY: region.mercatorBounds.maxY, pixelsWide: 1, pixelsHigh: 1), in: frame)
    }

    /// Where another frame's ground lies in this image, in pixels from its top-left corner.
    public static func pixelRect(of other: ImageFrame, in frame: ImageFrame) -> CGRect {
        let x0 = (other.minX - frame.minX) / frame.pixelWidth, x1 = (other.maxX - frame.minX) / frame.pixelWidth
        let y0 = (frame.maxY - other.maxY) / frame.pixelHeight, y1 = (frame.maxY - other.minY) / frame.pixelHeight
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The ESRI world file: the pixel's width, two zero rotation terms, its height (negative: rows run south),
    /// then the centre of the top-left pixel, all in EPSG:3857 metres.
    public static func worldFile(_ frame: ImageFrame) -> String {
        let lines = [
            frame.pixelWidth, 0, 0, -frame.pixelHeight,
            frame.minX + frame.pixelWidth / 2, frame.maxY - frame.pixelHeight / 2,
        ]
        return lines.map { String(format: "%.8f", $0) }.joined(separator: "\n") + "\n"
    }

    /// The CRS the world file's numbers are in, and the one the GeoJSON's are in (RFC 7946 allows no other).
    public static let worldFileCRS = "EPSG:3857 (Web Mercator)"
    public static let geoJSONCRS = "EPSG:4326 (WGS 84)"

    /// The image's footprint as GeoJSON: WGS84 degrees, a closed counter-clockwise ring, with what the file is
    /// and the world file's CRS in the feature's properties. `terrainCoverage` is the share of the view the
    /// terrain shading covers, when known.
    public static func geoJSON(
        _ frame: ImageFrame, styleName: String, groundResolutionMeters: Double?, terrainCoverage: Double?, exportedAt: Date
    ) -> String {
        let r = frame.region
        let ring: [[Double]] = [
            [r.minLongitude, r.minLatitude], [r.maxLongitude, r.minLatitude], [r.maxLongitude, r.maxLatitude],
            [r.minLongitude, r.maxLatitude], [r.minLongitude, r.minLatitude],
        ]
        var properties: [String: Any] = [
            "source": "USGS 3DEP Bare-Earth LiDAR",
            "crs": geoJSONCRS,
            "worldFileCRS": worldFileCRS,
            "worldFilePixelWidthMeters": frame.pixelWidth,
            "worldFilePixelHeightMeters": frame.pixelHeight,
            "imageWidthPixels": frame.pixelsWide,
            "imageHeightPixels": frame.pixelsHigh,
            "shadingStyle": styleName,
            "centerLatitude": frame.center.latitude,
            "centerLongitude": frame.center.longitude,
            "exportedAt": ISO8601DateFormatter().string(from: exportedAt),
        ]
        if let groundResolutionMeters { properties["groundResolutionMeters"] = groundResolutionMeters }
        if let terrainCoverage { properties["terrainCoverage"] = min(max(terrainCoverage, 0), 1) }
        let object: [String: Any] = [
            "type": "FeatureCollection",
            "features": [[
                "type": "Feature",
                "geometry": ["type": "Polygon", "coordinates": [ring]],
                "properties": properties,
            ]],
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text + "\n"
    }

    /// A ground resolution in the display unit: "1.0 m/px" or "3.3 ft/px".
    public static func formattedResolution(_ meters: Double, unit: ElevationUnit) -> String {
        String(format: "%.1f %@/px", unit.fromMeters(meters), unit.symbol)
    }

    /// The badge drawn along the image's foot: the centre with its hemispheres, the style, the ground resolution
    /// when known, and the data's source.
    public static func badgeText(
        center: CLLocationCoordinate2D, styleName: String, resolutionMeters: Double?, unit: ElevationUnit
    ) -> String {
        var parts = [
            String(format: "%.4f°%@, %.4f°%@", abs(center.latitude), center.latitude >= 0 ? "N" : "S",
                   abs(center.longitude), center.longitude >= 0 ? "E" : "W"),
            styleName,
        ]
        if let resolutionMeters, resolutionMeters.isFinite, resolutionMeters > 0 {
            parts.append(formattedResolution(resolutionMeters, unit: unit))
        }
        parts.append("USGS 3DEP LiDAR")
        return parts.joined(separator: "  ·  ")
    }
}
