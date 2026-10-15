//
//  HistoricalMap.swift
//  LidarExplorer
//
//  Georeferenced historical rasters: world files and memory-safe import.
//

import CoreGraphics
import Foundation
import ImageIO
import MapKit

/// An ESRI world file: `X = a·column + b·row + c`, `Y = d·column + e·row + f`,
/// evaluated at pixel centres. Line order in the file is a, d, b, e, c, f.
public nonisolated struct WorldFile: Sendable, Equatable {
    public enum Units: Sendable, Equatable { case degrees, webMercatorMeters }

    public let a: Double, d: Double, b: Double, e: Double, c: Double, f: Double

    public init?(text: String) {
        let values = text.split(whereSeparator: \.isNewline)
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count >= 6 else { return nil }
        (a, d, b, e, c, f) = (values[0], values[1], values[2], values[3], values[4], values[5])
        guard a != 0 || b != 0, e != 0 || d != 0 else { return nil }
    }

    /// A world file from a GeoTIFF's own tags (`ModelPixelScale`, `ModelTiepoint`, and the GeoKeys that say whether
    /// the coordinates are degrees or Web Mercator metres): the georeferencing a scanned quadrangle carries inside
    /// the file, with no sidecar. Nil for a file with no such tags, or in a projection this reader does not take
    /// (a UTM scan needs its sidecar, or a reprojection).
    public init?(geoTIFF data: Data) {
        guard let geo = FloatTIFFDecoder.georeference(of: data) else { return nil }
        let keys = geo.keys
        // Degrees (a geographic model, or WGS 84 named with no projection) and Web Mercator are the two frames a
        // world file can carry here (``units`` tells them apart by their magnitudes); any other projection is
        // refused rather than placed wrongly. A file with no keys at all is read as a world file would read it.
        let geographic = keys?.modelType == 2 || (keys?.geographicEPSG == 4326 && keys?.projectedEPSG == nil)
        let mercator = keys?.projectedEPSG == 3857 || keys?.projectedEPSG == 900913
        let unkeyed = keys == nil || (keys?.modelType == nil && keys?.projectedEPSG == nil && keys?.geographicEPSG == nil)
        guard geographic || mercator || unkeyed else { return nil }
        let t = geo.transform
        // The transform's origin is the first pixel's edge (PixelIsArea) or its centre (PixelIsPoint); the world
        // file names the centre.
        let half = keys?.isPixelIsPoint == true ? 0.0 : 0.5
        self.init(a: t.pixelSizeX, d: 0, b: 0, e: -t.pixelSizeY,
                  c: t.originX + half * t.pixelSizeX, f: t.originY - half * t.pixelSizeY)
        guard (units == .degrees) == geographic || unkeyed else { return nil }
    }

    public init(a: Double, d: Double, b: Double, e: Double, c: Double, f: Double) {
        (self.a, self.d, self.b, self.e, self.c, self.f) = (a, d, b, e, c, f)
    }

    /// Degree coefficients are tiny and the origin lies within ±180/±90.
    public var units: Units {
        abs(c) <= 180 && abs(f) <= 90 && abs(a) < 1 && abs(e) < 1 ? .degrees : .webMercatorMeters
    }

    public func mapPoint(column: Double, row: Double) -> MKMapPoint {
        let x = a * column + b * row + c
        let y = d * column + e * row + f
        switch units {
        case .degrees: return MKMapPoint(CLLocationCoordinate2D(latitude: y, longitude: x))
        case .webMercatorMeters: return MKMapPoint(GeoRegion.fromMercatorMeters(x: x, y: y))
        }
    }

    /// Image space (origin at the top-left pixel *edge*, y down) to map points,
    /// fitted through three corners. Exact for EPSG:3857; for degree files the
    /// Mercator nonlinearity across one sheet is far below a pixel.
    public func mapTransform(imageWidth w: Int, imageHeight h: Int) -> CGAffineTransform {
        let tl = mapPoint(column: -0.5, row: -0.5)
        let tr = mapPoint(column: Double(w) - 0.5, row: -0.5)
        let bl = mapPoint(column: -0.5, row: Double(h) - 0.5)
        return CGAffineTransform(a: (tr.x - tl.x) / Double(w), b: (tr.y - tl.y) / Double(w),
                                 c: (bl.x - tl.x) / Double(h), d: (bl.y - tl.y) / Double(h),
                                 tx: tl.x, ty: tl.y)
    }
}

public nonisolated enum HistoricalMapImporter {
    public static let maximumPixelDimension = 2048

    public struct Imported: @unchecked Sendable {
        public let name: String
        public let image: CGImage
        /// Decoded-image space to map points.
        public let imageToMap: CGAffineTransform
        public let boundingMapRect: MKMapRect

        public init(name: String, image: CGImage, imageToMap: CGAffineTransform, boundingMapRect: MKMapRect) {
            self.name = name
            self.image = image
            self.imageToMap = imageToMap
            self.boundingMapRect = boundingMapRect
        }
    }

    public enum ImportError: Error { case unreadableImage }

    private static let worldFileExtensions: Set<String> = ["pgw", "jgw", "tfw", "wld", "pngw", "jpgw", "tifw", "gfw"]

    public static func worldFileURL(for image: URL, among candidates: [URL]) -> URL? {
        let base = image.deletingPathExtension().lastPathComponent.lowercased()
        return candidates.first {
            $0.deletingPathExtension().lastPathComponent.lowercased() == base
                && worldFileExtensions.contains($0.pathExtension.lowercased())
        }
    }

    /// Decodes at most `maximumPixelDimension` on the long side via ImageIO
    /// thumbnailing (the full scan is never materialised) and rescales the
    /// placement to the decoded size. Without a world file the image is stretched
    /// over `fallbackRegion`.
    public static func importMap(imageURL: URL, worldFile: WorldFile?, fallbackRegion: GeoRegion) throws -> Imported {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let fullWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let fullHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
                  kCGImageSourceCreateThumbnailWithTransform: false,
              ] as CFDictionary)
        else { throw ImportError.unreadableImage }

        // No sidecar: a GeoTIFF's own tags place it (a USGS historical quadrangle carries them); only a file with
        // neither is stretched over the view.
        let embedded = worldFile == nil && ["tif", "tiff"].contains(imageURL.pathExtension.lowercased())
            ? (try? Data(contentsOf: imageURL, options: .mappedIfSafe)).flatMap { WorldFile(geoTIFF: $0) }
            : nil
        let fullToMap: CGAffineTransform
        if let worldFile = worldFile ?? embedded {
            fullToMap = worldFile.mapTransform(imageWidth: fullWidth, imageHeight: fullHeight)
        } else {
            let tl = MKMapPoint(CLLocationCoordinate2D(latitude: fallbackRegion.maxLatitude, longitude: fallbackRegion.minLongitude))
            let br = MKMapPoint(CLLocationCoordinate2D(latitude: fallbackRegion.minLatitude, longitude: fallbackRegion.maxLongitude))
            fullToMap = CGAffineTransform(a: (br.x - tl.x) / Double(fullWidth), b: 0, c: 0,
                                          d: (br.y - tl.y) / Double(fullHeight), tx: tl.x, ty: tl.y)
        }
        let scale = CGAffineTransform(scaleX: Double(fullWidth) / Double(image.width),
                                      y: Double(fullHeight) / Double(image.height))
        let imageToMap = scale.concatenating(fullToMap)
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: image.width, y: 0),
                       CGPoint(x: 0, y: image.height), CGPoint(x: image.width, y: image.height)].map { $0.applying(imageToMap) }
        let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!
        let minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
        return Imported(name: imageURL.deletingPathExtension().lastPathComponent, image: image, imageToMap: imageToMap,
                        boundingMapRect: MKMapRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }
}
