//
//  RasterStorageChecks.swift
//  ViewerHarness
//
//  The memory every raster producer hands to `makeBuffer(bytesNoCopy:)` (MetalTerrainPipelineActor's
//  bindElevation, RasterCompute's renderTile): page memory Metal can adopt in place, and never malloc memory.
//
//  The Simulator's Metal driver shares a no-copy buffer with its host process through xpc_shmem_create, which
//  traps ("XPC API Misuse: Attempt to pass a malloc(3)ed region to xpc_shmem_create()") on a region malloc
//  handed out, posix_memalign's included. The Mac's driver adopts the same region without complaint, so no
//  render in this harness can reproduce the trap: these checks test the allocator instead. malloc_size is 0
//  for any pointer malloc did not return, which is what an mmap'd region is.
//

import CoreLocation
import Foundation

@MainActor
func runRasterStorageChecks() async {
    print("\n=== Raster storage Metal adopts without a copy ===")
    checkCOGMappedStorage()
    checkNoCopyProducers()
    checkCOGMappedStorageFailures()
}

/// Why the region at `base` cannot be shared by the Simulator's Metal driver, or nil when it can: it came from
/// malloc. Checked at the region's start, which is where xpc_shmem_create checks it.
private func noCopyAllocatorProblem(_ base: UnsafeRawPointer) -> String? {
    let size = malloc_size(base)
    return size == 0 ? nil : "malloc_size \(size) (a malloc(3)ed region)"
}

/// Why `makeBuffer(bytesNoCopy:length:)` would refuse the region, or nil when it would not.
private func noCopyShapeProblem(_ base: UnsafeRawPointer, length: Int) -> String? {
    let page = Int(getpagesize())
    var problems: [String] = []
    if Int(bitPattern: base) % page != 0 { problems.append("base \(base) is not on a \(page)-byte page") }
    if length <= 0 || length % page != 0 { problems.append("length \(length) is not a whole number of \(page)-byte pages") }
    return problems.isEmpty ? nil : problems.joined(separator: "; ")
}

/// The region a raster's samples would hand to `makeBuffer(bytesNoCopy:)`, if they would.
private func noCopyRegion(_ raster: ElevationRaster) -> (base: UnsafeMutableRawPointer, length: Int)? {
    if case let .mapped(base, mappedLength, _, _) = raster.samples { return (base, mappedLength) }
    return nil
}

// MARK: - The storage itself

@MainActor
private func checkCOGMappedStorage() {
    print("\n--- N1. COGMappedStorage ---")
    let page = Int(getpagesize())
    // A single float, a row short of a page, exactly a page, a 256² COG tile, and the largest viewshed mosaic.
    let sizes = [4, page - 64, page, 256 * 256 * 4, 2048 * 2048 * 4]
    var allocatorProblems: [String] = [], shapeProblems: [String] = [], lengthProblems: [String] = []
    var writeProblems: [String] = []
    for size in sizes {
        guard let storage = COGMappedStorage(length: size) else {
            allocatorProblems.append("\(size): nil")
            continue
        }
        if let problem = noCopyAllocatorProblem(storage.pointer) {
            allocatorProblems.append("\(size): \(problem)")
        }
        if let problem = noCopyShapeProblem(storage.pointer, length: storage.length) {
            shapeProblems.append("\(size): \(problem)")
        }
        let rounded = (size + page - 1) / page * page
        if storage.length != rounded { lengthProblems.append("\(size): length \(storage.length), expected \(rounded)") }
        // Every byte of the reported length is the storage's own: Metal adopts all of it.
        storage.pointer.storeBytes(of: 0xA5, toByteOffset: storage.length - 1, as: UInt8.self)
        storage.pointer.storeBytes(of: 0x5A, toByteOffset: 0, as: UInt8.self)
        if storage.pointer.load(fromByteOffset: storage.length - 1, as: UInt8.self) != 0xA5
            || storage.pointer.load(as: UInt8.self) != 0x5A {
            writeProblems.append("\(size)")
        }
    }
    check("COGMappedStorage is not malloc memory, so the simulator's Metal driver can share it",
          allocatorProblems.isEmpty, allocatorProblems.joined(separator: " | "))
    check("COGMappedStorage starts on a page and spans whole pages, as makeBuffer(bytesNoCopy:) needs",
          shapeProblems.isEmpty, shapeProblems.joined(separator: " | "))
    check("COGMappedStorage reports the bytes asked for, rounded up to whole pages",
          lengthProblems.isEmpty, lengthProblems.joined(separator: " | "))
    check("every byte of a COGMappedStorage's reported length can be written and read back",
          writeProblems.isEmpty, "sizes \(writeProblems)")

    // Its pages go back when the last reference does: a tile cache churning through storages must not grow.
    let span = 5 * page
    var address: UInt = 0
    do {
        guard let storage = COGMappedStorage(length: span) else {
            check("a released COGMappedStorage gives its pages back", false, "nil storage")
            return
        }
        memset(storage.pointer, 1, span)
        address = UInt(bitPattern: storage.pointer)
    }
    // msync answers ENOMEM for a range with a page that is no longer mapped; memory malloc kept is still mapped.
    errno = 0
    let status = msync(UnsafeMutableRawPointer(bitPattern: address), span, MS_ASYNC)
    check("a released COGMappedStorage gives its pages back (unmapped, not left to malloc)",
          status == -1 && errno == ENOMEM, "msync \(status), errno \(errno)")
}

// MARK: - What the producers hand to Metal

@MainActor
private func checkNoCopyProducers() {
    print("\n--- N2. the regions each producer hands makeBuffer(bytesNoCopy:) ---")

    // The viewshed and the analytical GeoTIFF export: MercatorMosaic.raster.
    let fine = makeGrid(width: 81, height: 81, gsd: 1, base: 60)
    let layers = [TileMosaicField.Layer(grid: fine, bounds: fine.region)]
    var mosaicAllocator: [String] = [], mosaicShape: [String] = []
    for radius in [100.0, 5_000.0] {
        guard let mosaic = MercatorMosaicBuilder.build(
                center: fine.region.center, radiusMeters: radius, finestGroundSampleDistance: 1, layers: layers),
              let region = noCopyRegion(mosaic.raster)
        else {
            mosaicAllocator.append("\(Int(radius)) m: no mapped mosaic")
            continue
        }
        if let problem = noCopyAllocatorProblem(region.base) {
            mosaicAllocator.append("\(Int(radius)) m (\(mosaic.size)²): \(problem)")
        }
        if let problem = noCopyShapeProblem(region.base, length: region.length) {
            mosaicShape.append("\(Int(radius)) m (\(mosaic.size)²): \(problem)")
        }
    }
    check("the mosaic MercatorMosaicBuilder.build returns is not malloc memory, so the simulator's Metal driver "
          + "can share it (the viewshed and the analytical GeoTIFF export)",
          mosaicAllocator.isEmpty, mosaicAllocator.joined(separator: " | "))
    check("the mosaic MercatorMosaicBuilder.build returns starts on a page and spans whole pages",
          mosaicShape.isEmpty, mosaicShape.joined(separator: " | "))

    // A micro-topography tile with no pooled lease to write into.
    var analysisAllocator: [String] = [], analysisShape: [String] = []
    for (dest, margin, skirt) in [(8, 2, 4), (256, 4, 32)] {
        let padded = dest + 2 * margin
        let center = AnalysisTileSource(
            samples: [Float](repeating: 120, count: padded * padded), paddedWidth: padded, margin: margin)
        guard let built = AnalysisRasterBuilder.build(
                center: center, skirt: skirt, decimation: 1, cellSizeX: 1, cellSizeY: 1, neighbours: [:], lease: nil),
              built.lease == nil, let region = noCopyRegion(built.raster)
        else {
            analysisAllocator.append("\(dest) px: no mapped raster")
            continue
        }
        if let problem = noCopyAllocatorProblem(region.base) {
            analysisAllocator.append("\(dest) px (\(built.geometry.width)²): \(problem)")
        }
        if let problem = noCopyShapeProblem(region.base, length: region.length) {
            analysisShape.append("\(dest) px (\(built.geometry.width)²): \(problem)")
        }
    }
    check("AnalysisRasterBuilder.build's storage without a lease is not malloc memory, so the simulator's Metal "
          + "driver can share it",
          analysisAllocator.isEmpty, analysisAllocator.joined(separator: " | "))
    check("AnalysisRasterBuilder.build's storage without a lease starts on a page and spans whole pages",
          analysisShape.isEmpty, analysisShape.joined(separator: " | "))

    // The disk cache's mapped files: the other allocation that reaches both no-copy sites.
    let url = harnessTemporaryDirectory.appendingPathComponent("raster-storage-\(UUID().uuidString).bin")
    let fileBytes = 3 * Int(getpagesize()) + 100
    if (try? Data(repeating: 7, count: fileBytes).write(to: url)) != nil, let mapped = MappedFile(url: url) {
        let allocator = noCopyAllocatorProblem(mapped.base)
        let shape = noCopyShapeProblem(mapped.base, length: mapped.mappedLength)
        check("a tile disk cache MappedFile is not malloc memory, so the simulator's Metal driver can share it",
              allocator == nil, allocator ?? "")
        check("a tile disk cache MappedFile starts on a page and spans whole pages", shape == nil, shape ?? "")
    } else {
        check("a tile disk cache MappedFile maps a written file", false)
    }
    try? FileManager.default.removeItem(at: url)
}

// MARK: - Sizes it cannot map

/// Last, since at a length this close to `Int.max` rounding up to a page overflows, and an overflow traps.
@MainActor
private func checkCOGMappedStorageFailures() {
    print("\n--- N3. sizes COGMappedStorage cannot map ---")
    check("a COGMappedStorage of no bytes is nil, not an empty mapping",
          COGMappedStorage(length: 0) == nil && COGMappedStorage(length: -4) == nil)
    check("a COGMappedStorage too large to map is nil (MAP_FAILED), not a crash", COGMappedStorage(length: 1 << 60) == nil)
    check("a COGMappedStorage too large to round up to a page is nil, not an overflow trap",
          COGMappedStorage(length: Int.max - 1) == nil)
}
