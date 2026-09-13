//
//  RasterCompute.swift
//  LidarExplorer
//
//  GPU-accelerated terrain rasters with a transparent CPU fallback.
//

import CoreGraphics
import Foundation
import Metal
import os

/// Terrain raster products, however they were produced.
public nonisolated struct ReliefProducts: Sendable {
    public let slopeDegrees: [Float]
    public let aspectDegrees: [Float]
    /// Per-cell standard deviation of multi-directional hillshade.
    public let multiDirectionalRelief: [Float]
    public let width: Int
    public let height: Int
    /// Which path produced these. Surfaced so callers can log and test both.
    public let backend: RasterCompute.Backend
    public let normalX: [Float]?
    public let normalY: [Float]?
    public let normalZ: [Float]?

    public init(
        slopeDegrees: [Float],
        aspectDegrees: [Float],
        multiDirectionalRelief: [Float],
        width: Int,
        height: Int,
        backend: RasterCompute.Backend,
        normalX: [Float]? = nil,
        normalY: [Float]? = nil,
        normalZ: [Float]? = nil
    ) {
        self.slopeDegrees = slopeDegrees
        self.aspectDegrees = aspectDegrees
        self.multiDirectionalRelief = multiDirectionalRelief
        self.width = width
        self.height = height
        self.backend = backend
        self.normalX = normalX
        self.normalY = normalY
        self.normalZ = normalZ
    }
}

nonisolated extension ReliefProducts {
    /// The slope and aspect rasters as a ``TerrainDerivatives``.
    ///
    /// Lets a new hillshade be produced for a different light direction
    /// without recomputing derivatives or touching the GPU again. Hillshade
    /// from cached slope and aspect is one multiply-add per pixel, so a live
    /// azimuth drag stays smooth on the CPU and avoids a buffer round trip
    /// per frame.
    public var derivatives: TerrainDerivatives {
        TerrainDerivatives(
            slopeDegrees: slopeDegrees,
            aspectDegrees: aspectDegrees,
            width: width,
            height: height,
            normalX: normalX,
            normalY: normalY,
            normalZ: normalZ
        )
    }
}

/// Where a kernel's elevation samples come from.
///
/// The two cases are the same numbers reaching the GPU by very different
/// routes. `.array` is the fetch path: the raster is already on the heap, so
/// it is copied into a shared buffer. `.mapped` is the disk path: the cache
/// file is mapped, its base is page-aligned, and Metal adopts that memory
/// directly — no allocation, no `memcpy`, and the kernel faults pages in as it
/// reads them.
public nonisolated enum ElevationSamples: @unchecked Sendable {
    case array([Float])
    /// Page-aligned memory Metal can adopt in place.
    ///
    /// - Parameters:
    ///   - base: page-aligned start of the mapping.
    ///   - mappedLength: length of the mapping, rounded up to a page.
    ///   - sampleOffset: byte offset of the `Float32` block within it.
    ///   - owner: the object whose lifetime keeps the mapping valid. Held
    ///     until the command buffer completes; dropping it earlier would
    ///     unmap memory the GPU is still reading.
    case mapped(
        base: UnsafeMutableRawPointer,
        mappedLength: Int,
        sampleOffset: Int,
        owner: AnyObject
    )
    /// A leased pooled shared buffer from MetalTerrainPipelineActor.
    case leased(SurfaceLease)
}

/// Everything the display kernel needs beyond the raster itself.
public nonisolated struct TerrainRenderRequest: Sendable, Equatable {
    public var style: ReliefStyle
    public var azimuthDegrees: Double
    public var altitudeDegrees: Double
    public var azimuthCount: Int
    public var contourIntervalMeters: Float
    /// Every Nth contour is drawn as a bolder index line. 0 or 1 disables.
    public var indexContourMultiplier: Int
    /// Screen-space width multiplier for index lines, relative to regular ones.
    public var indexContourWidth: Float
    /// Value range mapped across the palette.
    public var range: ClosedRange<Float>
    public var palette: HypsometricPalette
    /// Skirt to read across and discard, in pixels.
    public var margin: Int

    public init(
        style: ReliefStyle,
        azimuthDegrees: Double,
        altitudeDegrees: Double,
        azimuthCount: Int = 4,
        contourIntervalMeters: Float,
        indexContourMultiplier: Int = 5,
        indexContourWidth: Float = 2.0,
        range: ClosedRange<Float>,
        palette: HypsometricPalette,
        margin: Int
    ) {
        self.style = style
        self.azimuthDegrees = azimuthDegrees
        self.altitudeDegrees = altitudeDegrees
        self.azimuthCount = azimuthCount
        self.contourIntervalMeters = contourIntervalMeters
        self.indexContourMultiplier = indexContourMultiplier
        self.indexContourWidth = indexContourWidth
        self.range = range
        self.palette = palette
        self.margin = margin
    }
}

/// A shaded tile still living in the buffer the GPU wrote it into.
///
/// The point of not copying it out: `MTLBuffer` with `.storageModeShared` is
/// memory the CPU can already read, so a `CGImage` can be built over
/// `contents()` with no encode, no decode, and no second allocation. The
/// buffer stays alive as long as the image's data provider does.
///
/// `@unchecked Sendable`: `MTLBuffer` is not `Sendable`, but nothing mutates
/// this buffer after the command buffer completes, and every consumer only
/// reads it.
public nonisolated struct TerrainBitmap: @unchecked Sendable {
    public let buffer: any MTLBuffer
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int

    private static let colorSpace = CGColorSpaceCreateDeviceRGB()

    /// Wraps the buffer as a `CGImage` without copying a byte.
    ///
    /// The data provider holds the last strong reference to the buffer, so
    /// the memory outlives this struct for exactly as long as the image needs
    /// it and is released with it.
    public func makeImage() -> CGImage? {
        let retained = Unmanaged.passRetained(buffer as AnyObject).toOpaque()
        guard let provider = CGDataProvider(
            dataInfo: retained,
            data: buffer.contents(),
            size: bytesPerRow * height,
            releaseData: { info, _, _ in
                if let info { Unmanaged<AnyObject>.fromOpaque(info).release() }
            }
        ) else {
            Unmanaged<AnyObject>.fromOpaque(retained).release()
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: Self.colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

/// A read-only lease on a pooled UMA buffer.
///
/// ## The defect it fixes
///
/// The pool used to reclaim a buffer the instant its command buffer completed.
/// But completion only means the *GPU* is done — the UI and the raster
/// providers are still reading the buffer on the CPU. Handing it back then let
/// the next tile's dispatch overwrite live pixels, which is exactly the
/// concurrent-tile tearing the pool was meant to prevent.
///
/// A lease inverts the lifecycle: the buffer returns to the pool **only when
/// the last consumer drops its reference**, in ``deinit``. ARC guarantees no
/// reader is active at that point, so recycling can never race a read.
///
/// ## Why `@unchecked Sendable` is sound here
///
/// `MTLBuffer` is not `Sendable`, but this lease is safe to share because the
/// memory it wraps is *written once by the GPU before the lease exists and
/// only read thereafter*. Concurrent reads of immutable memory do not race,
/// and the single write that returns the buffer to the pool happens in
/// `deinit`, strictly after every reader is gone. The guarantee holds only
/// while a consumer *holds the lease* across its reads — a raw ``pointer``
/// outliving the lease is a use-after-free, the same contract any handle type
/// carries.
public nonisolated final class MetalBufferLease: @unchecked Sendable {
    /// The leased buffer. Read-only for the life of the lease.
    public let buffer: any MTLBuffer
    /// Number of `Float` elements the buffer holds.
    public let count: Int
    private let onDeinit: @Sendable (any MTLBuffer) -> Void

    public init(
        buffer: any MTLBuffer,
        count: Int,
        onDeinit: @escaping @Sendable (any MTLBuffer) -> Void
    ) {
        self.buffer = buffer
        self.count = count
        self.onDeinit = onDeinit
    }

    /// A typed pointer to the shared samples. Valid only while `self` is alive.
    @inlinable
    public var pointer: UnsafePointer<Float> {
        UnsafePointer(buffer.contents().bindMemory(to: Float.self, capacity: count))
    }

    @inlinable
    public subscript(index: Int) -> Float {
        assert(index >= 0 && index < count, "Index out of bounds")
        return pointer[index]
    }

    deinit { onDeinit(buffer) }
}

/// Relief products whose planes stay in the GPU buffers they were written into.
///
/// The plain ``ReliefProducts`` copies every plane out into a `[Float]`; this
/// hands back leases instead, so a consumer reads the UMA memory directly with
/// no copy-out. All members are `Sendable` (a ``MetalBufferLease`` is), so this
/// needs no `@unchecked`.
public nonisolated struct LeasedReliefProducts: Sendable {
    public let slope: MetalBufferLease
    public let aspect: MetalBufferLease
    public let relief: MetalBufferLease
    public let normalX: MetalBufferLease?
    public let normalY: MetalBufferLease?
    public let normalZ: MetalBufferLease?
    public let width: Int
    public let height: Int
    public let backend: RasterCompute.Backend
}

/// Positive and negative topographic openness, leased zero-copy from the GPU.
///
/// See ``RasterCompute/opennessProducts(for:radiusCells:)``.
public nonisolated struct OpennessProducts: Sendable {
    public let positive: MetalBufferLease
    public let negative: MetalBufferLease
    public let width: Int
    public let height: Int
}

/// Owns the Metal device and pipeline states for terrain compute.
public actor RasterCompute {
    public enum Backend: String, Sendable {
        case gpu
        case cpu
        case disk
    }

    public nonisolated static let gpuThresholdCells = 65_536
    public nonisolated static let shared = RasterCompute()

    private let device: (any MTLDevice)?
    private var queue: (any MTLCommandQueue)?
    private var fusedPipeline: (any MTLComputePipelineState)?
    private var slopeAspectPipeline: (any MTLComputePipelineState)?
    private var reliefPipeline: (any MTLComputePipelineState)?
    private var displayPipeline: (any MTLComputePipelineState)?
    private var opennessPipeline: (any MTLComputePipelineState)?
    private var rrimPipeline: (any MTLComputePipelineState)?
    private var viewshedPipeline: (any MTLComputePipelineState)?
    /// One 256-texel ramp per style-and-palette combination, built once.
    private var paletteTextures: [String: any MTLTexture] = [:]
    private var setupAttempted = false

    private struct PooledBuffers {
        let elevation: any MTLBuffer
        let slope: any MTLBuffer
        let aspect: any MTLBuffer
        let relief: any MTLBuffer
        let normalX: any MTLBuffer
        let normalY: any MTLBuffer
        let normalZ: any MTLBuffer
        let byteCount: Int
    }

    private var bufferPool: [Int: [PooledBuffers]] = [:]
    private let maxBuffersPerSize = 8

    private func obtainBuffers(device: any MTLDevice, byteCount: Int) -> PooledBuffers? {
        if var list = bufferPool[byteCount], !list.isEmpty {
            let buffer = list.removeLast()
            bufferPool[byteCount] = list
            return buffer
        }
        let options: MTLResourceOptions = .storageModeShared
        guard
            let elevation = device.makeBuffer(length: byteCount, options: options),
            let slope = device.makeBuffer(length: byteCount, options: options),
            let aspect = device.makeBuffer(length: byteCount, options: options),
            let relief = device.makeBuffer(length: byteCount, options: options),
            let normalX = device.makeBuffer(length: byteCount, options: options),
            let normalY = device.makeBuffer(length: byteCount, options: options),
            let normalZ = device.makeBuffer(length: byteCount, options: options)
        else { return nil }
        return PooledBuffers(
            elevation: elevation, slope: slope,
            aspect: aspect, relief: relief,
            normalX: normalX, normalY: normalY, normalZ: normalZ,
            byteCount: byteCount
        )
    }

    private func releaseBuffers(_ buffers: PooledBuffers) {
        var list = bufferPool[buffers.byteCount] ?? []
        if list.count < maxBuffersPerSize {
            list.append(buffers)
            bufferPool[buffers.byteCount] = list
        }
    }

    // MARK: - Individual-buffer pool for leases

    /// Free single buffers keyed by byte size, for the leased path.
    ///
    /// Separate from ``bufferPool`` because a lease's buffer has an independent
    /// lifetime — slope may be released long after aspect — so buffers must be
    /// recycled one at a time, not as a seven-buffer bundle.
    private var leaseBufferPool: [Int: [any MTLBuffer]] = [:]

    /// A buffer being handed back to the actor from a lease's `deinit`.
    ///
    /// `@unchecked Sendable` is mathematically guarded: an instance is only ever
    /// created inside ``MetalBufferLease/deinit``, i.e. after the lease's last
    /// reference is gone, so no code can be reading the buffer while it crosses
    /// the actor boundary to be recycled. Ownership is transferred, not shared.
    private struct RecycledBuffer: @unchecked Sendable {
        let buffer: any MTLBuffer
        let byteCount: Int
    }

    private func obtainLeaseBuffer(device: any MTLDevice, byteCount: Int) -> (any MTLBuffer)? {
        if var list = leaseBufferPool[byteCount], !list.isEmpty {
            let buffer = list.removeLast()
            leaseBufferPool[byteCount] = list
            return buffer
        }
        return device.makeBuffer(length: byteCount, options: .storageModeShared)
    }

    /// Returns a leased buffer to the pool. Runs only from a lease `deinit`, so
    /// the buffer has no remaining readers when this executes.
    private func recycleBuffer(_ recycled: RecycledBuffer) {
        var list = leaseBufferPool[recycled.byteCount] ?? []
        if list.count < maxBuffersPerSize {
            list.append(recycled.buffer)
            leaseBufferPool[recycled.byteCount] = list
        }
    }

    /// Wraps a checked-out buffer in a lease that recycles it on `deinit`.
    ///
    /// The `deinit` runs off the actor, so it packages the buffer into a
    /// `Sendable` transfer box and hops back onto the actor to recycle — the
    /// only Swift-6-clean way to return a non-`Sendable` `MTLBuffer` across the
    /// isolation boundary.
    private func createLease(for buffer: any MTLBuffer, count: Int) -> MetalBufferLease {
        let byteCount = buffer.length
        return MetalBufferLease(buffer: buffer, count: count) { [weak self] returnedBuffer in
            let recycled = RecycledBuffer(buffer: returnedBuffer, byteCount: byteCount)
            Task { [weak self] in await self?.recycleBuffer(recycled) }
        }
    }

    private struct Uniforms {
        var width: UInt32
        var height: UInt32
        var cellSizeX: Float
        var cellSizeY: Float
        var zenithRadians: Float
        var lightAzimuth: Float
        var azimuthCount: UInt32
        var inv8CellX: Float
        var inv8CellY: Float
        var cosZenith: Float
        var sinZenith: Float
    }

    /// Mirror of `RenderUniforms` in `TerrainKernels.metal`.
    ///
    /// Every field is a 4-byte scalar in both languages and the order matches,
    /// so the two layouts are identical without padding to reason about.
    private struct RenderUniforms {
        var paddedWidth: UInt32
        var paddedHeight: UInt32
        var destWidth: UInt32
        var destHeight: UInt32
        var margin: UInt32
        var style: UInt32
        var azimuthCount: UInt32
        var inv8CellX: Float
        var inv8CellY: Float
        var cellSizeX: Float
        var cellSizeY: Float
        var cosZenith: Float
        var sinZenith: Float
        var lightAzimuth: Float
        var contourInterval: Float
        var rangeMin: Float
        var rangeMax: Float
        var indexMultiplier: UInt32
        var indexContourWidth: Float
    }

    /// Mirror of `OpennessUniforms` in `TerrainKernels.metal`.
    private struct OpennessUniforms {
        var width: UInt32
        var height: UInt32
        var cellSizeX: Float
        var cellSizeY: Float
        var searchRadiusCells: Int32
    }

    /// Mirror of `ViewshedUniforms` in `TerrainKernels.metal`.
    private struct ViewshedUniforms {
        var width: UInt32
        var height: UInt32
        var observerGrid: SIMD2<UInt32>
        var observerEyeAltitude: Float
        var cellSizeX: Float
        var cellSizeY: Float
        var maxRadiusMeters: Float
    }

    public init() {
        self.device = MTLCreateSystemDefaultDevice()
        if device == nil {
            Log.shader.notice("No Metal device available; terrain compute will use the CPU path.")
        }
    }

    public func reliefProducts(
        for grid: ElevationGrid,
        azimuthCount: Int = 4,
        altitudeDegrees: Double = 30
    ) async -> ReliefProducts {
        let state = Signpost.raster.beginInterval("reliefProducts")
        defer { Signpost.raster.endInterval("reliefProducts", state) }

        if grid.count >= Self.gpuThresholdCells,
           let products = await gpuReliefProducts(
               grid: grid,
               azimuthCount: azimuthCount,
               altitudeDegrees: altitudeDegrees
           ) {
            return products
        }
        return cpuReliefProducts(
            grid: grid, azimuthCount: azimuthCount, altitudeDegrees: altitudeDegrees
        )
    }

    public func isGPUAvailable() -> Bool {
        prepareIfNeeded()
        return fusedPipeline != nil || (slopeAspectPipeline != nil && reliefPipeline != nil)
    }

    /// Computes relief products and hands back the GPU buffers directly, leased.
    ///
    /// The zero-copy counterpart to ``reliefProducts(for:azimuthCount:altitudeDegrees:)``:
    /// the derivative planes are never copied out into `[Float]`. Each output
    /// buffer is wrapped in a ``MetalBufferLease`` and stays checked out of the
    /// pool until its last consumer drops it, so a concurrent tile dispatch can
    /// never overwrite a buffer the UI is still reading.
    ///
    /// The one unavoidable CPU→GPU copy is the elevation upload; every read-back
    /// is eliminated. Requires the fused pipeline (it also produces normals);
    /// returns `nil` when the GPU or that pipeline is unavailable so the caller
    /// can fall back to the copying path.
    public func leasedReliefProducts(
        for grid: ElevationGrid,
        azimuthCount: Int = 4,
        altitudeDegrees: Double = 30
    ) async -> LeasedReliefProducts? {
        let state = Signpost.raster.beginInterval("leasedReliefProducts")
        defer { Signpost.raster.endInterval("leasedReliefProducts", state) }

        prepareIfNeeded()
        guard let device, let queue, let pipeline = fusedPipeline else { return nil }

        let count = grid.count
        let byteCount = count * MemoryLayout<Float>.stride
        guard count > 0,
              let elevation = obtainLeaseBuffer(device: device, byteCount: byteCount),
              let slope = obtainLeaseBuffer(device: device, byteCount: byteCount),
              let aspect = obtainLeaseBuffer(device: device, byteCount: byteCount),
              let relief = obtainLeaseBuffer(device: device, byteCount: byteCount),
              let normalX = obtainLeaseBuffer(device: device, byteCount: byteCount),
              let normalY = obtainLeaseBuffer(device: device, byteCount: byteCount),
              let normalZ = obtainLeaseBuffer(device: device, byteCount: byteCount),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        grid.withUnsafeSamples { src in
            if let base = src.baseAddress {
                elevation.contents().copyMemory(from: base, byteCount: byteCount)
            }
        }

        let cellX = Float(grid.metersPerColumn)
        let cellY = Float(grid.metersPerRow)
        let zenithRad = Float((90 - altitudeDegrees) * .pi / 180)
        var uniforms = Uniforms(
            width: UInt32(grid.width),
            height: UInt32(grid.height),
            cellSizeX: cellX,
            cellSizeY: cellY,
            zenithRadians: zenithRad,
            lightAzimuth: 0,
            azimuthCount: UInt32(max(azimuthCount, 1)),
            inv8CellX: cellX > 0 ? (1.0 / (8.0 * cellX)) : 0,
            inv8CellY: cellY > 0 ? (1.0 / (8.0 * cellY)) : 0,
            cosZenith: cos(zenithRad),
            sinZenith: sin(zenithRad)
        )

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(elevation, offset: 0, index: 0)
        encoder.setBuffer(slope, offset: 0, index: 1)
        encoder.setBuffer(aspect, offset: 0, index: 2)
        encoder.setBuffer(relief, offset: 0, index: 3)
        encoder.setBuffer(normalX, offset: 0, index: 4)
        encoder.setBuffer(normalY, offset: 0, index: 5)
        encoder.setBuffer(normalZ, offset: 0, index: 6)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 7)
        encoder.dispatchThreads(
            MTLSize(width: grid.width, height: grid.height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: min(16, max(1, grid.width)), height: min(16, max(1, grid.height)), depth: 1
            )
        )
        encoder.endEncoding()

        let error = await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { cb in continuation.resume(returning: cb.error) }
            commandBuffer.commit()
        }
        guard error == nil else {
            // Nothing was leased out, so every buffer is safe to reclaim now.
            for buffer in [elevation, slope, aspect, relief, normalX, normalY, normalZ] {
                recycleBuffer(RecycledBuffer(buffer: buffer, byteCount: byteCount))
            }
            return nil
        }

        // The elevation input has no downstream reader, so it returns to the
        // pool immediately; the six output planes leave as leases.
        recycleBuffer(RecycledBuffer(buffer: elevation, byteCount: byteCount))

        return LeasedReliefProducts(
            slope: createLease(for: slope, count: count),
            aspect: createLease(for: aspect, count: count),
            relief: createLease(for: relief, count: count),
            normalX: createLease(for: normalX, count: count),
            normalY: createLease(for: normalY, count: count),
            normalZ: createLease(for: normalZ, count: count),
            width: grid.width,
            height: grid.height,
            backend: .gpu
        )
    }

    public func isOpennessAvailable() -> Bool {
        prepareIfNeeded()
        return opennessPipeline != nil
    }

    /// Positive and negative topographic openness (Yokoyama et al. 2002),
    /// leased zero-copy from the GPU the same way ``leasedReliefProducts(for:azimuthCount:altitudeDegrees:)``
    /// leases its planes: the buffers stay checked out of the pool until the
    /// lease's last consumer drops it.
    ///
    /// `radiusCells` is the search radius, in grid cells, each of the 8 radial
    /// directions walks looking for the local horizon. Returns `nil` when the
    /// GPU or the openness pipeline is unavailable.
    public func opennessProducts(
        for grid: ElevationGrid,
        radiusCells: Int = 15
    ) async -> OpennessProducts? {
        let state = Signpost.raster.beginInterval("opennessProducts")
        defer { Signpost.raster.endInterval("opennessProducts", state) }

        prepareIfNeeded()
        guard let device, let queue, let pipeline = opennessPipeline else { return nil }

        let count = grid.count
        let byteCount = count * MemoryLayout<Float>.stride
        guard count > 0,
              let elevation = obtainLeaseBuffer(device: device, byteCount: byteCount),
              let posOpen = obtainLeaseBuffer(device: device, byteCount: byteCount),
              let negOpen = obtainLeaseBuffer(device: device, byteCount: byteCount),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        grid.withUnsafeSamples { src in
            if let base = src.baseAddress {
                elevation.contents().copyMemory(from: base, byteCount: byteCount)
            }
        }

        var uniforms = OpennessUniforms(
            width: UInt32(grid.width),
            height: UInt32(grid.height),
            cellSizeX: Float(grid.metersPerColumn),
            cellSizeY: Float(grid.metersPerRow),
            searchRadiusCells: Int32(max(radiusCells, 1))
        )

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(elevation, offset: 0, index: 0)
        encoder.setBuffer(posOpen, offset: 0, index: 1)
        encoder.setBuffer(negOpen, offset: 0, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<OpennessUniforms>.stride, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: grid.width, height: grid.height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: min(16, max(1, grid.width)), height: min(16, max(1, grid.height)), depth: 1
            )
        )
        encoder.endEncoding()

        let error = await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { cb in continuation.resume(returning: cb.error) }
            commandBuffer.commit()
        }
        guard error == nil else {
            for buffer in [elevation, posOpen, negOpen] {
                recycleBuffer(RecycledBuffer(buffer: buffer, byteCount: byteCount))
            }
            return nil
        }

        recycleBuffer(RecycledBuffer(buffer: elevation, byteCount: byteCount))

        return OpennessProducts(
            positive: createLease(for: posOpen, count: count),
            negative: createLease(for: negOpen, count: count),
            width: grid.width,
            height: grid.height
        )
    }

    public func isRRIMAvailable() -> Bool {
        prepareIfNeeded()
        return rrimPipeline != nil && fusedPipeline != nil
    }

    /// A Red Relief Image Map: slope and differential topographic openness
    /// composited into one texture, legible without any directional light.
    ///
    /// Computes slope (via the fused relief pipeline) and openness internally,
    /// so unlike ``renderTile(samples:paddedWidth:paddedHeight:metersPerColumn:metersPerRow:request:)``
    /// this takes a grid directly rather than a pre-shaded style request —
    /// RRIM has no palette or contour stage, it writes its own fixed colour
    /// mapping straight to the output texture. Returns `nil` when the GPU or
    /// either pipeline it depends on is unavailable.
    public func rrimImage(for grid: ElevationGrid, radiusCells: Int = 15) async -> TerrainBitmap? {
        let state = Signpost.raster.beginInterval("rrimImage")
        defer { Signpost.raster.endInterval("rrimImage", state) }

        prepareIfNeeded()
        guard let device, let queue, let pipeline = rrimPipeline else { return nil }

        async let leasedSlope = leasedReliefProducts(for: grid)
        async let leasedOpenness = opennessProducts(for: grid, radiusCells: radiusCells)
        guard let relief = await leasedSlope, let openness = await leasedOpenness else { return nil }

        let width = grid.width, height = grid.height
        let alignment = max(device.minimumLinearTextureAlignment(for: .rgba8Unorm), 1)
        let bytesPerRow = (width * 4 + alignment - 1) / alignment * alignment
        guard let outBuffer = device.makeBuffer(
            length: bytesPerRow * height, options: .storageModeShared
        ) else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .shared
        guard let outTexture = outBuffer.makeTexture(
            descriptor: descriptor, offset: 0, bytesPerRow: bytesPerRow
        ) else { return nil }

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        var dims = SIMD2<UInt32>(UInt32(width), UInt32(height))
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(relief.slope.buffer, offset: 0, index: 0)
        encoder.setBuffer(openness.positive.buffer, offset: 0, index: 1)
        encoder.setBuffer(openness.negative.buffer, offset: 0, index: 2)
        encoder.setBytes(&dims, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 3)
        encoder.setTexture(outTexture, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: min(16, width), height: min(16, height), depth: 1)
        )
        encoder.endEncoding()

        let error = await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { cb in continuation.resume(returning: cb.error) }
            commandBuffer.commit()
        }
        // The leases keep their buffers alive (and unrecycled) until this
        // dispatch has read them; naming them here stops the optimiser from
        // dropping the leases early.
        withExtendedLifetime((relief, openness)) {}
        guard error == nil else { return nil }

        return TerrainBitmap(buffer: outBuffer, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    public func isViewshedAvailable() -> Bool {
        prepareIfNeeded()
        return viewshedPipeline != nil
    }

    /// A radial viewshed from one observer cell: `true` at every cell within
    /// `maxRadiusMeters` that has an unobstructed line of sight to the
    /// observer's eye, `false` everywhere else (including outside the
    /// radius, and any void cell).
    ///
    /// Copies the result out to `[Bool]` rather than leasing a GPU buffer:
    /// unlike the relief planes, a viewshed is a one-shot query a UI action
    /// triggers, not something re-read every frame, so the lease machinery
    /// built for the render hot path buys nothing here.
    ///
    /// Returns `nil` when the GPU or the viewshed pipeline is unavailable, the
    /// observer cell is outside the grid, or the observer's own ground
    /// elevation is a void.
    public func viewshed(
        for grid: ElevationGrid,
        observerColumn: Int,
        observerRow: Int,
        eyeHeightMeters: Float = 1.7,
        maxRadiusMeters: Float
    ) async -> [Bool]? {
        let state = Signpost.raster.beginInterval("viewshed")
        defer { Signpost.raster.endInterval("viewshed", state) }

        guard observerColumn >= 0, observerColumn < grid.width,
              observerRow >= 0, observerRow < grid.height,
              let observerGround = grid.sample(x: observerColumn, y: observerRow)
        else { return nil }

        prepareIfNeeded()
        guard let device, let queue, let pipeline = viewshedPipeline else { return nil }

        let count = grid.count
        let byteCount = count * MemoryLayout<Float>.stride
        guard count > 0,
              let elevationBuffer = device.makeBuffer(length: byteCount, options: .storageModeShared),
              let visibilityBuffer = device.makeBuffer(length: count, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        grid.withUnsafeSamples { src in
            if let base = src.baseAddress {
                elevationBuffer.contents().copyMemory(from: base, byteCount: byteCount)
            }
        }

        var uniforms = ViewshedUniforms(
            width: UInt32(grid.width),
            height: UInt32(grid.height),
            observerGrid: SIMD2(UInt32(observerColumn), UInt32(observerRow)),
            observerEyeAltitude: observerGround + eyeHeightMeters,
            cellSizeX: Float(grid.metersPerColumn),
            cellSizeY: Float(grid.metersPerRow),
            maxRadiusMeters: max(maxRadiusMeters, 0)
        )

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(elevationBuffer, offset: 0, index: 0)
        encoder.setBuffer(visibilityBuffer, offset: 0, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<ViewshedUniforms>.stride, index: 2)
        encoder.dispatchThreads(
            MTLSize(width: grid.width, height: grid.height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: min(16, max(1, grid.width)), height: min(16, max(1, grid.height)), depth: 1
            )
        )
        encoder.endEncoding()

        let error = await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { cb in continuation.resume(returning: cb.error) }
            commandBuffer.commit()
        }
        guard error == nil else { return nil }

        let bytes = visibilityBuffer.contents().bindMemory(to: UInt8.self, capacity: count)
        return (0..<count).map { bytes[$0] != 0 }
    }

    private func prepareIfNeeded() {
        guard !setupAttempted else { return }
        setupAttempted = true
        guard let device else { return }
        guard let queue = device.makeCommandQueue() else {
            Log.shader.error("Failed to create Metal command queue.")
            return
        }
        self.queue = queue

        let library: any MTLLibrary
        do {
            if let lib = try? device.makeDefaultLibrary(bundle: .main) {
                library = lib
            } else if let lib = device.makeDefaultLibrary() {
                library = lib
            } else {
                let defaultPath = "default.metallib"
                let execDir = Bundle.main.executableURL?.deletingLastPathComponent()
                let metallibAtExec = execDir?.appendingPathComponent("default.metallib")
                if let metallibAtExec, FileManager.default.fileExists(atPath: metallibAtExec.path) {
                    library = try device.makeLibrary(URL: metallibAtExec)
                } else if FileManager.default.fileExists(atPath: defaultPath) {
                    library = try device.makeLibrary(URL: URL(fileURLWithPath: defaultPath))
                } else {
                    Log.shader.error("Metal default library not found.")
                    return
                }
            }
        } catch {
            Log.shader.error("Metal library unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }

        do {
            if let fusedFn = library.makeFunction(name: "horn_derivatives_and_relief") {
                fusedPipeline = try device.makeComputePipelineState(function: fusedFn)
            }
            // The display kernel writes into a linear texture backed by a
            // shared buffer, so the CPU can read the shaded pixels without a
            // blit. Apple GPUs support that; the iOS *simulator's* Metal does
            // not — it rejects a linear texture on any storage mode but
            // private, and does so by raising, not by returning nil, so the
            // usual "resource unavailable -> CPU path" guard cannot catch it.
            // Leaving the pipeline nil on the simulator routes tiles through
            // the CPU renderer there, which is the same fallback an older GPU
            // takes. Devices, where this actually ships and is profiled, are
            // unaffected.
            #if !targetEnvironment(simulator)
            if let displayFn = library.makeFunction(name: "terrain_surface_to_texture") {
                displayPipeline = try device.makeComputePipelineState(function: displayFn)
            }
            #endif
            if let slopeFn = library.makeFunction(name: "horn_slope_aspect"),
               let reliefFn = library.makeFunction(name: "multidirectional_relief") {
                slopeAspectPipeline = try device.makeComputePipelineState(function: slopeFn)
                reliefPipeline = try device.makeComputePipelineState(function: reliefFn)
            }
            if let opennessFn = library.makeFunction(name: "compute_topographic_openness") {
                opennessPipeline = try device.makeComputePipelineState(function: opennessFn)
            }
            if let rrimFn = library.makeFunction(name: "rrim_composite_to_texture") {
                rrimPipeline = try device.makeComputePipelineState(function: rrimFn)
            }
            if let viewshedFn = library.makeFunction(name: "compute_viewshed_raymarch") {
                viewshedPipeline = try device.makeComputePipelineState(function: viewshedFn)
            }
            Log.shader.info("Metal terrain pipelines compiled successfully on \(device.name, privacy: .public).")
        } catch {
            Log.shader.error("Pipeline construction failed: \(error.localizedDescription, privacy: .public)")
            fusedPipeline = nil
            slopeAspectPipeline = nil
            reliefPipeline = nil
            displayPipeline = nil
            opennessPipeline = nil
            rrimPipeline = nil
            viewshedPipeline = nil
        }
    }

    private func gpuReliefProducts(
        grid: ElevationGrid,
        azimuthCount: Int,
        altitudeDegrees: Double
    ) async -> ReliefProducts? {
        prepareIfNeeded()
        guard let device, let queue else { return nil }

        let count = grid.count
        let byteCount = count * MemoryLayout<Float>.stride
        guard let buffers = obtainBuffers(device: device, byteCount: byteCount),
              let commandBuffer = queue.makeCommandBuffer()
        else {
            Log.shader.error("Metal buffer allocation failed for \(count) cells; using CPU.")
            return nil
        }

        grid.withUnsafeSamples { srcBuf in
            if let srcBase = srcBuf.baseAddress {
                buffers.elevation.contents().copyMemory(from: srcBase, byteCount: byteCount)
            }
        }

        let cellX = Float(grid.metersPerColumn)
        let cellY = Float(grid.metersPerRow)
        let zenithRad = Float((90 - altitudeDegrees) * .pi / 180)

        var uniforms = Uniforms(
            width: UInt32(grid.width),
            height: UInt32(grid.height),
            cellSizeX: cellX,
            cellSizeY: cellY,
            zenithRadians: zenithRad,
            lightAzimuth: 0,
            azimuthCount: UInt32(max(azimuthCount, 1)),
            inv8CellX: cellX > 0 ? (1.0 / (8.0 * cellX)) : 0,
            inv8CellY: cellY > 0 ? (1.0 / (8.0 * cellY)) : 0,
            cosZenith: cos(zenithRad),
            sinZenith: sin(zenithRad)
        )

        let threadsPerGrid = MTLSize(width: grid.width, height: grid.height, depth: 1)
        let tgW = min(16, max(1, grid.width))
        let tgH = min(16, max(1, grid.height))
        let threadgroupSize = MTLSize(width: tgW, height: tgH, depth: 1)

        if let pipeline = fusedPipeline,
           let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(buffers.elevation, offset: 0, index: 0)
            encoder.setBuffer(buffers.slope, offset: 0, index: 1)
            encoder.setBuffer(buffers.aspect, offset: 0, index: 2)
            encoder.setBuffer(buffers.relief, offset: 0, index: 3)
            encoder.setBuffer(buffers.normalX, offset: 0, index: 4)
            encoder.setBuffer(buffers.normalY, offset: 0, index: 5)
            encoder.setBuffer(buffers.normalZ, offset: 0, index: 6)
            encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 7)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadgroupSize)
            encoder.endEncoding()
        } else if let slopePipe = slopeAspectPipeline,
                  let reliefPipe = reliefPipeline,
                  let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(slopePipe)
            encoder.setBuffer(buffers.elevation, offset: 0, index: 0)
            encoder.setBuffer(buffers.slope, offset: 0, index: 1)
            encoder.setBuffer(buffers.aspect, offset: 0, index: 2)
            encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 3)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadgroupSize)

            encoder.memoryBarrier(scope: .buffers)

            encoder.setComputePipelineState(reliefPipe)
            encoder.setBuffer(buffers.slope, offset: 0, index: 0)
            encoder.setBuffer(buffers.aspect, offset: 0, index: 1)
            encoder.setBuffer(buffers.relief, offset: 0, index: 2)
            encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 3)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadgroupSize)
            encoder.endEncoding()
        } else {
            releaseBuffers(buffers)
            return nil
        }

        let status = await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { cb in
                continuation.resume(returning: cb.error)
            }
            commandBuffer.commit()
        }

        guard status == nil else {
            releaseBuffers(buffers)
            return nil
        }

        // Fast uninitialized array copy from UMA buffer pointers
        let slope = [Float](unsafeUninitializedCapacity: count) { buf, initialized in
            if let base = buf.baseAddress {
                UnsafeMutableRawPointer(base).copyMemory(from: buffers.slope.contents(), byteCount: byteCount)
            }
            initialized = count
        }
        let aspect = [Float](unsafeUninitializedCapacity: count) { buf, initialized in
            if let base = buf.baseAddress {
                UnsafeMutableRawPointer(base).copyMemory(from: buffers.aspect.contents(), byteCount: byteCount)
            }
            initialized = count
        }
        let relief = [Float](unsafeUninitializedCapacity: count) { buf, initialized in
            if let base = buf.baseAddress {
                UnsafeMutableRawPointer(base).copyMemory(from: buffers.relief.contents(), byteCount: byteCount)
            }
            initialized = count
        }

        // Only the fused kernel writes unit normals; the two-pass fallback
        // leaves the normal buffers untouched, so return nil there and let the
        // caller relight from slope/aspect.
        let normalsAvailable = fusedPipeline != nil
        let nx: [Float]? = normalsAvailable ? [Float](unsafeUninitializedCapacity: count) { buf, initialized in
            if let base = buf.baseAddress {
                UnsafeMutableRawPointer(base).copyMemory(from: buffers.normalX.contents(), byteCount: byteCount)
            }
            initialized = count
        } : nil

        let ny: [Float]? = normalsAvailable ? [Float](unsafeUninitializedCapacity: count) { buf, initialized in
            if let base = buf.baseAddress {
                UnsafeMutableRawPointer(base).copyMemory(from: buffers.normalY.contents(), byteCount: byteCount)
            }
            initialized = count
        } : nil

        let nz: [Float]? = normalsAvailable ? [Float](unsafeUninitializedCapacity: count) { buf, initialized in
            if let base = buf.baseAddress {
                UnsafeMutableRawPointer(base).copyMemory(from: buffers.normalZ.contents(), byteCount: byteCount)
            }
            initialized = count
        } : nil

        releaseBuffers(buffers)

        return ReliefProducts(
            slopeDegrees: slope,
            aspectDegrees: aspect,
            multiDirectionalRelief: relief,
            width: grid.width,
            height: grid.height,
            backend: .gpu,
            normalX: nx,
            normalY: ny,
            normalZ: nz
        )
    }

    // MARK: - Fused surface to display

    /// Whether the one-pass display kernel is available on this device.
    public func isDisplayKernelAvailable() -> Bool {
        prepareIfNeeded()
        return displayPipeline != nil
    }

    /// Shades a padded elevation raster straight into a displayable bitmap.
    ///
    /// One dispatch replaces the whole download-and-loop tail of the old
    /// path: derivatives, the style's scalar, the colour ramp, the contour
    /// overlay and the premultiplied bytes are all produced on the GPU, into
    /// shared memory a `CGImage` can be built over without copying. Nothing
    /// crosses the bus in either direction except the elevation going in.
    ///
    /// The skirt never leaves the buffer. `margin` and the padded dimensions
    /// go into the uniforms and the dispatch covers the destination tile only,
    /// so each thread reads its 3x3 Horn window from `gid + margin` and the
    /// row-by-row crop that used to precede rendering does not happen at all.
    ///
    /// Returns `nil` when the device, the pipeline or a resource is
    /// unavailable, which is the caller's signal to take the CPU path.
    public func renderTile(
        samples: ElevationSamples,
        paddedWidth: Int,
        paddedHeight: Int,
        metersPerColumn: Double,
        metersPerRow: Double,
        request: TerrainRenderRequest
    ) async -> TerrainBitmap? {
        let state = Signpost.raster.beginInterval("renderTile")
        defer { Signpost.raster.endInterval("renderTile", state) }

        prepareIfNeeded()
        guard let device, let queue, let pipeline = displayPipeline else { return nil }

        let margin = max(request.margin, 0)
        let destWidth = paddedWidth - margin * 2
        let destHeight = paddedHeight - margin * 2
        guard destWidth > 0, destHeight > 0 else { return nil }

        let sampleCount = paddedWidth * paddedHeight
        // `owner`, for `.mapped`, is the object whose lifetime keeps the
        // mapping valid; it has to outlive the dispatch, not just this setup.
        let source: (buffer: any MTLBuffer, offset: Int, owner: AnyObject?)?
        switch samples {
        case .array(let values):
            let byteCount = sampleCount * MemoryLayout<Float>.stride
            if values.count >= sampleCount,
               let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) {
                values.withUnsafeBytes { src in
                    if let base = src.baseAddress {
                        buffer.contents().copyMemory(from: base, byteCount: byteCount)
                    }
                }
                source = (buffer, 0, nil)
            } else {
                source = nil
            }

        case .mapped(let base, let mappedLength, let sampleOffset, let owner):
            // `bytesNoCopy` needs a page-aligned pointer and a page-multiple
            // length, which is what the mapping is; the sample block's own
            // offset is expressed as a *buffer* offset instead, where 4-byte
            // alignment is all Metal asks for.
            if sampleOffset % MemoryLayout<Float>.alignment == 0,
               sampleOffset + sampleCount * MemoryLayout<Float>.stride <= mappedLength,
               let buffer = device.makeBuffer(
                   bytesNoCopy: base,
                   length: mappedLength,
                   options: .storageModeShared,
                   deallocator: nil
               ) {
                source = (buffer, sampleOffset, owner)
            } else {
                source = nil
            }

        case .leased(let lease):
            source = (lease.buffer, 0, lease)
        }
        guard let source else { return nil }
        let elevationBuffer = source.buffer
        let elevationOffset = source.offset

        // A linear texture over a shared buffer: the GPU writes it, the CPU
        // reads the same bytes, and no blit or `getBytes` sits between them.
        let alignment = max(device.minimumLinearTextureAlignment(for: .rgba8Unorm), 1)
        let bytesPerRow = (destWidth * 4 + alignment - 1) / alignment * alignment
        guard let outBuffer = device.makeBuffer(
            length: bytesPerRow * destHeight, options: .storageModeShared
        ) else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: destWidth, height: destHeight, mipmapped: false
        )
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .shared
        guard let outTexture = outBuffer.makeTexture(
            descriptor: descriptor, offset: 0, bytesPerRow: bytesPerRow
        ) else { return nil }

        guard let palette = paletteTexture(
            device: device, style: request.style, palette: request.palette
        ) else { return nil }

        let cellX = Float(metersPerColumn)
        let cellY = Float(metersPerRow)
        let zenith = Float((90 - request.altitudeDegrees) * .pi / 180)
        var uniforms = RenderUniforms(
            paddedWidth: UInt32(paddedWidth),
            paddedHeight: UInt32(paddedHeight),
            destWidth: UInt32(destWidth),
            destHeight: UInt32(destHeight),
            margin: UInt32(margin),
            style: Self.styleIndex(request.style),
            azimuthCount: UInt32(max(request.azimuthCount, 1)),
            inv8CellX: cellX > 0 ? 1.0 / (8.0 * cellX) : 0,
            inv8CellY: cellY > 0 ? 1.0 / (8.0 * cellY) : 0,
            cellSizeX: cellX,
            cellSizeY: cellY,
            cosZenith: cos(zenith),
            sinZenith: sin(zenith),
            lightAzimuth: Float(
                request.azimuthDegrees.truncatingRemainder(dividingBy: 360) * .pi / 180
            ),
            contourInterval: request.contourIntervalMeters,
            rangeMin: request.range.lowerBound,
            rangeMax: request.range.upperBound,
            indexMultiplier: UInt32(max(request.indexContourMultiplier, 0)),
            indexContourWidth: request.indexContourWidth
        )

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(elevationBuffer, offset: elevationOffset, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 1)
        encoder.setTexture(palette, index: 0)
        encoder.setTexture(outTexture, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: destWidth, height: destHeight, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: min(16, destWidth), height: min(16, destHeight), depth: 1
            )
        )
        encoder.endEncoding()

        let error = await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { cb in
                continuation.resume(returning: cb.error)
            }
            commandBuffer.commit()
        }
        // The GPU has read the mapping by the time the command buffer
        // completes, and not a moment before. Naming `owner` here is what
        // stops the optimiser from releasing it — and unmapping the pages the
        // kernel is reading — while the dispatch is still in flight.
        withExtendedLifetime(source.owner) {}
        guard error == nil else { return nil }

        return TerrainBitmap(
            buffer: outBuffer, width: destWidth, height: destHeight, bytesPerRow: bytesPerRow
        )
    }

    /// Style discriminant shared with `TerrainKernels.metal`.
    private nonisolated static func styleIndex(_ style: ReliefStyle) -> UInt32 {
        switch style {
        case .hillshade: 0
        case .multiDirectional: 1
        case .slope: 2
        case .elevation: 3
        // Never actually dispatched: TerrainTileOverlay routes these two
        // styles to opennessProducts/rrimImage directly, not renderTile. The
        // shader's switch on this index falls back to elevation for 4 and 5,
        // so an accidental dispatch degrades rather than misbehaving.
        case .topographicOpenness: 4
        case .rrim: 5
        case .localRelief: 6
        case .skyView: 7
        case .rakingLight: 8
        case .relativeElevation: 9
        case .curvature: 10
        }
    }

    /// The 256-texel ramp for a style, built once and kept.
    ///
    /// Only `.elevation` varies with the palette; the other three ignore it,
    /// so they share one entry each rather than one per palette.
    private func paletteTexture(
        device: any MTLDevice, style: ReliefStyle, palette: HypsometricPalette
    ) -> (any MTLTexture)? {
        let key = style == .elevation ? "\(style.rawValue)_\(palette.rawValue)" : style.rawValue
        if let existing = paletteTextures[key] { return existing }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type1D
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = 256
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        let texels = ReliefRenderer.paletteTexels(style: style, palette: palette)
        texels.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                texture.replace(
                    region: MTLRegionMake1D(0, 256),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: 0
                )
            }
        }
        paletteTextures[key] = texture
        return texture
    }

    private func cpuReliefProducts(
        grid: ElevationGrid,
        azimuthCount: Int,
        altitudeDegrees: Double
    ) -> ReliefProducts {
        let derivatives = TerrainAnalysis.derivatives(of: grid)
        let step = 360.0 / Double(max(azimuthCount, 1))
        let azimuths = (0..<max(azimuthCount, 1)).map { Double($0) * step }
        let relief = TerrainAnalysis.multiDirectionalRelief(
            derivatives, azimuths: azimuths, altitudeDegrees: altitudeDegrees
        )
        return ReliefProducts(
            slopeDegrees: derivatives.slopeDegrees,
            aspectDegrees: derivatives.aspectDegrees,
            multiDirectionalRelief: relief,
            width: grid.width,
            height: grid.height,
            backend: .cpu,
            normalX: derivatives.normalX,
            normalY: derivatives.normalY,
            normalZ: derivatives.normalZ
        )
    }
}
