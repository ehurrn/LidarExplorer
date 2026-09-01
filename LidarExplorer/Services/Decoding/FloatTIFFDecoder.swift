//
//  FloatTIFFDecoder.swift
//  LidarExplorer
//
//  Minimal, bounds-checked baseline TIFF reader for scientific rasters.
//

import Foundation
import os

/// Decodes uncompressed baseline TIFF rasters into `Float` samples.
///
/// Scope is deliberately narrow: single-band, uncompressed, strip-organised
/// TIFFs as produced by ArcGIS ImageServer and Sentinel Hub when asked for
/// `FLOAT32`. It does not attempt to be a general TIFF library.
///
/// It replaces a three-stage guess-and-check chain — a hand-rolled parser,
/// then ImageIO, then a brute-force scan of the bytes for anything that
/// looked like a plausible float. That last stage in particular could
/// "succeed" on a no-data response and hand back garbage that passed a range
/// check, which is exactly the sort of silent fabrication this rewrite exists
/// to eliminate. Here, a raster that cannot be decoded returns `nil`.
public nonisolated enum FloatTIFFDecoder {

    public struct Raster: Sendable, Equatable {
        public let width: Int
        public let height: Int
        /// Row-major samples. Length is `width * height`.
        public let samples: [Float]
    }

    public enum DecodeError: Error, Sendable, Equatable {
        case tooShort
        case badMagic
        case unsupported(String)
        case truncated(String)

        public var description: String {
            switch self {
            case .tooShort: "file shorter than a TIFF header"
            case .badMagic: "not a TIFF (bad byte order or magic)"
            case .unsupported(let what): "unsupported TIFF: \(what)"
            case .truncated(let what): "truncated TIFF: \(what)"
            }
        }
    }

    // Baseline tag numbers used here.
    private enum Tag: UInt16 {
        case imageWidth = 256
        case imageLength = 257
        case bitsPerSample = 258
        case compression = 259
        case stripOffsets = 273
        case samplesPerPixel = 277
        case rowsPerStrip = 278
        case stripByteCounts = 279
        case sampleFormat = 339
    }

    /// Decodes `data`, or throws describing precisely why it could not.
    public static func decode(_ data: Data) throws -> Raster {
        guard data.count >= 8 else { throw DecodeError.tooShort }

        let bytes = [UInt8](data)

        // Byte order marker, then the constant 42.
        let littleEndian: Bool
        switch (bytes[0], bytes[1]) {
        case (0x49, 0x49): littleEndian = true   // "II"
        case (0x4D, 0x4D): littleEndian = false  // "MM"
        default: throw DecodeError.badMagic
        }

        let reader = ByteReader(bytes: bytes, littleEndian: littleEndian)
        guard try reader.uint16(at: 2) == 42 else { throw DecodeError.badMagic }

        let ifdOffset = Int(try reader.uint32(at: 4))
        guard ifdOffset > 0, ifdOffset + 2 <= bytes.count else {
            throw DecodeError.truncated("IFD offset \(ifdOffset) past end")
        }

        let entryCount = Int(try reader.uint16(at: ifdOffset))
        // Each IFD entry is 12 bytes; the directory ends with a 4-byte next-offset.
        guard ifdOffset + 2 + entryCount * 12 + 4 <= bytes.count else {
            throw DecodeError.truncated("IFD with \(entryCount) entries past end")
        }

        var tags: [UInt16: [UInt32]] = [:]
        for i in 0..<entryCount {
            let entry = ifdOffset + 2 + i * 12
            let tag = try reader.uint16(at: entry)
            let type = try reader.uint16(at: entry + 2)
            let count = Int(try reader.uint32(at: entry + 4))
            tags[tag] = try reader.values(
                atEntryValueField: entry + 8, type: type, count: count
            )
        }

        func scalar(_ tag: Tag, default fallback: UInt32? = nil) throws -> UInt32 {
            if let v = tags[tag.rawValue]?.first { return v }
            if let fallback { return fallback }
            throw DecodeError.unsupported("missing tag \(tag)")
        }

        let width = Int(try scalar(.imageWidth))
        let height = Int(try scalar(.imageLength))
        let samplesPerPixel = Int(try scalar(.samplesPerPixel, default: 1))
        let compression = try scalar(.compression, default: 1)
        let bitsPerSample = try scalar(.bitsPerSample, default: 32)
        // SampleFormat 1 = unsigned int, 2 = signed int, 3 = IEEE float.
        let sampleFormat = try scalar(.sampleFormat, default: 1)

        guard width > 0, height > 0 else {
            throw DecodeError.unsupported("zero-sized image \(width)x\(height)")
        }
        guard compression == 1 else {
            throw DecodeError.unsupported("compression \(compression); only uncompressed is handled")
        }
        guard samplesPerPixel == 1 else {
            throw DecodeError.unsupported("\(samplesPerPixel) samples per pixel; only single-band is handled")
        }

        let bytesPerSample = Int(bitsPerSample) / 8
        guard bytesPerSample > 0, [1, 2, 4, 8].contains(bytesPerSample) else {
            throw DecodeError.unsupported("\(bitsPerSample) bits per sample")
        }

        guard let stripOffsets = tags[Tag.stripOffsets.rawValue], !stripOffsets.isEmpty else {
            throw DecodeError.unsupported("no strip offsets")
        }
        let rowsPerStrip = Int(try scalar(.rowsPerStrip, default: UInt32(height)))
        guard rowsPerStrip > 0 else { throw DecodeError.unsupported("rowsPerStrip 0") }
        let stripByteCounts = tags[Tag.stripByteCounts.rawValue]

        var samples = [Float]()
        samples.reserveCapacity(width * height)

        for (stripIndex, offset32) in stripOffsets.enumerated() {
            let offset = Int(offset32)
            let rowsInStrip = min(rowsPerStrip, height - stripIndex * rowsPerStrip)
            guard rowsInStrip > 0 else { break }

            let expected = rowsInStrip * width * bytesPerSample
            let available = stripByteCounts.map { Int($0[min(stripIndex, $0.count - 1)]) } ?? expected
            let length = min(expected, available)

            guard offset >= 0, offset + length <= bytes.count else {
                throw DecodeError.truncated(
                    "strip \(stripIndex) wants bytes \(offset)..<\(offset + length) of \(bytes.count)"
                )
            }

            let sampleCount = length / bytesPerSample
            for s in 0..<sampleCount {
                let at = offset + s * bytesPerSample
                samples.append(
                    try reader.sample(
                        at: at, bytesPerSample: bytesPerSample, sampleFormat: sampleFormat
                    )
                )
            }
        }

        guard samples.count >= width * height else {
            throw DecodeError.truncated(
                "decoded \(samples.count) samples, need \(width * height)"
            )
        }
        if samples.count > width * height {
            samples.removeLast(samples.count - width * height)
        }

        return Raster(width: width, height: height, samples: samples)
    }

    // MARK: - Byte access

    /// Bounds-checked, endian-aware reads over a byte array.
    private struct ByteReader {
        let bytes: [UInt8]
        let littleEndian: Bool

        func uint16(at index: Int) throws -> UInt16 {
            guard index >= 0, index + 2 <= bytes.count else {
                throw DecodeError.truncated("uint16 at \(index)")
            }
            let a = UInt16(bytes[index]), b = UInt16(bytes[index + 1])
            return littleEndian ? (b << 8) | a : (a << 8) | b
        }

        func uint32(at index: Int) throws -> UInt32 {
            guard index >= 0, index + 4 <= bytes.count else {
                throw DecodeError.truncated("uint32 at \(index)")
            }
            let b = (0..<4).map { UInt32(bytes[index + $0]) }
            return littleEndian
                ? (b[3] << 24) | (b[2] << 16) | (b[1] << 8) | b[0]
                : (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]
        }

        /// Reads one raster sample and widens it to `Float`.
        func sample(at index: Int, bytesPerSample: Int, sampleFormat: UInt32) throws -> Float {
            switch (bytesPerSample, sampleFormat) {
            case (4, 3):
                return Float(bitPattern: try uint32(at: index))
            case (8, 3):
                // Double-precision samples, narrowed. Elevation never needs
                // the extra range, and the grid stores Float regardless.
                let lo = UInt64(try uint32(at: index))
                let hi = UInt64(try uint32(at: index + 4))
                let bits = littleEndian ? (hi << 32) | lo : (lo << 32) | hi
                return Float(Double(bitPattern: bits))
            case (2, 2):
                return Float(Int16(bitPattern: try uint16(at: index)))
            case (2, _):
                return Float(try uint16(at: index))
            case (4, 2):
                return Float(Int32(bitPattern: try uint32(at: index)))
            case (4, _):
                return Float(try uint32(at: index))
            case (1, _):
                guard index < bytes.count else {
                    throw DecodeError.truncated("uint8 at \(index)")
                }
                return Float(bytes[index])
            default:
                throw DecodeError.unsupported(
                    "\(bytesPerSample * 8)-bit sample format \(sampleFormat)"
                )
            }
        }

        /// Reads an IFD entry's values, following the offset when the payload
        /// does not fit in the entry's inline 4-byte field.
        func values(atEntryValueField field: Int, type: UInt16, count: Int) throws -> [UInt32] {
            let elementSize: Int
            switch type {
            case 1, 2, 6, 7: elementSize = 1   // BYTE, ASCII, SBYTE, UNDEFINED
            case 3, 8: elementSize = 2         // SHORT, SSHORT
            case 4, 9, 11: elementSize = 4     // LONG, SLONG, FLOAT
            case 5, 10, 12: elementSize = 8    // RATIONAL, SRATIONAL, DOUBLE
            default: elementSize = 4
            }

            guard count >= 0, count <= 1 << 22 else {
                throw DecodeError.unsupported("implausible tag count \(count)")
            }

            let total = elementSize * count
            let base = total <= 4 ? field : Int(try uint32(at: field))

            var out: [UInt32] = []
            out.reserveCapacity(min(count, 4096))
            for i in 0..<count {
                let at = base + i * elementSize
                switch elementSize {
                case 1:
                    guard at < bytes.count else { throw DecodeError.truncated("tag byte at \(at)") }
                    out.append(UInt32(bytes[at]))
                case 2:
                    out.append(UInt32(try uint16(at: at)))
                default:
                    out.append(try uint32(at: at))
                }
                // Tag arrays here are small (strip tables); cap defensively.
                if out.count >= 65_536 { break }
            }
            return out
        }
    }
}
