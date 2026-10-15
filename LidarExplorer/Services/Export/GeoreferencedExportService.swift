//
//  GeoreferencedExportService.swift
//  LidarExplorer
//
//  Exports the map with its terrain shading as a georeferenced PNG, with an ESRI World File (.pgw) and a GeoJSON
//  footprint for GIS packages (QGIS, ArcGIS). The files' contents come from GeoreferencedExportMetadata, which the
//  harness checks; this file takes the basemap snapshot and draws the image, which only UIKit can.
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

    /// Renders the map region as a high-resolution PNG, the terrain shading the map draws laid over Apple's basemap,
    /// with an ESRI World File (.pgw) in Web Mercator and a GeoJSON footprint in WGS 84.
    ///
    /// The snapshot fits `region` into a square image, so the image shows more ground than the region along one
    /// axis; the world file and the footprint describe the image's own ground, read off two points the snapshot
    /// drew. `terrain` supplies the shaded tiles (``TerrainTileProvider/shadedComposite(over:maxPixels:background:)``),
    /// drawn at `terrainOpacity` as the map draws them; `terrainCoverage` is the share of the image they cover, for
    /// the footprint's properties. `basemap` is the one the map shows: Apple's imagery is the snapshot's own; a USGS
    /// basemap's tiles are fetched as the map fetches them (``HillshadeTileOverlay``) and drawn over the snapshot at
    /// `basemapOpacity`, as the map draws them.
    public func export(
        region: MKCoordinateRegion,
        style: ReliefStyle,
        elevationUnit: ElevationUnit,
        resolutionMeters: Double?,
        terrain: TerrainTileProvider? = nil,
        terrainOpacity: Double = 1,
        terrainCoverage: Double? = nil,
        basemap: BasemapChoice = .usgs(.shadedRelief),
        basemapOpacity: Double = 1
    ) async throws -> GeoreferencedExportResult {
        let size = CGSize(width: 1024, height: 1024)
        let scale: CGFloat = 2.0 // Produces a crisp 2048x2048 image
        let pixelsWide = Int(size.width * scale), pixelsHigh = Int(size.height * scale)

        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.scale = scale
        options.pointOfInterestFilter = .excludingAll
        if case .appleImagery = basemap {
            options.preferredConfiguration = MKImageryMapConfiguration()
        }

        let snapshotter = MKMapSnapshotter(options: options)
        let snapshot = try await snapshotter.start()

        // The ground the snapshot drew: two points of the region and where they landed, in the image's pixels.
        let frame = Self.frame(of: snapshot, region: region, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh)
        guard let frame else {
            throw NSError(domain: "GeoreferencedExportService", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The map snapshot could not be georeferenced."
            ])
        }

        // The USGS basemap's tiles over the image's ground, as the map draws them over Apple's; none for Apple's own.
        let basemapTiles = await Self.basemapTiles(for: frame, basemap: basemap)
        let basemapAlpha = CGFloat(min(max(basemapOpacity, 0), 1))

        // The shaded terrain over the image's whole ground, transparent where no tile has drawn.
        let terrainImage = await terrain?.shadedComposite(over: frame.region, maxPixels: pixelsWide, background: nil)
        let opacity = CGFloat(min(max(terrainOpacity, 0), 1))
        let badge = GeoreferencedExportMetadata.badgeText(
            center: frame.center, styleName: style.displayName, resolutionMeters: resolutionMeters, unit: elevationUnit)

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let renderedImage = renderer.image { ctx in
            // 1. Apple's basemap, as the snapshot drew it, and the USGS basemap's tiles over it where that is the map's.
            snapshot.image.draw(in: CGRect(origin: .zero, size: size))
            for tile in basemapTiles {
                let rect = CGRect(x: tile.pixelRect.minX / scale, y: tile.pixelRect.minY / scale,
                                  width: tile.pixelRect.width / scale, height: tile.pixelRect.height / scale)
                tile.image.draw(in: rect, blendMode: .normal, alpha: basemapAlpha)
            }

            // 2. The terrain shading the map draws over it, at the map's opacity.
            if let terrainImage {
                UIImage(cgImage: terrainImage).draw(in: CGRect(origin: .zero, size: size), blendMode: .normal, alpha: opacity)
            }

            // 3. The badge and the north arrow.
            drawCartographicOverlays(in: ctx.cgContext, size: size, badge: badge)
        }

        guard let pngData = renderedImage.pngData() else {
            throw NSError(domain: "GeoreferencedExportService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode PNG image."
            ])
        }

        let pgwContent = GeoreferencedExportMetadata.worldFile(frame)
        let geojsonContent = GeoreferencedExportMetadata.geoJSON(
            frame, styleName: style.displayName, groundResolutionMeters: resolutionMeters,
            terrainCoverage: terrainCoverage, exportedAt: Date())

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

    /// A fetched basemap tile and where it lands in the image.
    private struct FetchedBasemapTile: @unchecked Sendable {
        let image: UIImage
        let pixelRect: CGRect
    }

    /// The USGS basemap's tiles covering `frame` (``GeoreferencedExportMetadata/basemapTiles(for:tilePixels:maximumZ:maximumTiles:)``),
    /// fetched through the overlay the map uses, so the harvested tiles and the URL cache answer first and a zoom past
    /// the service's deepest is sliced from an ancestor as on the map. A tile that cannot be fetched is left out: the
    /// snapshot's basemap shows there. Empty for Apple's imagery.
    private static func basemapTiles(for frame: GeoreferencedExportMetadata.ImageFrame, basemap: BasemapChoice) async -> [FetchedBasemapTile] {
        guard case .usgs(let service) = basemap else { return [] }
        // MKTileOverlay is not Sendable, but loadTile(at:) is what MapKit calls from its own concurrent tile loads,
        // and this overlay's loader guards its shared state with a lock: the fetches below may share it.
        nonisolated(unsafe) let overlay = HillshadeTileOverlay(basemap: service)
        let plan = GeoreferencedExportMetadata.basemapTiles(for: frame, tilePixels: Int(overlay.tileSize.width))
        return await withTaskGroup(of: FetchedBasemapTile?.self, returning: [FetchedBasemapTile].self) { group in
            var pending = plan.tiles[...]
            var fetched: [FetchedBasemapTile] = []
            func fetch(_ tile: GeoreferencedExportMetadata.BasemapTile) {
                group.addTask {
                    let path = MKTileOverlayPath(x: tile.x, y: tile.y, z: tile.z, contentScaleFactor: 1)
                    guard let data = try? await overlay.loadTile(at: path), let image = UIImage(data: data) else { return nil }
                    return FetchedBasemapTile(image: image, pixelRect: tile.pixelRect)
                }
            }
            // Six at a time, the overlay's own connection limit.
            for _ in 0..<6 { if let next = pending.popFirst() { fetch(next) } }
            for await result in group {
                if let result { fetched.append(result) }
                if let next = pending.popFirst() { fetch(next) }
            }
            return fetched
        }
    }

    /// The image's ground, from where the snapshot put the region's centre and a point a quarter span off it;
    /// the region fitted to the image's shape when the snapshot's own mapping is degenerate.
    private static func frame(
        of snapshot: MKMapSnapshotter.Snapshot, region: MKCoordinateRegion, pixelsWide: Int, pixelsHigh: Int
    ) -> GeoreferencedExportMetadata.ImageFrame? {
        let scale = Double(pixelsWide) / Double(snapshot.image.size.width)
        let centre = region.center
        let off = CLLocationCoordinate2D(
            latitude: centre.latitude + region.span.latitudeDelta / 4,
            longitude: centre.longitude + region.span.longitudeDelta / 4)
        func calibration(_ coordinate: CLLocationCoordinate2D) -> GeoreferencedExportMetadata.Calibration {
            let point = snapshot.point(for: coordinate)
            return GeoreferencedExportMetadata.Calibration(
                coordinate: coordinate, pixel: SIMD2(Double(point.x) * scale, Double(point.y) * scale))
        }
        if let calibrated = GeoreferencedExportMetadata.frame(
            pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, calibration: calibration(centre), calibration(off)) {
            return calibrated
        }
        let geoRegion = GeoRegion(
            center: region.center, latitudeSpan: region.span.latitudeDelta, longitudeSpan: region.span.longitudeDelta)
        return GeoreferencedExportMetadata.frame(fitting: geoRegion, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh)
    }

    // MARK: - Cartographic Elements

    private func drawCartographicOverlays(in ctx: CGContext, size: CGSize, badge: String) {
        // Bottom badge with coordinates, style, resolution and USGS attribution
        let badgeRect = CGRect(x: 16, y: size.height - 48, width: size.width - 32, height: 32)
        ctx.saveGState()
        let badgePath = UIBezierPath(roundedRect: badgeRect, cornerRadius: 8)
        UIColor.black.withAlphaComponent(0.65).setFill()
        badgePath.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let textSize = (badge as NSString).size(withAttributes: attributes)
        let textRect = CGRect(
            x: badgeRect.origin.x + 12,
            y: badgeRect.origin.y + (badgeRect.height - textSize.height) / 2,
            width: min(textSize.width, badgeRect.width - 24),
            height: textSize.height
        )
        (badge as NSString).draw(in: textRect, withAttributes: attributes)

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
