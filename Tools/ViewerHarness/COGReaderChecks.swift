//
//  COGReaderChecks.swift
//  ViewerHarness
//
//  The COG byte reader against files it is handed over HTTP ranges: a well-formed tiled Float32 GeoTIFF, and the
//  files a reader of network data has to refuse without trapping (truncated, multi-band, odd tag types, mask IFDs).
//

import Foundation

// MARK: - A tiled TIFF built in memory

/// A classic little-endian TIFF with a chain of IFDs, each tiled, written the way GDAL lays a COG out: the IFD, its
/// out-of-line tag data, then its tiles.
struct TIFFFixture {
    struct Entry {
        let tag: Int
        let type: Int
        let count: Int
        let payload: [UInt8]

        static func short(_ tag: Int, _ values: [Int]) -> Entry {
            Entry(tag: tag, type: 3, count: values.count, payload: values.flatMap { le16($0) })
        }
        static func long(_ tag: Int, _ values: [Int]) -> Entry {
            Entry(tag: tag, type: 4, count: values.count, payload: values.flatMap { le32($0) })
        }
        static func byte(_ tag: Int, _ values: [Int]) -> Entry {
            Entry(tag: tag, type: 1, count: values.count, payload: values.map { UInt8($0 & 0xFF) })
        }
        static func double(_ tag: Int, _ values: [Double]) -> Entry {
            Entry(tag: tag, type: 12, count: values.count, payload: values.flatMap { le64($0.bitPattern) })
        }
        static func ascii(_ tag: Int, _ text: String) -> Entry {
            let bytes = Array(text.utf8) + [0]
            return Entry(tag: tag, type: 2, count: bytes.count, payload: bytes)
        }
    }

    struct IFD {
        var entries: [Entry]
        /// Each tile's bytes; TileOffsets and TileByteCounts are written for them unless `entries` carries its own.
        var tiles: [[UInt8]]
        /// The type TileOffsets and TileByteCounts are written as: LONG, or a byte type for a malformed file.
        var tileTableType: Int = 4
    }

    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    static func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    static func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> UInt64(8 * $0)) & 0xFF) } }

    /// The samples of a `width` x `height` Float32 tile, row-major, little-endian.
    static func tile(_ samples: [Float]) -> [UInt8] {
        samples.flatMap { le32(Int($0.bitPattern)) }
    }

    /// The whole file. IFDs are chained through their next-IFD pointers, in order.
    static func build(_ ifds: [IFD]) -> [UInt8] {
        var bytes: [UInt8] = [0x49, 0x49] + le16(42) + le32(8)
        for (index, ifd) in ifds.enumerated() {
            if bytes.count % 2 == 1 { bytes.append(0) }
            let ifdOffset = bytes.count
            var entries = ifd.entries
            if !entries.contains(where: { $0.tag == 324 }) {
                // Where the tiles will go: after the entry table and every out-of-line payload.
                let tableSize = 2 + (entries.count + 2) * 12 + 4
                var dataSize = 0
                func outOfLine(_ size: Int) -> Int { size > 4 ? (size + 1) / 2 * 2 : 0 }
                for e in entries { dataSize += outOfLine(e.payload.count) }
                let unit = ifd.tileTableType == 3 ? 2 : (ifd.tileTableType == 1 ? 1 : 4)
                dataSize += 2 * outOfLine(unit * ifd.tiles.count)
                var offsets: [Int] = [], counts: [Int] = []
                var cursor = ifdOffset + tableSize + dataSize
                for t in ifd.tiles {
                    offsets.append(cursor); counts.append(t.count)
                    cursor += (t.count + 1) / 2 * 2
                }
                func table(_ tag: Int, _ values: [Int]) -> Entry {
                    switch ifd.tileTableType {
                    case 3: return .short(tag, values)
                    case 1: return .byte(tag, values)
                    default: return .long(tag, values)
                    }
                }
                entries.append(table(324, offsets))
                entries.append(table(325, counts))
            }
            entries.sort { $0.tag < $1.tag }
            let tableSize = 2 + entries.count * 12 + 4
            var data: [UInt8] = []
            var table: [UInt8] = le16(entries.count)
            for e in entries {
                table += le16(e.tag) + le16(e.type) + le32(e.count)
                if e.payload.count <= 4 {
                    table += e.payload + [UInt8](repeating: 0, count: 4 - e.payload.count)
                } else {
                    table += le32(ifdOffset + tableSize + data.count)
                    data += e.payload
                    if data.count % 2 == 1 { data.append(0) }
                }
            }
            let tilesStart = ifdOffset + tableSize + data.count
            var tiles: [UInt8] = []
            for t in ifd.tiles {
                tiles += t
                if tiles.count % 2 == 1 { tiles.append(0) }
            }
            let next = index + 1 < ifds.count ? tilesStart + tiles.count + (tiles.count % 2) : 0
            table += le32(next)
            bytes += table + data + tiles
        }
        return bytes
    }
}

/// Serves one in-memory file to the reader's range requests, as a web server would: a range past the end is
/// clamped to the file, one starting past it is answered empty.
nonisolated final class RangeServingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var file: [UInt8] = []
    nonisolated(unsafe) static var requests: [Range<Int>] = []

    override nonisolated class func canInit(with request: URLRequest) -> Bool { true }
    override nonisolated class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override nonisolated func startLoading() {
        let file = Self.file
        var lower = 0, upper = file.count
        if let header = request.value(forHTTPHeaderField: "Range"), header.hasPrefix("bytes=") {
            let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) {
                lower = a
                upper = min(b + 1, file.count)
            }
        }
        Self.requests.append(lower..<max(lower, upper))
        let body = lower < upper ? Data(file[lower..<upper]) : Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override nonisolated func stopLoading() {}
}

// MARK: - Fixtures

private let tileSide = 4
private let noDataSentinel: Float = -32767

/// The common tags of a one-band Float32 COG, `width` x `height`, in UTM zone 15N at 1 m, with `noData` as GDAL's
/// nodata text; tiles are `tileSide` square.
private func baseEntries(width: Int, height: Int, noData: String? = String(Int(noDataSentinel))) -> [TIFFFixture.Entry] {
    var entries: [TIFFFixture.Entry] = [
        .long(256, [width]), .long(257, [height]),
        .short(258, [32]), .short(259, [1]), .short(262, [1]), .short(277, [1]),
        .short(284, [1]), .long(322, [tileSide]), .long(323, [tileSide]), .short(339, [3]),
        .double(33550, [1, 1, 0]),
        .double(33922, [0, 0, 0, 500_000, 4_280_000, 0]),
        .short(34735, [1, 1, 0, 1, 3072, 0, 1, 32615]),
    ]
    if let noData { entries.append(.ascii(42113, noData)) }
    return entries
}

/// Two tiles across, one down: the first tile's samples count up from 100, the second carries the values a reader
/// must turn into voids (the nodata sentinel, an infinity, a NaN, and -12000, 1e38 and a float's lowest value,
/// which lie outside the -11000...9000 m the app takes for an elevation).
private func wellFormedFile() -> [UInt8] {
    let first = (0..<(tileSide * tileSide)).map { Float(100 + $0) }
    var second = [Float](repeating: 120, count: tileSide * tileSide)
    second[0] = noDataSentinel
    second[1] = .infinity
    second[2] = .nan
    second[3] = -12000
    second[4] = 1e38
    second[5] = -3.4028235e38
    return TIFFFixture.build([
        TIFFFixture.IFD(entries: baseEntries(width: 2 * tileSide, height: tileSide),
                        tiles: [TIFFFixture.tile(first), TIFFFixture.tile(second)]),
    ])
}

private func reader(serving file: [UInt8]) -> COGByteReader {
    RangeServingURLProtocol.file = file
    RangeServingURLProtocol.requests = []
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RangeServingURLProtocol.self]
    let transport = HTTPTransport(session: URLSession(configuration: config))
    return COGByteReader(url: URL(string: "https://cog.test/fixture.tif")!, transport: transport)
}

private func describe(_ error: any Error) -> String {
    switch error {
    case COGError.malformedHeader(let s): "malformedHeader(\(s))"
    case COGError.unsupportedLayout(let s): "unsupportedLayout(\(s))"
    case COGError.decodeFailure(let s): "decodeFailure(\(s))"
    case COGError.transportFailure(let s): "transportFailure(\(s))"
    default: "\(error)"
    }
}

// MARK: - Checks

@MainActor
func runCOGReaderChecks() async {
    print("\n=== COG byte reader ===")
    await checkWellFormedCOG()
    await checkTruncatedCOG()
    await checkMultiBandCOG()
    await checkOddTagTypes()
    await checkMaskIFDs()
}

@MainActor
private func checkWellFormedCOG() async {
    print("\n--- Q1. a well-formed tiled Float32 COG ---")
    let cog = reader(serving: wellFormedFile())
    do {
        let h = try await cog.header()
        check("the header carries the raster's size, tiling, sample format, nodata and georeference",
              h.width == 2 * tileSide && h.height == tileSide && h.tileWidth == tileSide && h.tileLength == tileSide
                && h.compression == 1 && h.sampleFormat == 3 && h.bitsPerSample == 32 && h.littleEndian
                && h.tileOffsets.count == 2 && h.tileByteCounts == [UInt32(tileSide * tileSide * 4), UInt32(tileSide * tileSide * 4)]
                && h.noDataValue == noDataSentinel && h.epsgCode == 32615 && h.overviews.isEmpty
                && h.modelPixelScale.x == 1 && h.modelTiepoint.x == 500_000 && h.modelTiepoint.y == 4_280_000,
              "\(h.width)x\(h.height), tiles \(h.tileWidth), format \(h.sampleFormat)/\(h.bitsPerSample), nodata \(String(describing: h.noDataValue)), epsg \(String(describing: h.epsgCode)), overviews \(h.overviews.count)")
        check("the header came from a single range request where the tag data fits the first 16 KB",
              RangeServingURLProtocol.requests.count == 1, "\(RangeServingURLProtocol.requests)")

        let first = try await cog.fetchTile(0)
        let firstSamples = (0..<(tileSide * tileSide)).map { first.storage.pointer.load(fromByteOffset: $0 * 4, as: Float.self) }
        check("a tile's samples decode in order into page-aligned storage",
              first.width == tileSide && first.height == tileSide && firstSamples == (0..<(tileSide * tileSide)).map { Float(100 + $0) }
                && Int(bitPattern: first.storage.pointer) % Int(getpagesize()) == 0,
              "\(firstSamples.prefix(6))")

        let second = try await cog.fetchTile(1)
        let secondSamples = (0..<(tileSide * tileSide)).map { second.storage.pointer.load(fromByteOffset: $0 * 4, as: Float.self) }
        let voids = secondSamples.prefix(6).map(\.isNaN)
        check("the nodata sentinel, infinities, NaN and values outside -11000...9000 m all read as voids, as the coordinator's CPU normalisation has them",
              voids == [true, true, true, true, true, true] && secondSamples[6...].allSatisfy { $0 == 120 },
              "\(secondSamples.prefix(7))")

        let raw = try await cog.fetchTileStorage(1)
        check("the raw tile storage keeps the file's sentinel for the GPU's nodata pass",
              raw.storage.pointer.load(fromByteOffset: 0, as: Float.self) == noDataSentinel)

        let region = try await cog.tileRegion(col: 1, row: 0)
        let range = try await region.asyncFlatMap { try await cog.pixelRange(covering: $0) }
        check("a tile's ground region maps back onto its own columns and rows",
              range.map { $0.cols.lowerBound <= tileSide && $0.cols.upperBound >= 2 * tileSide - 1 && $0.rows == 0..<tileSide } ?? false,
              "\(String(describing: range)) for \(String(describing: region))")
    } catch {
        check("the well-formed COG parses and its tiles decode", false, describe(error))
    }
}

private extension Optional where Wrapped == GeoRegion {
    func asyncFlatMap<T>(_ transform: (GeoRegion) async throws -> T?) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}

@MainActor
private func checkTruncatedCOG() async {
    print("\n--- Q2. a file cut short ---")
    // A server that clamps a range to the file's end: the reader asks for the tile tables past the end and gets less.
    let whole = wellFormedFile()
    // The entry table ends before the out-of-line tag data: cut the file where that data begins.
    let cut = 8 + 2 + (Int(whole[8]) | Int(whole[9]) << 8) * 12 + 4
    let truncated = Array(whole.prefix(cut))
    let cog = reader(serving: truncated)
    var failedCleanly = false, detail = "parsed"
    do { _ = try await cog.header() } catch COGError.malformedHeader(let why) { failedCleanly = true; detail = why } catch { detail = describe(error) }
    check("a file that ends inside its tag data fails with a malformed-header error, not a trap",
          failedCleanly, detail)

    // A tile offset table pointing past the end of the file.
    var ifd = TIFFFixture.IFD(entries: baseEntries(width: tileSide, height: tileSide), tiles: [TIFFFixture.tile([Float](repeating: 1, count: 16))])
    ifd.entries.append(.long(324, [1 << 20]))
    ifd.entries.append(.long(325, [64]))
    let beyond = reader(serving: TIFFFixture.build([ifd]))
    var tileFailedCleanly = false
    detail = "decoded"
    do {
        _ = try await beyond.fetchTile(0)
    } catch let error as COGError {
        tileFailedCleanly = true; detail = describe(error)
    } catch { detail = describe(error) }
    check("a tile whose offset lies past the end of the file fails with a reader error, not a trap", tileFailedCleanly, detail)
}

@MainActor
private func checkMultiBandCOG() async {
    print("\n--- Q3. a three-band file ---")
    // SamplesPerPixel 3 with BitsPerSample [32, 32, 32]: the bits tag's value is then an offset to the array, which a
    // reader must not take for a bit depth.
    var entries = baseEntries(width: tileSide, height: tileSide).filter { $0.tag != 258 && $0.tag != 277 }
    entries.append(.short(258, [32, 32, 32]))
    entries.append(.short(277, [3]))
    let samples = [Float](repeating: 1, count: tileSide * tileSide * 3)
    let cog = reader(serving: TIFFFixture.build([TIFFFixture.IFD(entries: entries, tiles: [TIFFFixture.tile(samples)])]))
    var refused = false, detail = "parsed"
    do {
        let h = try await cog.header()
        detail = "parsed as \(h.bitsPerSample)-bit"
    } catch COGError.unsupportedLayout(let why) { refused = true; detail = why } catch { detail = describe(error) }
    check("a three-band file is refused as an unsupported layout at the header, its bit depth never read from an offset",
          refused, detail)
}

@MainActor
private func checkOddTagTypes() async {
    print("\n--- Q4. tag types the reader does not take ---")
    // TileOffsets and TileByteCounts as BYTE arrays: a reader that sizes the fetch by the byte type and then reads
    // 4-byte words runs past its buffer.
    let ifd = TIFFFixture.IFD(entries: baseEntries(width: 2 * tileSide, height: tileSide),
                              tiles: [TIFFFixture.tile([Float](repeating: 1, count: 16)), TIFFFixture.tile([Float](repeating: 2, count: 16))],
                              tileTableType: 1)
    let cog = reader(serving: TIFFFixture.build([ifd]))
    var refused = false, detail = "parsed"
    do {
        let h = try await cog.header()
        detail = "parsed, offsets \(h.tileOffsets)"
    } catch COGError.malformedHeader(let why) { refused = true; detail = why } catch { detail = describe(error) }
    check("a tile table of a byte type is refused as malformed rather than read past its bytes", refused, detail)

    // SHORT tile tables are legitimate for a small file and still read.
    let shorts = TIFFFixture.IFD(entries: baseEntries(width: tileSide, height: tileSide),
                                 tiles: [TIFFFixture.tile([Float](repeating: 7, count: 16))], tileTableType: 3)
    let small = reader(serving: TIFFFixture.build([shorts]))
    var shortRead = false
    do {
        let tile = try await small.fetchTile(0)
        shortRead = tile.storage.pointer.load(fromByteOffset: 60, as: Float.self) == 7
    } catch { detail = describe(error) }
    check("a SHORT tile table is read", shortRead, detail)
}

@MainActor
private func checkMaskIFDs() async {
    print("\n--- Q5. mask IFDs in the overview chain ---")
    // GDAL writes an internal mask as an IFD with NewSubfileType bit 2 set (4 for the full mask, 5 for a reduced
    // one), 1 bit a sample. Chained between the image and its overview, it is no overview, and selected as one it
    // would fail to decode.
    let full = TIFFFixture.IFD(entries: baseEntries(width: 2 * tileSide, height: tileSide),
                               tiles: [TIFFFixture.tile([Float](repeating: 1, count: 16)), TIFFFixture.tile([Float](repeating: 2, count: 16))])
    var maskEntries: [TIFFFixture.Entry] = [
        .long(254, [4]), .long(256, [2 * tileSide]), .long(257, [tileSide]), .short(258, [1]), .short(259, [1]),
        .short(262, [4]), .short(277, [1]), .long(322, [tileSide]), .long(323, [tileSide]),
    ]
    maskEntries.sort { $0.tag < $1.tag }
    let mask = TIFFFixture.IFD(entries: maskEntries, tiles: [[UInt8](repeating: 0xFF, count: 2), [UInt8](repeating: 0xFF, count: 2)])
    var overviewEntries = baseEntries(width: tileSide, height: tileSide, noData: nil).filter { $0.tag != 33550 && $0.tag != 33922 && $0.tag != 34735 }
    overviewEntries.append(.long(254, [1]))
    let overview = TIFFFixture.IFD(entries: overviewEntries, tiles: [TIFFFixture.tile([Float](repeating: 3, count: 16))])
    let reducedMaskEntries = maskEntries.map { $0.tag == 254 ? .long(254, [5]) : $0 }
    let reducedMask = TIFFFixture.IFD(entries: reducedMaskEntries, tiles: [[UInt8](repeating: 0xFF, count: 2), [UInt8](repeating: 0xFF, count: 2)])

    let cog = reader(serving: TIFFFixture.build([full, mask, overview, reducedMask]))
    do {
        let h = try await cog.header()
        check("mask IFDs are left out of the overviews, which keep the image's pixel scale scaled to their size",
              h.overviews.count == 1 && h.overviews.first?.width == tileSide && h.overviews.first?.modelPixelScale.x == 2
                && h.overviews.first?.noDataValue == noDataSentinel && h.overviews.first?.epsgCode == 32615,
              "\(h.overviews.count) overviews: \(h.overviews.map { "\($0.width)x\($0.height) at \($0.modelPixelScale.x)" })")
        let level1 = try await cog.header(forOverview: 1)
        let tile = try await cog.fetchTile(0, overviewLevel: 1)
        check("the first overview level is the half-resolution image, and its tile decodes",
              level1.width == tileSide && tile.storage.pointer.load(fromByteOffset: 0, as: Float.self) == 3)
    } catch {
        check("a COG with mask IFDs in its chain parses", false, describe(error))
    }
}
