//
//  COGByteReader.swift
//  LidarExplorer
//
//  Zero-copy(-past-decode) HTTP range reading of a Cloud Optimized GeoTIFF,
//  targeting USGS 3DEP 1 m tiled COGs directly rather than through an
//  ImageServer export.
//

import Foundation

/// Page-aligned raw memory a `MTLBuffer` can adopt with `bytesNoCopy`, so a
/// decoded tile crosses into Metal with no further copy.
///
/// Not zero-copy from the network: an LZW-compressed tile has to be
/// materialised somewhere by the time it is decompressed. This is where that
/// one copy lands, so everything downstream of it -- the Metal buffer, the
/// render kernel -- touches it without another.
public nonisolated final class COGMappedStorage: @unchecked Sendable {
    public let pointer: UnsafeMutableRawPointer
    public let length: Int

    /// `length` is rounded up to a whole page; `Metal.makeBuffer(bytesNoCopy:)`
    /// requires the base pointer (not just an internal offset) to land on one.
    /// Failable rather than a force-unwrapped `posix_memalign` result: an
    /// allocation failure here should hand the caller `nil`, not crash it.
    public init?(length: Int) {
        guard length > 0 else { return nil }
        let pageSize = Int(getpagesize())
        self.length = (length + pageSize - 1) / pageSize * pageSize
        var raw: UnsafeMutableRawPointer?
        guard posix_memalign(&raw, pageSize, self.length) == 0, let raw else { return nil }
        self.pointer = raw
    }

    deinit { free(pointer) }
}

/// Errors surfaced by ``COGByteReader``.
public nonisolated enum COGError: Error, Sendable {
    case transportFailure(String)
    case malformedHeader(String)
    /// A real TIFF feature this reader does not implement -- BigTIFF,
    /// striped (non-tiled) layout, an unsupported compression or sample
    /// format. Distinct from a malformed file: the input is valid TIFF, just
    /// outside this reader's deliberately narrow scope.
    case unsupportedLayout(String)
    case decodeFailure(String)
}

/// Reads one Cloud Optimized GeoTIFF over HTTP range requests, fetching only
/// the header/IFD and the specific tiles a caller asks for.
///
/// Scope: classic (non-BigTIFF) TIFF, tiled (not striped) layout, Float32
/// samples, uncompressed or LZW-with-floating-point-predictor compression --
/// which is what USGS 3DEP ships its 1 m COGs as. It does not attempt to be a
/// general TIFF reader; ``FloatTIFFDecoder`` already covers the ImageServer's
/// uncompressed strips.
public actor COGByteReader {
    public struct Header: Sendable {
        public let width: Int
        public let height: Int
        public let tileWidth: Int
        public let tileLength: Int
        public let compression: Int
        public let predictor: Int
        public let sampleFormat: Int
        public let bitsPerSample: Int
        public let littleEndian: Bool
        public let tileOffsets: [UInt64]
        public let tileByteCounts: [UInt32]
        /// (x, y, z) ground units per pixel.
        public let modelPixelScale: (x: Double, y: Double, z: Double)
        /// Raster (i, j, k) -> model (x, y, z); i/j are always 0 in a COG.
        public let modelTiepoint: (x: Double, y: Double)
        public let noDataValue: Float?
        /// `ProjectedCSTypeGeoKey`, when the file declares one inline.
        public let epsgCode: Int?

        public var tilesAcross: Int { (width + tileWidth - 1) / tileWidth }
        public var tilesDown: Int { (height + tileLength - 1) / tileLength }

        func tileIndex(col: Int, row: Int) -> Int? {
            guard col >= 0, row >= 0, col < tilesAcross, row < tilesDown else { return nil }
            return row * tilesAcross + col
        }
    }

    private static let typeSize: [Int: Int] = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8]
    private static let initialRangeBytes = 16_384

    private let url: URL
    private let transport: HTTPTransport
    private var cachedHeader: Header?

    public init(url: URL, transport: HTTPTransport = .shared) {
        self.url = url
        self.transport = transport
    }

    /// Parses (and caches) the file's TIFF header, first IFD, and the tags a
    /// COG reader needs. Issues one HTTP range request in the common case;
    /// a second, only if this file's tag data does not fit the first.
    public func header() async throws -> Header {
        if let cachedHeader { return cachedHeader }
        let parsed = try await loadHeader()
        cachedHeader = parsed
        return parsed
    }

    /// Fetches, decompresses, and un-predicts one tile, landing the decoded
    /// `Float32` samples in page-aligned memory ready for `ElevationSamples.mapped`.
    public func fetchTile(_ tileIndex: Int) async throws -> (storage: COGMappedStorage, width: Int, height: Int) {
        let h = try await header()
        guard tileIndex >= 0, tileIndex < h.tileOffsets.count else {
            throw COGError.unsupportedLayout("tile index \(tileIndex) out of range")
        }
        guard h.sampleFormat == 3, h.bitsPerSample == 32 else {
            throw COGError.unsupportedLayout("expected Float32 samples, got format \(h.sampleFormat)/\(h.bitsPerSample)-bit")
        }
        guard h.compression == 1 || h.compression == 5 else {
            throw COGError.unsupportedLayout("unsupported compression \(h.compression)")
        }

        let offset = Int(h.tileOffsets[tileIndex])
        let byteCount = Int(h.tileByteCounts[tileIndex])
        guard byteCount > 0 else {
            throw COGError.malformedHeader("tile \(tileIndex) has zero byte count")
        }
        let compressed = try await rangeGet(offset..<(offset + byteCount))

        let expectedRaw = h.tileWidth * h.tileLength * 4
        let raw: [UInt8]
        switch h.compression {
        case 1:
            guard compressed.count >= expectedRaw else {
                throw COGError.decodeFailure("uncompressed tile \(tileIndex) short by \(expectedRaw - compressed.count) bytes")
            }
            raw = compressed
        default:
            guard let decoded = TIFFLZWDecoder.decode(compressed, expectedByteCount: expectedRaw) else {
                throw COGError.decodeFailure("LZW decode failed for tile \(tileIndex)")
            }
            raw = decoded
        }

        let unpredicted = h.predictor == 3
            ? TIFFFloatingPointPredictor.decode(
                raw, width: h.tileWidth, height: h.tileLength, littleEndian: h.littleEndian)
            : raw

        guard let storage = COGMappedStorage(length: expectedRaw) else {
            throw COGError.decodeFailure("could not allocate \(expectedRaw) bytes for tile \(tileIndex)")
        }
        let noData = h.noDataValue
        unpredicted.withUnsafeBufferPointer { src in
            let floats = storage.pointer.bindMemory(to: Float.self, capacity: h.tileWidth * h.tileLength)
            src.withMemoryRebound(to: Float.self) { floatSrc in
                for i in 0..<(h.tileWidth * h.tileLength) {
                    let v = floatSrc[i]
                    floats[i] = (v.isNaN || v == noData) ? .nan : v
                }
            }
        }
        return (storage, h.tileWidth, h.tileLength)
    }

    /// The pixel-space column/row range a geographic region covers, using the
    /// file's own tiepoint/pixel-scale and, when the CRS is a UTM zone this
    /// reader recognises, ``UTMProjection``. Returns `nil` for any other CRS.
    public func pixelRange(covering region: GeoRegion) async throws -> (cols: Range<Int>, rows: Range<Int>)? {
        let h = try await header()
        guard let epsg = h.epsgCode, let (zone, hemisphere) = UTMProjection.zone(forEPSG: epsg) else { return nil }

        let corners = [
            (region.minLatitude, region.minLongitude), (region.minLatitude, region.maxLongitude),
            (region.maxLatitude, region.minLongitude), (region.maxLatitude, region.maxLongitude),
        ].map { UTMProjection.forward(latitude: $0.0, longitude: $0.1, zone: zone, hemisphere: hemisphere) }

        let minEasting = corners.map(\.easting).min()!
        let maxEasting = corners.map(\.easting).max()!
        let minNorthing = corners.map(\.northing).min()!
        let maxNorthing = corners.map(\.northing).max()!

        // PixelIsArea (USGS 3DEP's convention): the tiepoint is pixel (0,0)'s
        // upper-left corner, so column grows with easting and row grows as
        // northing falls, both scaled by the pixel size.
        let scaleX = max(h.modelPixelScale.x, 1e-9)
        let scaleY = max(h.modelPixelScale.y, 1e-9)
        let colStart = Int(((minEasting - h.modelTiepoint.x) / scaleX).rounded(.down))
        let colEnd = Int(((maxEasting - h.modelTiepoint.x) / scaleX).rounded(.up))
        let rowStart = Int(((h.modelTiepoint.y - maxNorthing) / scaleY).rounded(.down))
        let rowEnd = Int(((h.modelTiepoint.y - minNorthing) / scaleY).rounded(.up))

        let cols = max(0, colStart)..<min(h.width, max(colStart + 1, colEnd))
        let rows = max(0, rowStart)..<min(h.height, max(rowStart + 1, rowEnd))
        guard cols.lowerBound < cols.upperBound, rows.lowerBound < rows.upperBound else { return nil }
        return (cols, rows)
    }

    /// The geographic extent one tile covers, for building the `GeoRegion` a
    /// decoded tile's `ElevationGrid` should carry.
    public func tileRegion(col: Int, row: Int) async throws -> GeoRegion? {
        let h = try await header()
        guard let epsg = h.epsgCode, let (zone, hemisphere) = UTMProjection.zone(forEPSG: epsg) else { return nil }
        let minEasting = h.modelTiepoint.x + Double(col * h.tileWidth) * h.modelPixelScale.x
        let maxEasting = minEasting + Double(h.tileWidth) * h.modelPixelScale.x
        let maxNorthing = h.modelTiepoint.y - Double(row * h.tileLength) * h.modelPixelScale.y
        let minNorthing = maxNorthing - Double(h.tileLength) * h.modelPixelScale.y

        let sw = UTMProjection.inverse(easting: minEasting, northing: minNorthing, zone: zone, hemisphere: hemisphere)
        let ne = UTMProjection.inverse(easting: maxEasting, northing: maxNorthing, zone: zone, hemisphere: hemisphere)
        return GeoRegion(
            minLatitude: sw.latitude, maxLatitude: ne.latitude,
            minLongitude: sw.longitude, maxLongitude: ne.longitude
        )
    }

    // MARK: - Byte-range fetch and header parsing

    private func rangeGet(_ range: Range<Int>) async throws -> [UInt8] {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        switch await transport.data(for: request) {
        case .success(let data): return [UInt8](data)
        case .failure(let error): throw COGError.transportFailure(error.description)
        }
    }

    /// Returns `buffer` unchanged if it already reaches `end`, or replaces it
    /// with a fresh fetch covering `0..<end` otherwise.
    ///
    /// A real (not nested-closure) actor method taking and returning the
    /// buffer by value: a local `async` function that mutates a captured
    /// `var` is inferred `@concurrent` under `NonisolatedNonsendingByDefault`,
    /// which the compiler then flags as an unsafe send of non-`Sendable`
    /// state -- threading the buffer explicitly sidesteps the question rather
    /// than fighting the inference.
    private func extend(_ buffer: [UInt8], upTo end: Int) async throws -> [UInt8] {
        guard end > buffer.count else { return buffer }
        return try await rangeGet(0..<end)
    }

    private struct TagEntry { let type: Int; let count: Int; let fieldOffset: Int }

    private func dataOffset(_ e: TagEntry, buffer: [UInt8], littleEndian: Bool) -> Int {
        let total = (Self.typeSize[e.type] ?? 1) * e.count
        return total <= 4 ? e.fieldOffset : tiffU32(buffer, e.fieldOffset, littleEndian: littleEndian)
    }

    private func scalarTag(_ tag: Int, entries: [Int: TagEntry], buffer: [UInt8], littleEndian: Bool) throws -> Int {
        guard let e = entries[tag] else { throw COGError.malformedHeader("missing tag \(tag)") }
        switch e.type {
        case 3: return tiffU16(buffer, e.fieldOffset, littleEndian: littleEndian)
        case 4: return tiffU32(buffer, e.fieldOffset, littleEndian: littleEndian)
        default: throw COGError.malformedHeader("tag \(tag) has unexpected type \(e.type)")
        }
    }

    private func uintArrayTag(
        _ tag: Int, entries: [Int: TagEntry], buffer: [UInt8], littleEndian: Bool
    ) async throws -> (values: [UInt64], buffer: [UInt8]) {
        guard let e = entries[tag] else { throw COGError.malformedHeader("missing tag \(tag)") }
        let unit = Self.typeSize[e.type] ?? 4
        let offset = dataOffset(e, buffer: buffer, littleEndian: littleEndian)
        let extended = try await extend(buffer, upTo: offset + unit * e.count)
        let values: [UInt64] = (0..<e.count).map { i in
            let o = offset + i * unit
            return e.type == 3
                ? UInt64(tiffU16(extended, o, littleEndian: littleEndian))
                : UInt64(tiffU32(extended, o, littleEndian: littleEndian))
        }
        return (values, extended)
    }

    private func doubleArrayTag(
        _ tag: Int, entries: [Int: TagEntry], buffer: [UInt8], littleEndian: Bool
    ) async throws -> (values: [Double]?, buffer: [UInt8]) {
        guard let e = entries[tag], e.type == 12 else { return (nil, buffer) }
        let offset = dataOffset(e, buffer: buffer, littleEndian: littleEndian)
        let extended = try await extend(buffer, upTo: offset + 8 * e.count)
        let values = (0..<e.count).map { tiffF64(extended, offset + $0 * 8, littleEndian: littleEndian) }
        return (values, extended)
    }

    private func asciiTag(
        _ tag: Int, entries: [Int: TagEntry], buffer: [UInt8], littleEndian: Bool
    ) async throws -> (value: String?, buffer: [UInt8]) {
        guard let e = entries[tag], e.type == 2, e.count > 0 else { return (nil, buffer) }
        let offset = dataOffset(e, buffer: buffer, littleEndian: littleEndian)
        let extended = try await extend(buffer, upTo: offset + e.count)
        let bytes = extended[offset..<(offset + e.count)].prefix { $0 != 0 }
        return (String(bytes: bytes, encoding: .ascii), extended)
    }

    /// `ProjectedCSTypeGeoKey` (3072) out of the GeoKey directory (34735),
    /// when it carries a plain inline EPSG code (`tiffTagLoc == 0`) -- the
    /// only form USGS 3DEP's UTM-projected COGs use.
    private func geoKeyEPSGTag(
        entries: [Int: TagEntry], buffer: [UInt8], littleEndian: Bool
    ) async throws -> (value: Int?, buffer: [UInt8]) {
        guard let e = entries[34735], e.type == 3 else { return (nil, buffer) }
        let offset = dataOffset(e, buffer: buffer, littleEndian: littleEndian)
        let extended = try await extend(buffer, upTo: offset + 2 * e.count)
        let keys = (0..<e.count).map { tiffU16(extended, offset + $0 * 2, littleEndian: littleEndian) }
        guard keys.count >= 4 else { return (nil, extended) }
        let numKeys = keys[3]
        for i in 0..<numKeys {
            let base = 4 + i * 4
            guard base + 3 < keys.count else { break }
            if keys[base] == 3072, keys[base + 1] == 0, keys[base + 2] == 1 {
                return (keys[base + 3], extended)
            }
        }
        return (nil, extended)
    }

    private func loadHeader() async throws -> Header {
        var buffer = try await rangeGet(0..<Self.initialRangeBytes)
        guard buffer.count >= 8 else { throw COGError.malformedHeader("truncated header") }

        let littleEndian: Bool
        if buffer[0] == 0x49, buffer[1] == 0x49 { littleEndian = true }
        else if buffer[0] == 0x4D, buffer[1] == 0x4D { littleEndian = false }
        else { throw COGError.malformedHeader("bad byte-order mark") }

        let magic = tiffU16(buffer, 2, littleEndian: littleEndian)
        guard magic == 42 else {
            throw COGError.unsupportedLayout("not classic TIFF (magic \(magic)); BigTIFF is unsupported")
        }
        let ifdOffset = tiffU32(buffer, 4, littleEndian: littleEndian)

        buffer = try await extend(buffer, upTo: ifdOffset + 2)
        let entryCount = tiffU16(buffer, ifdOffset, littleEndian: littleEndian)
        buffer = try await extend(buffer, upTo: ifdOffset + 2 + entryCount * 12 + 4)

        var entries: [Int: TagEntry] = [:]
        for i in 0..<entryCount {
            let e = ifdOffset + 2 + i * 12
            entries[tiffU16(buffer, e, littleEndian: littleEndian)] = TagEntry(
                type: tiffU16(buffer, e + 2, littleEndian: littleEndian),
                count: tiffU32(buffer, e + 4, littleEndian: littleEndian),
                fieldOffset: e + 8
            )
        }

        func scalar(_ tag: Int) throws -> Int {
            try scalarTag(tag, entries: entries, buffer: buffer, littleEndian: littleEndian)
        }
        func scalarOrDefault(_ tag: Int, _ fallback: Int) -> Int { (try? scalar(tag)) ?? fallback }

        guard scalarOrDefault(322, 0) > 0, scalarOrDefault(323, 0) > 0 else {
            throw COGError.unsupportedLayout("striped (non-tiled) layout is unsupported")
        }

        let (tileOffsets, buffer1) = try await uintArrayTag(324, entries: entries, buffer: buffer, littleEndian: littleEndian)
        buffer = buffer1
        let (tileByteCountsRaw, buffer2) = try await uintArrayTag(325, entries: entries, buffer: buffer, littleEndian: littleEndian)
        buffer = buffer2
        let tileByteCounts = tileByteCountsRaw.map { UInt32(truncatingIfNeeded: $0) }

        let (pixelScale, buffer3) = try await doubleArrayTag(33550, entries: entries, buffer: buffer, littleEndian: littleEndian)
        buffer = buffer3
        guard let pixelScale, pixelScale.count >= 2 else { throw COGError.malformedHeader("missing ModelPixelScale") }

        let (tiepoint, buffer4) = try await doubleArrayTag(33922, entries: entries, buffer: buffer, littleEndian: littleEndian)
        buffer = buffer4
        guard let tiepoint, tiepoint.count >= 6 else { throw COGError.malformedHeader("missing ModelTiepoint") }

        let (noDataString, buffer5) = try await asciiTag(42113, entries: entries, buffer: buffer, littleEndian: littleEndian)
        buffer = buffer5
        let noDataValue = noDataString.flatMap { Float($0) }

        let (epsgCode, buffer6) = try await geoKeyEPSGTag(entries: entries, buffer: buffer, littleEndian: littleEndian)
        buffer = buffer6

        return Header(
            width: try scalar(256),
            height: try scalar(257),
            tileWidth: try scalar(322),
            tileLength: try scalar(323),
            compression: scalarOrDefault(259, 1),
            predictor: scalarOrDefault(317, 1),
            sampleFormat: scalarOrDefault(339, 1),
            bitsPerSample: scalarOrDefault(258, 32),
            littleEndian: littleEndian,
            tileOffsets: tileOffsets,
            tileByteCounts: tileByteCounts,
            modelPixelScale: (pixelScale[0], pixelScale[1], pixelScale.count > 2 ? pixelScale[2] : 0),
            modelTiepoint: (tiepoint[3], tiepoint[4]),
            noDataValue: noDataValue,
            epsgCode: epsgCode
        )
    }
}

// MARK: - Pure byte-order-aware readers (no captured state, safe from any context)

private nonisolated func tiffU16(_ b: [UInt8], _ o: Int, littleEndian: Bool) -> Int {
    littleEndian ? Int(b[o]) | Int(b[o + 1]) << 8 : Int(b[o]) << 8 | Int(b[o + 1])
}

private nonisolated func tiffU32(_ b: [UInt8], _ o: Int, littleEndian: Bool) -> Int {
    littleEndian
        ? Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
        : Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
}

private nonisolated func tiffF64(_ b: [UInt8], _ o: Int, littleEndian: Bool) -> Double {
    var bits: UInt64 = 0
    if littleEndian {
        for i in (0..<8).reversed() { bits = (bits << 8) | UInt64(b[o + i]) }
    } else {
        for i in 0..<8 { bits = (bits << 8) | UInt64(b[o + i]) }
    }
    return Double(bitPattern: bits)
}
