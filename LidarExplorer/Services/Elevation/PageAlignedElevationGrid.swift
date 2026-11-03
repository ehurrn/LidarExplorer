//
//  PageAlignedElevationGrid.swift
//  LidarExplorer
//
//  Where every fetched raster is born: page-aligned pages (`COGMappedStorage`, an anonymous `mmap`) that Metal adopts
//  with `makeBuffer(bytesNoCopy:)` from the tile's first shade and the CPU readers read in place. A raster that
//  reached the provider as a heap array was copied into a shared buffer at its first shade and into pages at its
//  second (the 2026-11-01 tile pipeline audit's M1); written into pages by its producer, it is never copied at all.
//

import Foundation

nonisolated extension ElevationGrid {
    /// A grid whose `width * height` samples `fill` writes into fresh pages, which start zero-filled. Nil only when the
    /// pages cannot be mapped (`width` or `height` zero, or `mmap` refusing), so a producer can fall back to the heap.
    public static func inPages(
        width: Int, height: Int, region: GeoRegion, fill: (UnsafeMutableBufferPointer<Float>) -> Void
    ) -> ElevationGrid? {
        guard width > 0, height > 0 else { return nil }
        let count = width * height
        guard let pages = COGMappedStorage(length: count * MemoryLayout<Float>.stride),
              let storage = ElevationSampleStorage(
                  base: pages.pointer, mappedLength: pages.length, sampleOffset: 0, count: count, owner: pages)
        else { return nil }
        let floats = pages.pointer.bindMemory(to: Float.self, capacity: count)
        fill(UnsafeMutableBufferPointer(start: floats, count: count))
        return ElevationGrid(width: width, height: height, storage: storage, region: region)
    }

    /// `samples` copied once into pages; the heap grid over `samples` themselves when pages cannot be mapped.
    public static func inPages(width: Int, height: Int, samples: [Float], region: GeoRegion) -> ElevationGrid {
        precondition(
            samples.count == width * height,
            "ElevationGrid buffer is \(samples.count) samples but \(width)x\(height) requires \(width * height)"
        )
        return inPages(width: width, height: height, region: region) { destination in
            samples.withUnsafeBufferPointer { _ = destination.update(fromContentsOf: $0) }
        } ?? ElevationGrid(width: width, height: height, samples: samples, region: region)
    }
}
