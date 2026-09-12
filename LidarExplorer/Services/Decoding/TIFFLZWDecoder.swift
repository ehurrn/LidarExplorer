//
//  TIFFLZWDecoder.swift
//  LidarExplorer
//
//  LZW decompression and the floating-point horizontal predictor, the two
//  transforms a Cloud Optimized GeoTIFF's Float32 tiles are actually stored
//  under -- unlike the uncompressed strips ``FloatTIFFDecoder`` reads.
//

import Foundation

/// Decodes the TIFF variant of LZW (TIFF 6.0 Section 13).
///
/// Differs from classic GIF-LZW in two ways: codes are packed MSB-first
/// within each byte (GIF is LSB-first), and the code width grows one code
/// index *earlier* than GIF's ("early change") -- 9 bits through code 510,
/// 10 through 1022, 11 through 2046, 12 thereafter. Getting either wrong
/// desyncs the whole stream after the first multi-byte table entry, so this
/// is verified byte-for-byte against a real USGS 3DEP tile cross-checked with
/// GDAL (see the harness's "COG tile decode" section) rather than against the
/// spec text alone.
public nonisolated enum TIFFLZWDecoder {
    private static let clearCode = 256
    private static let eoiCode = 257
    private static let firstCode = 258

    /// Decodes `compressed` into exactly `expectedByteCount` bytes.
    ///
    /// Returns `nil` if the stream ends before producing that many bytes or
    /// contains a code that cannot be resolved against the table built so
    /// far -- a truncated fetch or a corrupt tile, not a bug in a well-formed
    /// encoder's output.
    public static func decode(_ compressed: [UInt8], expectedByteCount: Int) -> [UInt8]? {
        guard !compressed.isEmpty, expectedByteCount > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: expectedByteCount)
        let ok = compressed.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in decode(src, into: dst) }
        }
        return ok ? out : nil
    }

    /// Decodes `compressed` straight into `destination`, filling all of it.
    ///
    /// No table storage and no intermediate buffer. Every LZW string is the
    /// string emitted before it plus one byte, and both already sit
    /// contiguously in the output, so a table entry is just an (offset, length)
    /// into bytes this call has already written. That is what lets a COG tile
    /// decompress directly into the page-aligned memory Metal adopts.
    ///
    /// Returns `false` on a truncated or corrupt stream, leaving `destination`
    /// partially written.
    public static func decode(
        _ compressed: UnsafeRawBufferPointer, into destination: UnsafeMutableRawBufferPointer
    ) -> Bool {
        let expected = destination.count
        guard compressed.count > 0, expected > 0,
              let src = compressed.baseAddress, let dst = destination.baseAddress
        else { return false }

        let offsets = UnsafeMutablePointer<Int32>.allocate(capacity: 4096)
        let lengths = UnsafeMutablePointer<Int32>.allocate(capacity: 4096)
        defer {
            offsets.deallocate()
            lengths.deallocate()
        }

        let byteCount = compressed.count
        var bitBuffer: UInt64 = 0
        var bitCount = 0
        var byteIndex = 0

        // MSB-first codes, refilled a byte at a time.
        func nextCode(_ width: Int) -> Int? {
            while bitCount < width {
                guard byteIndex < byteCount else { return nil }
                bitBuffer = (bitBuffer << 8) | UInt64(src.load(fromByteOffset: byteIndex, as: UInt8.self))
                byteIndex += 1
                bitCount += 8
            }
            bitCount -= width
            return Int((bitBuffer >> UInt64(bitCount)) & ((1 << UInt64(width)) - 1))
        }

        var outPosition = 0
        var codeWidth = 9
        var tableCount = firstCode
        var hasPrevious = false
        var previousStart = 0
        var previousLength = 0

        while outPosition < expected {
            guard let code = nextCode(codeWidth), code != eoiCode else { break }

            if code == clearCode {
                tableCount = firstCode
                codeWidth = 9
                guard let first = nextCode(codeWidth), first < 256 else { break }
                dst.storeBytes(of: UInt8(first), toByteOffset: outPosition, as: UInt8.self)
                previousStart = outPosition
                previousLength = 1
                hasPrevious = true
                outPosition += 1
                continue
            }

            let start = outPosition
            let remaining = expected - outPosition
            let length: Int
            if code < 256 {
                dst.storeBytes(of: UInt8(code), toByteOffset: outPosition, as: UInt8.self)
                length = 1
            } else if code >= firstCode && code < tableCount {
                length = Int(lengths[code])
                (dst + outPosition).copyMemory(from: dst + Int(offsets[code]), byteCount: min(length, remaining))
            } else if hasPrevious && code == tableCount {
                // The "KwKwK" case: a code the encoder emitted before adding
                // it to its own table -- the previous string plus its own
                // first byte. The copy's source ends exactly where it starts.
                length = previousLength + 1
                (dst + outPosition).copyMemory(from: dst + previousStart, byteCount: min(previousLength, remaining))
                if previousLength < remaining {
                    let firstByte = dst.load(fromByteOffset: previousStart, as: UInt8.self)
                    dst.storeBytes(of: firstByte, toByteOffset: outPosition + previousLength, as: UInt8.self)
                }
            } else {
                return false
            }
            outPosition = min(outPosition + length, expected)

            if hasPrevious, tableCount < 4096 {
                offsets[tableCount] = Int32(previousStart)
                lengths[tableCount] = Int32(previousLength + 1)
                tableCount += 1
                switch tableCount {
                case 511 where codeWidth == 9: codeWidth = 10
                case 1023 where codeWidth == 10: codeWidth = 11
                case 2047 where codeWidth == 11: codeWidth = 12
                default: break
                }
            }
            previousStart = start
            previousLength = length
            hasPrevious = true
        }
        return outPosition >= expected
    }
}

/// Reverses TIFF Predictor 3 (floating point), TIFF Technical Note 3.
///
/// The encoder splits each row's multi-byte samples into byte planes
/// (most-significant byte first), horizontal-differences each plane across
/// the row, and concatenates the differenced planes in place of the row.
/// Decoding undoes both steps: a continuous cumulative sum across the whole
/// row (the planes are differenced as one sequence, not reset at each plane
/// boundary), then de-interleaving the planes back into samples in the
/// file's own byte order.
///
/// Verified byte-for-byte against a real USGS 3DEP tile cross-checked with
/// GDAL -- the plane order and the final byte order are two independent
/// choices a encoder can make, and only one combination round-trips.
public nonisolated enum TIFFFloatingPointPredictor {
    /// - Parameters:
    ///   - bytesPerSample: 4 for `Float32`, 8 for `Float64`.
    ///   - littleEndian: the TIFF file's own declared byte order. The
    ///     reconstructed samples are returned in this same order.
    public static func decode(
        _ bytes: [UInt8],
        width: Int,
        height: Int,
        samplesPerPixel: Int = 1,
        bytesPerSample: Int = 4,
        littleEndian: Bool = true
    ) -> [UInt8] {
        let count = width * samplesPerPixel
        let rowBytes = count * bytesPerSample
        guard rowBytes > 0, bytes.count >= rowBytes * height else { return bytes }

        var out = [UInt8](repeating: 0, count: bytes.count)
        var scratch = [UInt8](repeating: 0, count: rowBytes)

        bytes.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for row in 0..<height {
                    let rowStart = row * rowBytes
                    var accumulator: UInt8 = 0
                    for i in 0..<rowBytes {
                        accumulator = accumulator &+ src[rowStart + i]
                        scratch[i] = accumulator
                    }
                    // Plane 0 is the most-significant byte of every sample;
                    // reassemble in the file's declared byte order.
                    for plane in 0..<bytesPerSample {
                        let planeStart = plane * count
                        let byteOffset = littleEndian ? (bytesPerSample - 1 - plane) : plane
                        for i in 0..<count {
                            dst[rowStart + i * bytesPerSample + byteOffset] = scratch[planeStart + i]
                        }
                    }
                }
            }
        }
        return out
    }

    /// Reverses Predictor 3 over `buffer` in place, with one row of scratch.
    ///
    /// Same transform as ``decode(_:width:height:samplesPerPixel:bytesPerSample:littleEndian:)``,
    /// for bytes that already live where they are needed (a COG tile decoded
    /// straight into page-aligned storage). Returns `false` if `buffer` is too
    /// small for the geometry.
    @discardableResult
    public static func decodeInPlace(
        _ buffer: UnsafeMutableRawBufferPointer,
        width: Int,
        height: Int,
        samplesPerPixel: Int = 1,
        bytesPerSample: Int = 4,
        littleEndian: Bool = true
    ) -> Bool {
        let count = width * samplesPerPixel
        let rowBytes = count * bytesPerSample
        guard rowBytes > 0, buffer.count >= rowBytes * height, let base = buffer.baseAddress else { return false }
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: rowBytes, alignment: 1)
        defer { scratch.deallocate() }
        for row in 0..<height {
            let rowStart = base + row * rowBytes
            var accumulator: UInt8 = 0
            for i in 0..<rowBytes {
                accumulator = accumulator &+ rowStart.load(fromByteOffset: i, as: UInt8.self)
                scratch.storeBytes(of: accumulator, toByteOffset: i, as: UInt8.self)
            }
            for plane in 0..<bytesPerSample {
                let planeStart = plane * count
                let byteOffset = littleEndian ? (bytesPerSample - 1 - plane) : plane
                for i in 0..<count {
                    rowStart.storeBytes(
                        of: scratch.load(fromByteOffset: planeStart + i, as: UInt8.self),
                        toByteOffset: i * bytesPerSample + byteOffset, as: UInt8.self
                    )
                }
            }
        }
        return true
    }
}
