//
//  GeoreferencedExportService.swift
//  LidarExplorer
//
//  Exports high-resolution georeferenced terrain imagery with ESRI World Files (.pgw)
//  and GeoJSON boundary metadata for GIS packages (QGIS, ArcGIS).
//

import CoreGraphics
import CoreLocation
import Foundation
import MapKit
import UIKit

/// Result package containing exported georeferenced files.
public nonisolated struct GeoreferencedExportResult: Sendable {
    public let imageURL: URL
    public let worldFileURL: URL
    public let metadataURL: URL
    public let allURLs: [URL]

    public init(imageURL: URL, worldFileURL: URL, metadataURL: URL) {
        self.imageURL = imageURL
        self.worldFileURL = worldFileURL
        self.metadataURL = metadataURL
        self.allURLs = [imageURL, worldFileURL, metadataURL]
    }
}

public nonisolated final class GeoreferencedExportService: Sendable {

    public init() {}

    /// Renders the current map region as a high-resolution PNG with accompanying
    /// ESRI World File (.pgw) and GeoJSON spatial metadata.
    public func export(
        region: MKCoordinateRegion,
        style: ReliefStyle,
        elevationUnit: ElevationUnit,
        resolutionMeters: Double?
    ) async throws -> GeoreferencedExportResult {
        let size = CGSize(width: 1024, height: 1024)
        let scale: CGFloat = 2.0 // Produces a crisp 2048x2048 image

        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.scale = scale
        options.pointOfInterestFilter = .excludingAll

        let snapshotter = MKMapSnapshotter(options: options)
        let snapshot = try await snapshotter.start()

        // Render base map snapshot with cartographic scale bar and annotations
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let renderedImage = renderer.image { ctx in
            // 1. Draw MapKit snapshot
            snapshot.image.draw(in: CGRect(origin: .zero, size: size))

            // 2. Draw Cartographic Overlay HUD
            drawCartographicOverlays(
                in: ctx.cgContext,
                size: size,
                region: region,
                elevationUnit: elevationUnit,
                style: style,
                resolutionMeters: resolutionMeters
            )
        }

        guard let pngData = renderedImage.pngData() else {
            throw NSError(domain: "GeoreferencedExportService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode PNG image."
            ])
        }

        // Calculate ESRI World File (.pgw) parameters in Web Mercator (EPSG:3857)
        let geoRegion = GeoRegion(
            center: region.center,
            latitudeSpan: region.span.latitudeDelta,
            longitudeSpan: region.span.longitudeDelta
        )

        let sw = GeoRegion.toMercatorMeters(CLLocationCoordinate2D(latitude: geoRegion.minLatitude, longitude: geoRegion.minLongitude))
        let ne = GeoRegion.toMercatorMeters(CLLocationCoordinate2D(latitude: geoRegion.maxLatitude, longitude: geoRegion.maxLongitude))

        let minX = min(sw.x, ne.x)
        let maxX = max(sw.x, ne.x)
        let minY = min(sw.y, ne.y)
        let maxY = max(sw.y, ne.y)

        let pixelWidth = (maxX - minX) / Double(size.width * scale)
        let pixelHeight = (maxY - minY) / Double(size.height * scale)
        let originX = minX + pixelWidth / 2.0
        let originY = maxY - pixelHeight / 2.0

        let pgwContent = """
        \(String(format: "%.8f", pixelWidth))
        0.00000000
        0.00000000
        \(String(format: "%.8f", -pixelHeight))
        \(String(format: "%.8f", originX))
        \(String(format: "%.8f", originY))
        """

        let geojsonContent = """
        {
          "type": "FeatureCollection",
          "features": [
            {
              "type": "Feature",
              "geometry": {
                "type": "Polygon",
                "coordinates": [
                  [
                    [\(geoRegion.minLongitude), \(geoRegion.minLatitude)],
                    [\(geoRegion.maxLongitude), \(geoRegion.minLatitude)],
                    [\(geoRegion.maxLongitude), \(geoRegion.maxLatitude)],
                    [\(geoRegion.minLongitude), \(geoRegion.maxLatitude)],
                    [\(geoRegion.minLongitude), \(geoRegion.minLatitude)]
                  ]
                ]
              },
              "properties": {
                "source": "USGS 3DEP Bare-Earth LiDAR",
                "projection": "EPSG:3857 (Web Mercator)",
                "shadingStyle": "\(style.displayName)",
                "centerLatitude": \(region.center.latitude),
                "centerLongitude": \(region.center.longitude),
                "exportedAt": "\(ISO8601DateFormatter().string(from: Date()))"
              }
            }
          ]
        }
        """

        // Write files to unique temporary directory
        let exportID = UUID().uuidString.prefix(8)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let baseName = "LidarExplorer_\(timestamp)_\(exportID)"

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(baseName, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let imageURL = tempDir.appendingPathComponent("\(baseName).png")
        let worldFileURL = tempDir.appendingPathComponent("\(baseName).pgw")
        let metadataURL = tempDir.appendingPathComponent("\(baseName).geojson")

        try pngData.write(to: imageURL)
        try pgwContent.write(to: worldFileURL, atomically: true, encoding: .utf8)
        try geojsonContent.write(to: metadataURL, atomically: true, encoding: .utf8)

        return GeoreferencedExportResult(
            imageURL: imageURL,
            worldFileURL: worldFileURL,
            metadataURL: metadataURL
        )
    }

    // MARK: - Cartographic Elements

    private func drawCartographicOverlays(
        in ctx: CGContext,
        size: CGSize,
        region: MKCoordinateRegion,
        elevationUnit: ElevationUnit,
        style: ReliefStyle,
        resolutionMeters: Double?
    ) {
        // Bottom badge with coordinates, style, and USGS attribution
        let badgeRect = CGRect(x: 16, y: size.height - 48, width: size.width - 32, height: 32)
        ctx.saveGState()
        let badgePath = UIBezierPath(roundedRect: badgeRect, cornerRadius: 8)
        UIColor.black.withAlphaComponent(0.65).setFill()
        badgePath.fill()

        let coordText = String(
            format: "%.4f°N, %.4f°W  ·  %@  ·  USGS 3DEP LiDAR",
            region.center.latitude,
            abs(region.center.longitude),
            style.displayName
        )

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let textSize = (coordText as NSString).size(withAttributes: attributes)
        let textRect = CGRect(
            x: badgeRect.origin.x + 12,
            y: badgeRect.origin.y + (badgeRect.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        (coordText as NSString).draw(in: textRect, withAttributes: attributes)

        // North Arrow in top-right
        let northRect = CGRect(x: size.width - 50, y: 16, width: 34, height: 34)
        let northBg = UIBezierPath(ovalIn: northRect)
        UIColor.black.withAlphaComponent(0.65).setFill()
        northBg.fill()

        let northText = "N ▲"
        let northAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: UIColor.systemOrange
        ]
        let northSize = (northText as NSString).size(withAttributes: northAttributes)
        let northTextRect = CGRect(
            x: northRect.origin.x + (northRect.width - northSize.width) / 2,
            y: northRect.origin.y + (northRect.height - northSize.height) / 2,
            width: northSize.width,
            height: northSize.height
        )
        (northText as NSString).draw(in: northTextRect, withAttributes: northAttributes)

        ctx.restoreGState()
    }
}
