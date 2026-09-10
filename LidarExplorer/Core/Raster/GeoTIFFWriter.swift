//
//  GeoTIFFWriter.swift
//  LidarExplorer
//
//  Streams an ElevationGrid to a georeferenced Float32 GeoTIFF.
//

import Foundation

/// Writes an ``ElevationGrid`` as a single-strip, uncompressed Float32
/// GeoTIFF carrying EPSG:3857 georeferencing.
///
/// This is the *data* raster export — the raw elevation samples a GIS can
/// analyse — as distinct from ``GeoreferencedExportService``, which renders a
/// shaded *picture* plus a world file. The two serve different consumers and
/// share no code.
///
/// ## Byte alignment
///
/// The defect this replaces produced offsets like 146, which is `2 (mod 4)`;
/// GDAL and ImageIO then hit unaligned reads decoding the `DOUBLE` and `FLOAT`
/// payloads and either warn or reject the file. Every variable-length payload
/// here — the tiepoint doubles, the pixel-scale doubles, the GeoKey shorts,
/// and the pixel strip — is placed at an offset rounded **up to a 4-byte
/// boundary** (`(x + 3) & ~3`), and the fixed-size IFD is a multiple of 4 by
/// construction, so nothing lands unaligned.
///
/// ## Tag order
///
/// TIFF requires the IFD entries to be sorted by tag in ascending order; a
/// strict reader rejects an out-of-order directory. The entries below are
/// emitted already sorted (note `305` sits between `279` and `339`, not at the
/// end), so the file validates under libtiff, GDAL, and ImageIO alike.
///
/// ## Registration
///
/// The grid's samples sit at node positions — sample `(0,0)` *is* the
/// `(minX, maxY)` corner and `(w-1, h-1)` *is* `(maxX, minY)` — so the pixel
/// scale is the span divided by `n − 1` and the raster type is **PixelIsPoint**
/// (`RasterTypeGeoKey = 2`). Declaring PixelIsArea with a `/(n−1)` scale, as an
/// earlier draft did, is self-inconsistent by half a pixel.
public final class GeoTIFFWriter: Sendable {
    public static let shared = GeoTIFFWriter()

    public init() {}

    public func export(grid: ElevationGrid, to fileURL: URL) throws {
        let width = UInt32(grid.width)
        let height = UInt32(grid.height)
        let sampleCount = grid.count

        // --- Layout planning -------------------------------------------------
        let headerSize = 8
        let ifdEntryCount: UInt16 = 14
        // 2-byte entry count + N×12-byte entries + 4-byte next-IFD pointer.
        let ifdDataSize = 2 + (Int(ifdEntryCount) * 12) + 4

        let tiepointBytes = 48    // 6 × Double
        let pixelScaleBytes = 24  // 3 × Double
        let geoKeyBytes = 32      // 16 × UInt16 (4-short header + 3 GeoKeys)

        // Every extra-data block starts on a 4-byte boundary.
        let extraDataOffset = (headerSize + ifdDataSize + 3) & ~3
        let tiepointOffset = UInt32(extraDataOffset)
        let pixelScaleOffset = tiepointOffset + UInt32(tiepointBytes)
        let geoKeyOffset = pixelScaleOffset + UInt32(pixelScaleBytes)

        let rawStripOffset = geoKeyOffset + UInt32(geoKeyBytes)
        let stripOffset = (rawStripOffset + 3) & ~3
        let stripByteCounts = UInt32(sampleCount * MemoryLayout<Float>.stride)

        var data = Data()
        data.reserveCapacity(Int(stripOffset) + Int(stripByteCounts))

        // --- TIFF header: little-endian 'II', magic 42 -----------------------
        let header: [UInt8] = [0x49, 0x49, 0x2A, 0x00]
        data.append(contentsOf: header)
        var firstIFD = UInt32(headerSize)
        withUnsafeBytes(of: &firstIFD) { data.append(contentsOf: $0) }

        // --- Image File Directory --------------------------------------------
        var entries = ifdEntryCount
        withUnsafeBytes(of: &entries) { data.append(contentsOf: $0) }

        func appendEntry(tag: UInt16, type: UInt16, count: UInt32, val: UInt32) {
            var t = tag, ty = type, c = count, v = val
            withUnsafeBytes(of: &t) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &ty) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &c) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        // Ascending tag order (required by the TIFF spec).
        appendEntry(tag: 256, type: 4, count: 1, val: width)                 // ImageWidth
        appendEntry(tag: 257, type: 4, count: 1, val: height)               // ImageLength
        appendEntry(tag: 258, type: 3, count: 1, val: 32)                   // BitsPerSample
        appendEntry(tag: 259, type: 3, count: 1, val: 1)                    // Compression = none
        appendEntry(tag: 262, type: 3, count: 1, val: 1)                    // Photometric = BlackIsZero
        appendEntry(tag: 273, type: 4, count: 1, val: stripOffset)         // StripOffsets
        appendEntry(tag: 277, type: 3, count: 1, val: 1)                   // SamplesPerPixel
        appendEntry(tag: 278, type: 4, count: 1, val: height)             // RowsPerStrip = full image
        appendEntry(tag: 279, type: 4, count: 1, val: stripByteCounts)   // StripByteCounts
        appendEntry(tag: 305, type: 2, count: 1, val: 0)                // Software (empty)
        appendEntry(tag: 339, type: 3, count: 1, val: 3)              // SampleFormat = IEEE float
        appendEntry(tag: 33550, type: 12, count: 3, val: pixelScaleOffset) // ModelPixelScale
        appendEntry(tag: 33922, type: 12, count: 6, val: tiepointOffset)   // ModelTiepoint
        appendEntry(tag: 34735, type: 3, count: 16, val: geoKeyOffset)     // GeoKeyDirectory

        var nextIFD: UInt32 = 0
        withUnsafeBytes(of: &nextIFD) { data.append(contentsOf: $0) }

        // --- Extra data blocks (each 4-byte aligned) -------------------------
        while data.count < Int(tiepointOffset) { data.append(0) }

        // Tiepoint: raster (0,0,0) → model (minX, maxY, 0), the NW corner node.
        let bounds = grid.region.mercatorBounds
        let tiepoints: [Double] = [0.0, 0.0, 0.0, bounds.minX, bounds.maxY, 0.0]
        tiepoints.withUnsafeBytes { data.append(contentsOf: $0) }

        // Pixel scale: metres between adjacent nodes (span / (n − 1)).
        let scaleX = grid.width > 1 ? (bounds.maxX - bounds.minX) / Double(grid.width - 1) : 1.0
        let scaleY = grid.height > 1 ? (bounds.maxY - bounds.minY) / Double(grid.height - 1) : 1.0
        let pixelScale: [Double] = [scaleX, scaleY, 0.0]
        pixelScale.withUnsafeBytes { data.append(contentsOf: $0) }

        // GeoKeyDirectory: EPSG:3857, node-registered (PixelIsPoint).
        let geoKeys: [UInt16] = [
            1, 1, 0, 3,        // dir version 1, key rev 1.0, 3 keys
            1024, 0, 1, 1,     // GTModelType      = Projected
            1025, 0, 1, 2,     // GTRasterType     = PixelIsPoint
            3072, 0, 1, 3857,  // ProjectedCSType  = EPSG:3857 Web Mercator
        ]
        geoKeys.withUnsafeBytes { data.append(contentsOf: $0) }

        // --- Pixel strip: contiguous Float32, zero intermediate copies -------
        while data.count < Int(stripOffset) { data.append(0) }

        grid.withUnsafeSamples { src in
            if let base = src.baseAddress {
                data.append(UnsafeBufferPointer(start: base, count: sampleCount))
            }
        }

        try data.write(to: fileURL, options: .atomic)
    }
}
