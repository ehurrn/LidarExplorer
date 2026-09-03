//
//  TerrariumTileService.swift
//  LidarExplorer
//
//  Pre-tiled elevation from AWS Terrain Tiles.
//

import CoreGraphics
import Foundation
import ImageIO
import os

/// Fetches RGB-encoded elevation tiles from the AWS Terrain Tiles archive.
///
/// ## Why a second elevation source
///
/// The 3DEP ImageServer renders every novel extent on demand. Measured
/// against the live service, a first request for a given bbox takes 10-18
/// seconds; the identical URL afterwards returns in 0.14s. That is fine for
/// one deliberate load and hopeless for panning, where every tile is a novel
/// extent.
///
/// These tiles are pre-rendered and served from S3 in about 0.2s, which is
/// what makes continuous browsing possible. They stop at zoom 15 (~3.7 m/px
/// at mid-latitudes), so 3DEP still supplies the native 1 m detail once the
/// user zooms past that.
public actor TerrariumTileService {

    /// Deepest zoom the archive publishes. Verified: z16 returns 404.
    public nonisolated static let maximumZ = 15

    private nonisolated static let host =
        "https://s3.amazonaws.com/elevation-tiles-prod/terrarium"

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.httpMaximumConnectionsPerHost = 8
            config.timeoutIntervalForRequest = 20
            // These tiles are immutable, so a generous on-disk cache means a
            // revisited area costs nothing at all.
            config.urlCache = URLCache(
                memoryCapacity: 32 * 1024 * 1024,
                diskCapacity: 256 * 1024 * 1024,
                diskPath: "terrarium-tiles"
            )
            config.requestCachePolicy = .returnCacheDataElseLoad
            self.session = URLSession(configuration: config)
        }
    }

    /// Fetches and decodes one tile.
    public func elevation(x: Int, y: Int, z: Int, region: GeoRegion) async -> Evidence<ElevationGrid> {
        guard z <= Self.maximumZ else {
            return .unavailable(.noCoverage(.usgs3DEP))
        }
        guard let url = URL(string: "\(Self.host)/\(z)/\(x)/\(y).png") else {
            return .unavailable(.transportFailure(.usgs3DEP, description: "bad tile URL"))
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                // 404 means no coverage here, which is a fact, not a failure.
                return .unavailable(
                    code == 404 ? .noCoverage(.usgs3DEP)
                                : .transportFailure(.usgs3DEP, description: "HTTP \(code)")
                )
            }
            guard let grid = Self.decode(data, region: region) else {
                return .unavailable(.undecodable(.usgs3DEP, description: "terrarium PNG"))
            }
            return .observed(grid, Provenance(source: .usgs3DEP))
        } catch {
            if (error as? URLError)?.code == .cancelled {
                return .unavailable(.transportFailure(.usgs3DEP, description: "cancelled"))
            }
            return .unavailable(
                .transportFailure(.usgs3DEP, description: error.localizedDescription)
            )
        }
    }

    /// Decodes the Terrarium RGB encoding into metres.
    ///
    /// `elevation = (R * 256 + G + B / 256) - 32768`, which gives a range of
    /// -32768 to +32768 m at 1/256 m (about 4 mm) precision — far finer than
    /// the underlying data.
    nonisolated static func decode(_ data: Data, region: GeoRegion) -> ElevationGrid? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        // Redraw into a known layout rather than trusting the PNG's own.
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }

        var samples = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let o = i * 4
            let r = Double(pixels[o]), g = Double(pixels[o + 1]), b = Double(pixels[o + 2])
            samples[i] = Float((r * 256 + g + b / 256) - 32768)
        }

        return ElevationGrid(
            width: width, height: height, samples: samples, region: region
        )
    }
}
