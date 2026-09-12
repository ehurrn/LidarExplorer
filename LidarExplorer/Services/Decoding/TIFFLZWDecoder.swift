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

        var out = [UInt8]()
        out.reserveCapacity(expectedByteCount)

        var table: [[UInt8]] = (0..<256).map { [UInt8($0)] }
        table.append([])   // 256: CLEAR, never indexed
        table.append([])   // 257: EOI, never indexed

        var bitPosition = 0
        let totalBits = compressed.count * 8

        func nextCode(_ width: Int) -> Int? {
            guard bitPosition + width <= totalBits else { return nil }
            var value = 0
            for _ in 0..<width {
                let byte = compressed[bitPosition >> 3]
                let bit = (Int(byte) >> (7 - (bitPosition & 7))) & 1
                value = (value << 1) | bit
                bitPosition += 1
            }
            return value
        }

        var codeWidth = 9
        var previousCode: Int?

        while true {
            guard let code = nextCode(codeWidth), code != eoiCode else { break }

            if code == clearCode {
                table.removeLast(table.count - firstCode)
                codeWidth = 9
                guard let first = nextCode(codeWidth), first != eoiCode, first < table.count else { break }
                out.append(contentsOf: table[first])
                previousCode = first
                continue
            }

            let entry: [UInt8]
            if code < table.count {
                entry = table[code]
            } else if let previousCode, code == table.count {
                // The "KwKwK" case: a code the encoder emitted before adding
                // it to its own table, resolvable from the previous entry.
                entry = table[previousCode] + [table[previousCode][0]]
            } else {
                return nil
            }
            out.append(contentsOf: entry)

            if let previousCode {
                table.append(table[previousCode] + [entry[0]])
            }
            previousCode = code

            switch table.count {
            case 511 where codeWidth == 9: codeWidth = 10
            case 1023 where codeWidth == 10: codeWidth = 11
            case 2047 where codeWidth == 11: codeWidth = 12
            default: break
            }

            if out.count >= expectedByteCount { break }
        }

        guard out.count >= expectedByteCount else { return nil }
        if out.count > expectedByteCount { out.removeLast(out.count - expectedByteCount) }
        return out
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
}
