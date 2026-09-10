//
//  ElevationGridCoder.swift
//  LidarExplorer
//
//  Binary encoding for cached elevation rasters.
//

import Foundation

/// Serialises an ``ElevationGrid`` for the on-disk tile cache.
///
/// ## Why a raw format rather than a compressed one
///
/// Measured on a 264x264 tile of synthetic terrain, zlib returns 88% of the
/// raw size, and 68% after byte-shuffling the mantissas — a third off, for a
/// compression pass on every read and write of a cache whose whole purpose is
/// to be cheaper than recomputing. Encode and decode as raw `Float32` measure
/// 0.004 ms; the budget absorbs the size more comfortably than the tile path
/// absorbs the latency.
///
/// ## Why lossless
///
/// Elevation is measured data. Storing it as scaled `Int16` would halve the
/// file and put a few centimetres of fabricated precision behind readouts
/// that present themselves as observations — the exact confusion ``Evidence``
/// exists to make unrepresentable.
///
/// ## Why the sample block starts at a page boundary
///
/// `LEG2` pads the header out to ``sampleOffset`` (4096 bytes) so the
/// `Float32` block begins on a boundary Metal will accept. A mapped cache file
/// can then be handed to `makeBuffer(bytesNoCopy:)` whole — the mapping's base
/// is page-aligned by construction — and the sample block addressed with a
/// 4096-byte *buffer offset*, which needs only 4-byte alignment. The raster
/// reaches the GPU without ever being copied into the heap. The waste is one
/// header page against a ~272 KB payload.
///
/// `LEG1` payloads (the sample block packed immediately after a
/// variable-length source string) still decode, so an existing cache survives
/// the upgrade; they simply take the copying path.
public nonisolated enum ElevationGridCoder {

    /// `LEG1`, big-endian, so a truncated or foreign payload is rejected
    /// rather than misread. Sample block packed immediately after the source.
    private static let magicV1: UInt32 = 0x4C45_4731

    /// `LEG2`. Identical header fields; sample block at ``sampleOffset``.
    private static let magicV2: UInt32 = 0x4C45_4732

    /// magic + width + height + 4 region doubles + source length.
    private static let headerBytes = 4 + 4 + 4 + (8 * 4) + 4

    /// Byte offset of the `Float32` block in a `LEG2` payload.
    ///
    /// A whole page on every platform this ships to, and a divisor of the
    /// 16 KB pages Apple silicon actually uses, so the offset is valid as a
    /// Metal buffer offset regardless of the host's page size.
    public static let sampleOffset = 4096

    /// Guards against a corrupt header describing an absurd allocation.
    private static let maxDimension = 16_384

    /// Longest source string accepted, in UTF-8 bytes.
    private static let maxSourceBytes = 256

    public struct StoredGrid: Sendable {
        public let grid: ElevationGrid
        /// Which service produced this raster, carried so a restored tile
        /// reports the same provenance a freshly fetched one would.
        public let source: String
    }

    /// Everything a payload declares about itself, without touching the
    /// sample block.
    ///
    /// Separated out so the zero-copy path can validate a mapped file and
    /// then point Metal straight at its samples, rather than decoding into an
    /// `ElevationGrid` it would immediately copy back out again.
    public nonisolated struct Header: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let region: GeoRegion
        public let source: String
        /// Byte offset of the `Float32` block within the payload.
        public let sampleOffset: Int

        public var sampleCount: Int { width * height }
        public var sampleByteCount: Int { sampleCount * MemoryLayout<Float>.stride }
        /// Whether the sample block starts where Metal can address it directly.
        public var isPageAligned: Bool {
            sampleOffset == ElevationGridCoder.sampleOffset
        }
    }

    // MARK: - Encoding

    public static func encode(_ grid: ElevationGrid, source: String) -> Data? {
        guard grid.width > 0, grid.height > 0,
              grid.samples.count == grid.width * grid.height
        else { return nil }

        let sourceBytes = Array(source.utf8)
        guard sourceBytes.count <= maxSourceBytes else { return nil }

        var data = Data(capacity: sampleOffset + grid.samples.count * 4)

        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendInt32(_ value: Int32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendDouble(_ value: Double) {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }

        appendUInt32(magicV2)
        appendInt32(Int32(grid.width))
        appendInt32(Int32(grid.height))
        appendDouble(grid.region.minLatitude)
        appendDouble(grid.region.maxLatitude)
        appendDouble(grid.region.minLongitude)
        appendDouble(grid.region.maxLongitude)
        appendInt32(Int32(sourceBytes.count))
        data.append(contentsOf: sourceBytes)
        data.append(Data(count: sampleOffset - data.count))
        grid.samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        return data
    }

    // MARK: - Decoding

    /// Validates a payload's header, or returns `nil` for anything that is not
    /// exactly what ``encode(_:source:)`` produced.
    ///
    /// Every field is checked before an ``ElevationGrid`` can be constructed
    /// from it: that initialiser has a `precondition` on buffer length, so a
    /// truncated or corrupted cache file would otherwise crash the app rather
    /// than simply miss.
    public static func decodeHeader(_ bytes: UnsafeRawBufferPointer) -> Header? {
        guard bytes.count >= headerBytes else { return nil }

        func readUInt32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        func readInt32(_ offset: Int) -> Int32 { Int32(bitPattern: readUInt32(offset)) }
        func readDouble(_ offset: Int) -> Double {
            var pattern: UInt64 = 0
            for i in 0..<8 { pattern |= UInt64(bytes[offset + i]) << (8 * UInt64(i)) }
            return Double(bitPattern: pattern)
        }

        let magic = readUInt32(0)
        guard magic == magicV1 || magic == magicV2 else { return nil }

        let width = Int(readInt32(4))
        let height = Int(readInt32(8))
        guard width > 0, height > 0, width <= maxDimension, height <= maxDimension
        else { return nil }

        let minLat = readDouble(12)
        let maxLat = readDouble(20)
        let minLon = readDouble(28)
        let maxLon = readDouble(36)
        guard minLat.isFinite, maxLat.isFinite, minLon.isFinite, maxLon.isFinite,
              minLat <= maxLat, minLon <= maxLon
        else { return nil }

        let sourceLength = Int(readInt32(44))
        guard sourceLength >= 0, sourceLength <= maxSourceBytes else { return nil }

        let sourceStart = headerBytes
        guard bytes.count >= sourceStart + sourceLength else { return nil }
        let sampleStart = magic == magicV2 ? sampleOffset : sourceStart + sourceLength
        guard sampleStart >= sourceStart + sourceLength else { return nil }

        // Multiplication first, in Int, so a hostile width x height cannot wrap.
        let sampleCount = width * height
        guard sampleCount > 0, sampleCount <= maxDimension * maxDimension else { return nil }

        // A mapped file is rounded up to a page, so the payload may be
        // *followed* by zero fill; a short one is still corrupt.
        guard bytes.count >= sampleStart + sampleCount * 4 else { return nil }

        guard let source = String(
            bytes: UnsafeRawBufferPointer(rebasing: bytes[sourceStart..<(sourceStart + sourceLength)]),
            encoding: .utf8
        ) else { return nil }

        return Header(
            width: width,
            height: height,
            region: GeoRegion(
                minLatitude: minLat, maxLatitude: maxLat,
                minLongitude: minLon, maxLongitude: maxLon
            ),
            source: source,
            sampleOffset: sampleStart
        )
    }

    /// Decodes a payload into a heap-backed grid.
    ///
    /// Still the path for anything that is not going straight to the GPU —
    /// spot readouts and profiles want an `ElevationGrid` — and the only path
    /// for `LEG1` files left over from an earlier build.
    public static func decode(_ data: Data) -> StoredGrid? {
        data.withUnsafeBytes { decode($0) }
    }

    public static func decode(_ bytes: UnsafeRawBufferPointer) -> StoredGrid? {
        guard let header = decodeHeader(bytes), let base = bytes.baseAddress else { return nil }

        let samples = [Float](unsafeUninitializedCapacity: header.sampleCount) { dst, initialized in
            if let dstBase = dst.baseAddress {
                UnsafeMutableRawPointer(dstBase).copyMemory(
                    from: base + header.sampleOffset, byteCount: header.sampleByteCount
                )
            }
            initialized = header.sampleCount
        }

        return StoredGrid(
            grid: ElevationGrid(
                width: header.width, height: header.height,
                samples: samples, region: header.region
            ),
            source: header.source
        )
    }
}
