//
//  MetalTerrainPipelineActor.swift
//  LidarExplorer
//
//  GPU dispatch and buffer management for the micro-topography engine.
//

import CoreGraphics
import Foundation
@preconcurrency import Metal
import os
import simd
#if canImport(UIKit)
import UIKit
#endif

/// Which micro-topography product a request shades.
public nonisolated enum MicroTopographyProduct: String, Sendable, CaseIterable, Identifiable {
    /// A. Local Relief Model: raw DEM minus a Gaussian trend surface.
    case localRelief
    /// B. Red Relief Image Map: slope saturation over differential openness.
    case redRelief
    /// C. Sky-view factor.
    case skyView
    /// D. Grazing-angle Lambertian hillshade.
    case rakingLight
    /// F. Relative Elevation Model against a river thalweg.
    case relativeElevation
    /// G. Flat benches ringed by steep ground.
    case habitation
    /// J. Topographic curvature (profile and planform).
    case curvature
    /// K. Directional grazing occlusion along solar azimuth.
    case directionalOcclusion
    /// L. Positive topographic openness.
    case positiveOpenness
    /// M. Negative topographic openness.
    case negativeOpenness
    /// N. Vector Ruggedness Measure (VRM).
    case vectorRuggedness
    /// O. Multi-scale Difference of Gaussians (DoG).
    case differenceOfGaussians

    public var id: String { rawValue }
}

/// How the elevation raster reached the GPU for one request.
public nonisolated enum ElevationBinding: String, Sendable {
    /// A linear texture over the caller's own memory: no sample moved.
    case zeroCopy
    /// Rows copied into a pooled shared buffer (a heap array, or a mapping whose
    /// row stride does not meet Metal's linear-texture alignment).
    case copied
    /// Uploaded to a private texture by a GPU blit (the Simulator's path).
    case blitted
}

/// An elevation raster as the pipeline consumes it.
public nonisolated struct ElevationRaster: Sendable {
    public let samples: ElevationSamples
    public let geometry: RasterGeometry
    /// True for sources that may still carry sentinels (`-999999`, infinities,
    /// a file's own GDAL_NODATA); the GPU rewrites them to NaN in place before
    /// any kernel reads them. False for rasters that are already NaN-voided.
    public let needsNoDataNormalization: Bool
    public let noDataValue: Float?

    public init(
        samples: ElevationSamples,
        geometry: RasterGeometry,
        needsNoDataNormalization: Bool = false,
        noDataValue: Float? = nil
    ) {
        self.samples = samples
        self.geometry = geometry
        self.needsNoDataNormalization = needsNoDataNormalization
        self.noDataValue = noDataValue
    }

    public init(grid: ElevationGrid) {
        self.init(samples: .array(grid.samples), geometry: RasterGeometry(grid))
    }
}

/// Layers the composite render pass draws over a product.
public nonisolated struct CompositeOverlays: Sendable, Equatable, Hashable {
    /// Intermediate contour interval in metres; 0 disables.
    public var contourIntervalMeters: Float = 0
    /// Index contour interval in metres; 0 disables.
    public var indexIntervalMeters: Float = 0
    /// Opacity of the habitation-potential mask; 0 disables.
    public var habitationOpacity: Float = 0
    /// How strongly the sky-view factor darkens the base, 0...1; 0 disables.
    public var skyViewStrength: Float = 0

    public init(
        contourIntervalMeters: Float = 0,
        indexIntervalMeters: Float = 0,
        habitationOpacity: Float = 0,
        skyViewStrength: Float = 0
    ) {
        self.contourIntervalMeters = contourIntervalMeters
        self.indexIntervalMeters = indexIntervalMeters
        self.habitationOpacity = habitationOpacity
        self.skyViewStrength = skyViewStrength
    }

    public var isEmpty: Bool {
        contourIntervalMeters <= 0 && indexIntervalMeters <= 0 && habitationOpacity <= 0 && skyViewStrength <= 0
    }
}

/// A read-only lease on a pooled shared buffer.
///
/// The buffer returns to the pool only in `deinit`, after its last reader has
/// gone -- the same contract as ``MetalBufferLease``, for the same reason: a
/// command buffer completing means the GPU is done, not that the CPU is.
///
/// `@unchecked Sendable`: the GPU writes the memory before the lease exists and
/// everything afterwards only reads it; the one write that recycles it happens
/// strictly after every reader is gone.
public nonisolated final class SurfaceLease: @unchecked Sendable {
    public let buffer: any MTLBuffer
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let bytesPerPixel: Int
    private let onDeinit: @Sendable (any MTLBuffer) -> Void

    init(
        buffer: any MTLBuffer, width: Int, height: Int, bytesPerRow: Int, bytesPerPixel: Int,
        onDeinit: @escaping @Sendable (any MTLBuffer) -> Void
    ) {
        self.buffer = buffer
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.bytesPerPixel = bytesPerPixel
        self.onDeinit = onDeinit
    }

    deinit { onDeinit(buffer) }
}

/// A `Float32` plane in shared memory, row stride included.
public nonisolated struct ScalarPlane: Sendable {
    public let lease: SurfaceLease

    public var width: Int { lease.width }
    public var height: Int { lease.height }

    public func value(x: Int, y: Int) -> Float {
        lease.buffer.contents().load(fromByteOffset: y * lease.bytesPerRow + x * 4, as: Float.self)
    }

    /// The plane as a tight row-major array.
    public func values() -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        let base = lease.buffer.contents()
        out.withUnsafeMutableBytes { dst in
            for y in 0..<height {
                memcpy(dst.baseAddress! + y * width * 4, base + y * lease.bytesPerRow, width * 4)
            }
        }
        return out
    }
}

/// Premultiplied RGBA8 pixels in shared memory, drawable without a copy.
public nonisolated struct DisplayBitmap: Sendable {
    public let lease: SurfaceLease

    public var width: Int { lease.width }
    public var height: Int { lease.height }

    private static let colorSpace = CGColorSpaceCreateDeviceRGB()

    public func pixel(x: Int, y: Int) -> SIMD4<UInt8> {
        let p = lease.buffer.contents().advanced(by: y * lease.bytesPerRow + x * 4)
            .assumingMemoryBound(to: UInt8.self)
        return SIMD4(p[0], p[1], p[2], p[3])
    }

    /// Wraps the leased bytes as a `CGImage`. The data provider holds the
    /// lease, so the buffer is recycled only when the image is released.
    public func makeImage() -> CGImage? {
        let retained = Unmanaged.passRetained(lease).toOpaque()
        guard let provider = CGDataProvider(
            dataInfo: retained,
            data: lease.buffer.contents(),
            size: lease.bytesPerRow * lease.height,
            releaseData: { info, _, _ in
                if let info { Unmanaged<SurfaceLease>.fromOpaque(info).release() }
            }
        ) else {
            Unmanaged<SurfaceLease>.fromOpaque(retained).release()
            return nil
        }
        return CGImage(
            width: lease.width,
            height: lease.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: lease.bytesPerRow,
            space: Self.colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

/// One product, as the GPU produced it.
public nonisolated struct MicroTopographyResult: Sendable {
    public let product: MicroTopographyProduct
    /// The product, or the composite when overlays were requested.
    public let display: DisplayBitmap
    /// The product's scalar over the destination window: `dh` (m), differential
    /// openness (deg), sky-view factor, light intensity, `h_rel` (m) or the
    /// habitation mask (0/1).
    public let scalar: ScalarPlane
    /// GPU execution time of the whole command buffer.
    public let gpuMilliseconds: Double
    public let elevationBinding: ElevationBinding
}

public nonisolated struct ViewshedResult: Sendable {
    /// Visible cells tinted, everything else transparent.
    public let display: DisplayBitmap
    /// 1 where visible, 0 elsewhere.
    public let mask: ScalarPlane
    public let gpuMilliseconds: Double
    public let elevationBinding: ElevationBinding
}

/// Owns the Metal pipelines, surface pool and dispatch for every
/// micro-topography product.
///
/// ## Memory
///
/// Every texture is a view over a pooled shared buffer (or, on the Simulator, a
/// pooled private texture). Temporaries return to the pool when their command
/// buffer completes; outputs leave as ``SurfaceLease``s and return when the
/// last reader drops them. Idle pool memory is capped at ``idleByteLimit``.
///
/// ## Dispatch
///
/// A product is one command buffer: optional upload blit, nodata
/// normalisation, the product's passes, optional overlay passes and the
/// composite render pass, optional readback blit. Completion is awaited through
/// a handler, never `waitUntilCompleted`, so no thread blocks on the GPU.
public actor MetalTerrainPipelineActor {

    public enum SurfaceMode: String, Sendable {
        /// Textures are linear views over shared buffers (Apple GPUs).
        case linear
        /// Private textures with GPU blits in and out (the iOS Simulator,
        /// whose Metal raises on linear textures).
        case blit
    }

    public struct PoolStatistics: Sendable, Equatable {
        public let idleBytes: Int
        public let idleBuffers: Int
        public let idleTextures: Int
        public let liveLeases: Int
    }

    public static let shared = MetalTerrainPipelineActor()
    public nonisolated static let idleByteLimit = 192 * 1024 * 1024

    public nonisolated let surfaceMode: SurfaceMode
    private let device: (any MTLDevice)?
    private var queue: (any MTLCommandQueue)?
    private var computePipelines: [String: any MTLComputePipelineState] = [:]
    private var compositePipeline: (any MTLRenderPipelineState)?
    private var setupAttempted = false

    private nonisolated static let kernelNames = [
        "normalize_nodata",
        "lrm_gaussian_horizontal", "lrm_gaussian_vertical", "lrm_residual_to_texture",
        "compute_rrim", "compute_svf", "dynamic_raking_hillshade", "detrend_river_elevation",
        "habitation_slope_seed", "habitation_jump_flood", "evaluate_habitation_potential",
        "viewshed_radial_sweep", "compute_viewshed", "compute_topographic_curvature",
        "compute_directional_occlusion", "compute_openness_split", "compute_vector_ruggedness",
        "lrm_robust_horizontal", "lrm_robust_vertical", "dog_residual_to_texture",
    ]

    public init(surfaceMode: SurfaceMode? = nil) {
        self.device = MTLCreateSystemDefaultDevice()
        #if targetEnvironment(simulator)
        self.surfaceMode = surfaceMode ?? .blit
        #else
        self.surfaceMode = surfaceMode ?? .linear
        #endif

        // Idle pool memory is only a warm start, up to ``idleByteLimit`` of it.
        // Give it back when the system asks, and when the app leaves the
        // screen; the next render refills what it needs.
        #if canImport(UIKit)
        for name in [UIApplication.didReceiveMemoryWarningNotification,
                     UIApplication.didEnterBackgroundNotification] {
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name) {
                    await self?.purgeIdlePools()
                }
            }
        }
        #endif
    }

    // MARK: - Setup

    public func isAvailable() -> Bool {
        prepareIfNeeded()
        return queue != nil && compositePipeline != nil && computePipelines.count == Self.kernelNames.count
    }

    private func prepareIfNeeded() {
        guard !setupAttempted else { return }
        setupAttempted = true
        guard let device, let queue = device.makeCommandQueue() else {
            Log.shader.notice("Micro-topography pipeline: no Metal device or queue.")
            return
        }
        queue.label = "MicroTopography"

        guard let library = Self.loadLibrary(device) else {
            Log.shader.error("Micro-topography pipeline: Metal library not found.")
            return
        }
        do {
            for name in Self.kernelNames {
                guard let function = library.makeFunction(name: name) else {
                    Log.shader.error("Micro-topography kernel \(name, privacy: .public) missing from library.")
                    return
                }
                computePipelines[name] = try device.makeComputePipelineState(function: function)
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "terrain_composite"
            descriptor.vertexFunction = library.makeFunction(name: "terrain_composite_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "terrain_composite_fragment")
            descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
            compositePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            self.queue = queue
            Log.shader.info("Micro-topography pipeline ready (\(self.surfaceMode.rawValue, privacy: .public) surfaces).")
        } catch {
            Log.shader.error("Micro-topography pipeline failed: \(error.localizedDescription, privacy: .public)")
            computePipelines.removeAll()
            compositePipeline = nil
        }
    }

    private nonisolated static func loadLibrary(_ device: any MTLDevice) -> (any MTLLibrary)? {
        if let library = try? device.makeDefaultLibrary(bundle: .main) { return library }
        if let library = device.makeDefaultLibrary() { return library }
        let candidates = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("default.metallib"),
            URL(fileURLWithPath: "default.metallib"),
        ]
        for case let url? in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let library = try? device.makeLibrary(URL: url) { return library }
        }
        return nil
    }

    // MARK: - Pool

    private struct Surface {
        let texture: any MTLTexture
        /// The shared buffer a linear texture views; nil for a private texture.
        let buffer: (any MTLBuffer)?
        let bytesPerRow: Int
        let width: Int
        let height: Int
        let bytesPerPixel: Int
    }

    private struct TextureKey: Hashable {
        let width: Int
        let height: Int
        let format: UInt
        let usage: UInt
    }

    /// A staging buffer carried into its upload's completion handler.
    private struct TransferredBuffer: @unchecked Sendable {
        let buffer: any MTLBuffer
    }

    private final class SharedBufferPool: @unchecked Sendable {
        struct State: @unchecked Sendable {
            var bufferPool: [Int: [any MTLBuffer]] = [:]
            var idleBytes: Int = 0
            var liveLeases: Int = 0
        }

        let lock = OSAllocatedUnfairLock<State>(initialState: State())
        let maxIdleBytes: Int

        init(maxIdleBytes: Int) {
            self.maxIdleBytes = maxIdleBytes
        }

        func obtainBuffer(length: Int, device: (any MTLDevice)?) -> (any MTLBuffer)? {
            let page = Int(getpagesize())
            let rounded = (max(length, 1) + page - 1) / page * page
            let popped = lock.withLock { state -> (any MTLBuffer)? in
                if var list = state.bufferPool[rounded], let buffer = list.popLast() {
                    state.bufferPool[rounded] = list
                    state.idleBytes -= rounded
                    return buffer
                }
                return nil
            }
            if let popped { return popped }
            return device?.makeBuffer(length: rounded, options: .storageModeShared)
        }

        func recycleBuffer(_ buffer: any MTLBuffer) {
            let length = buffer.length
            lock.withLock { state in
                guard state.idleBytes + length <= maxIdleBytes else { return }
                state.bufferPool[length, default: []].append(buffer)
                state.idleBytes += length
            }
        }

        func purge() {
            lock.withLock { state in
                state.bufferPool.removeAll()
                state.idleBytes = 0
            }
        }

        func leaseAcquired() {
            lock.withLock { state in state.liveLeases += 1 }
        }

        func leaseReleased(_ buffer: any MTLBuffer) {
            let length = buffer.length
            lock.withLock { state in
                state.liveLeases = max(0, state.liveLeases - 1)
                guard state.idleBytes + length <= maxIdleBytes else { return }
                state.bufferPool[length, default: []].append(buffer)
                state.idleBytes += length
            }
        }
    }

    private let sharedBufferPool = SharedBufferPool(maxIdleBytes: idleByteLimit)
    private var texturePool: [TextureKey: [any MTLTexture]] = [:]
    private var idleBytes = 0

    public func poolStatistics() -> PoolStatistics {
        let (poolIdleBytes, idleBuffers, liveLeases) = sharedBufferPool.lock.withLock { state in
            (state.idleBytes, state.bufferPool.values.reduce(0) { $0 + $1.count }, state.liveLeases)
        }
        return PoolStatistics(
            idleBytes: idleBytes + poolIdleBytes,
            idleBuffers: idleBuffers,
            idleTextures: texturePool.values.reduce(0) { $0 + $1.count },
            liveLeases: liveLeases
        )
    }

    /// Releases every idle buffer and texture. Leased and in-flight surfaces are
    /// untouched; they return to the emptied pool as their readers finish.
    public func purgeIdlePools() {
        let released = poolStatistics().idleBytes
        sharedBufferPool.purge()
        texturePool.removeAll()
        idleBytes = 0
        Log.shader.notice("Purged idle Metal pools: released \(released / 1_048_576, privacy: .public) MB.")
    }

    private nonisolated static func bytesPerPixel(_ format: MTLPixelFormat) -> Int {
        switch format {
        case .rgba32Float: 16
        case .rg32Float: 8
        case .r32Float, .rgba8Unorm: 4
        default: 4
        }
    }

    private func obtainBuffer(length: Int) -> (any MTLBuffer)? {
        sharedBufferPool.obtainBuffer(length: length, device: device)
    }

    private func recycleBuffer(_ buffer: any MTLBuffer) {
        sharedBufferPool.recycleBuffer(buffer)
    }

    private func makeSurface(width: Int, height: Int, format: MTLPixelFormat, usage: MTLTextureUsage) -> Surface? {
        guard let device, width > 0, height > 0 else { return nil }
        let bpp = Self.bytesPerPixel(format)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false
        )
        descriptor.usage = usage
        switch surfaceMode {
        case .linear:
            let alignment = max(device.minimumLinearTextureAlignment(for: format), 1)
            let bytesPerRow = (width * bpp + alignment - 1) / alignment * alignment
            guard let buffer = obtainBuffer(length: bytesPerRow * height) else { return nil }
            descriptor.storageMode = .shared
            guard let texture = buffer.makeTexture(descriptor: descriptor, offset: 0, bytesPerRow: bytesPerRow) else {
                recycleBuffer(buffer)
                return nil
            }
            return Surface(texture: texture, buffer: buffer, bytesPerRow: bytesPerRow,
                           width: width, height: height, bytesPerPixel: bpp)
        case .blit:
            let key = TextureKey(width: width, height: height, format: format.rawValue, usage: usage.rawValue)
            if var list = texturePool[key], let texture = list.popLast() {
                texturePool[key] = list
                idleBytes -= width * height * bpp
                return Surface(texture: texture, buffer: nil, bytesPerRow: width * bpp,
                               width: width, height: height, bytesPerPixel: bpp)
            }
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            return Surface(texture: texture, buffer: nil, bytesPerRow: width * bpp,
                           width: width, height: height, bytesPerPixel: bpp)
        }
    }

    private func recycle(_ surface: Surface) {
        if let buffer = surface.buffer {
            recycleBuffer(buffer)
            return
        }
        let bytes = surface.width * surface.height * surface.bytesPerPixel
        guard idleBytes + bytes <= Self.idleByteLimit else { return }
        let key = TextureKey(
            width: surface.width, height: surface.height,
            format: surface.texture.pixelFormat.rawValue, usage: surface.texture.usage.rawValue
        )
        texturePool[key, default: []].append(surface.texture)
        idleBytes += bytes
    }

    private func makeLease(buffer: any MTLBuffer, width: Int, height: Int, bytesPerRow: Int, bytesPerPixel: Int) -> SurfaceLease {
        let pool = sharedBufferPool
        pool.leaseAcquired()
        return SurfaceLease(
            buffer: buffer, width: width, height: height, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel
        ) { returned in
            pool.leaseReleased(returned)
        }
    }

    /// Acquires a pooled shared buffer wrapped in a `SurfaceLease` for zero-copy raster generation.
    public func leasedSurface(for format: MTLPixelFormat = .r32Float, dimensions: SIMD2<Int32>) -> SurfaceLease? {
        leasedSurface(for: format, width: Int(dimensions.x), height: Int(dimensions.y))
    }

    /// Acquires a pooled shared buffer wrapped in a `SurfaceLease` with linear row alignment.
    public func leasedSurface(for format: MTLPixelFormat = .r32Float, width: Int, height: Int) -> SurfaceLease? {
        guard let device, width > 0, height > 0 else { return nil }
        let bpp = Self.bytesPerPixel(format)
        let alignment = max(device.minimumLinearTextureAlignment(for: format), 1)
        let unaligned = width * bpp
        let rowBytes = (unaligned + alignment - 1) / alignment * alignment
        let totalBytes = rowBytes * height
        guard let buffer = obtainBuffer(length: totalBytes) else { return nil }
        return makeLease(buffer: buffer, width: width, height: height, bytesPerRow: rowBytes, bytesPerPixel: bpp)
    }

    // MARK: - Static textures (palettes, placeholders)

    private var staticTextures: [String: any MTLTexture] = [:]

    /// A small texture whose contents never change, created on first use.
    ///
    /// Linear mode fills a shared texture directly. Blit mode creates a private
    /// texture and schedules its upload at the head of `commandBuffer`, ahead
    /// of every encoder that reads it.
    private func staticTexture(
        key: String, descriptor: MTLTextureDescriptor, bytes: [UInt8], bytesPerRow: Int,
        commandBuffer: any MTLCommandBuffer
    ) -> (any MTLTexture)? {
        if let existing = staticTextures[key] { return existing }
        guard let device else { return nil }
        descriptor.usage = .shaderRead
        let region = descriptor.textureType == .type1D
            ? MTLRegionMake1D(0, descriptor.width)
            : MTLRegionMake2D(0, 0, descriptor.width, descriptor.height)
        switch surfaceMode {
        case .linear:
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            bytes.withUnsafeBytes { raw in
                texture.replace(region: region, mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow)
            }
            staticTextures[key] = texture
            return texture
        case .blit:
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor),
                  let staging = bytes.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
                  let blit = commandBuffer.makeBlitCommandEncoder()
            else { return nil }
            blit.copy(
                from: staging, sourceOffset: 0, sourceBytesPerRow: bytesPerRow,
                sourceBytesPerImage: bytes.count,
                sourceSize: MTLSize(width: descriptor.width, height: descriptor.height, depth: 1),
                to: texture, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
            staticTextures[key] = texture
            return texture
        }
    }

    private func transparentPlaceholder(_ commandBuffer: any MTLCommandBuffer) -> (any MTLTexture)? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        return staticTexture(key: "placeholder.rgba8", descriptor: d, bytes: [0, 0, 0, 0], bytesPerRow: 4, commandBuffer: commandBuffer)
    }

    private func unitPlaceholder(_ commandBuffer: any MTLCommandBuffer) -> (any MTLTexture)? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        let one = withUnsafeBytes(of: Float(1)) { Array($0) }
        return staticTexture(key: "placeholder.r32f", descriptor: d, bytes: one, bytesPerRow: 4, commandBuffer: commandBuffer)
    }

    private func relativeElevationPalette(range: ClosedRange<Float>, commandBuffer: any MTLCommandBuffer) -> (any MTLTexture)? {
        let d = MTLTextureDescriptor()
        d.textureType = .type1D
        d.pixelFormat = .rgba8Unorm
        d.width = 256
        return staticTexture(
            key: "rem.\(range.lowerBound).\(range.upperBound)", descriptor: d,
            bytes: MicroTopographyPalettes.relativeElevationTexels(range: range), bytesPerRow: 0,
            commandBuffer: commandBuffer
        )
    }

    // MARK: - Elevation binding

    private struct BoundElevation {
        let texture: any MTLTexture
        let binding: ElevationBinding
    }

    /// Makes `raster` readable (and, if it needs normalising, writable) as an
    /// R32Float texture, moving as little as the platform allows.
    private func bindElevation(
        _ raster: ElevationRaster,
        commandBuffer: any MTLCommandBuffer,
        temporaries: inout [Surface],
        retained: inout [AnyObject]
    ) -> BoundElevation? {
        guard let device else { return nil }
        let g = raster.geometry
        let sampleBytes = g.count * MemoryLayout<Float>.stride
        let tightRow = g.width * 4

        // A shared buffer holding the samples at `offset`,
        // without copying when the source is page-aligned memory or a leased buffer.
        var source: (buffer: any MTLBuffer, offset: Int)?
        var sourceIsZeroCopy = false
        var sourceRowBytes = tightRow
        if case let .leased(lease) = raster.samples {
            source = (lease.buffer, 0)
            sourceIsZeroCopy = true
            sourceRowBytes = lease.bytesPerRow
            retained.append(lease)
            retained.append(lease.buffer)
        } else if case let .mapped(base, mappedLength, sampleOffset, owner) = raster.samples,
           sampleOffset % MemoryLayout<Float>.alignment == 0,
           sampleOffset + sampleBytes <= mappedLength,
           let buffer = device.makeBuffer(bytesNoCopy: base, length: mappedLength, options: .storageModeShared, deallocator: nil) {
            source = (buffer, sampleOffset)
            sourceIsZeroCopy = true
            retained.append(owner)
            retained.append(buffer)
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: g.width, height: g.height, mipmapped: false
        )
        let usage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        descriptor.usage = usage

        switch surfaceMode {
        case .linear:
            let alignment = max(device.minimumLinearTextureAlignment(for: .r32Float), 1)
            // Metal validates both the row stride and the buffer offset against
            // the alignment ("Offset of a buffer-backed texture ... must be
            // aligned to 16 bytes" on Apple silicon). Today's offsets are 0 and
            // 4096; anything else takes the copy rather than the assert.
            if let source, sourceIsZeroCopy, source.offset % alignment == 0, sourceRowBytes % alignment == 0 {
                descriptor.storageMode = .shared
                if let texture = source.buffer.makeTexture(descriptor: descriptor, offset: source.offset, bytesPerRow: sourceRowBytes) {
                    return BoundElevation(texture: texture, binding: .zeroCopy)
                }
            }
            guard let surface = makeSurface(width: g.width, height: g.height, format: .r32Float, usage: usage),
                  let destination = surface.buffer
            else { return nil }
            temporaries.append(surface)
            Self.withSampleBytes(raster.samples, count: g.count) { src in
                let dst = destination.contents()
                for y in 0..<g.height {
                    memcpy(dst + y * surface.bytesPerRow, src.baseAddress! + y * tightRow, tightRow)
                }
            }
            return BoundElevation(texture: surface.texture, binding: .copied)

        case .blit:
            if source == nil {
                guard let staging = obtainBuffer(length: sampleBytes) else { return nil }
                Self.withSampleBytes(raster.samples, count: g.count) { src in
                    memcpy(staging.contents(), src.baseAddress!, sampleBytes)
                }
                source = (staging, 0)
                // Recycled when *this* command buffer completes. Recycling when
                // the render resumed let a sibling render that finished first
                // return this buffer to the pool while its blit was still
                // queued, where a third render could take it and overwrite the
                // samples before the GPU read them. A command buffer abandoned
                // before commit never completes, and the buffer is released.
                let transfer = TransferredBuffer(buffer: staging)
                let pool = sharedBufferPool
                commandBuffer.addCompletedHandler { _ in pool.recycleBuffer(transfer.buffer) }
            }
            guard let source,
                  let surface = makeSurface(width: g.width, height: g.height, format: .r32Float, usage: usage),
                  let blit = commandBuffer.makeBlitCommandEncoder()
            else { return nil }
            temporaries.append(surface)
            blit.copy(
                from: source.buffer, sourceOffset: source.offset, sourceBytesPerRow: sourceRowBytes,
                sourceBytesPerImage: sampleBytes, sourceSize: MTLSize(width: g.width, height: g.height, depth: 1),
                to: surface.texture, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
            return BoundElevation(texture: surface.texture, binding: .blitted)
        }
    }

    private nonisolated static func withSampleBytes(
        _ samples: ElevationSamples, count: Int, _ body: (UnsafeRawBufferPointer) -> Void
    ) {
        switch samples {
        case .array(let values):
            values.withUnsafeBytes { body(UnsafeRawBufferPointer(rebasing: $0.prefix(count * 4))) }
        case let .mapped(base, _, sampleOffset, owner):
            withExtendedLifetime(owner) {
                body(UnsafeRawBufferPointer(start: base + sampleOffset, count: count * 4))
            }
        case .leased(let lease):
            withExtendedLifetime(lease) {
                body(UnsafeRawBufferPointer(start: lease.buffer.contents(), count: count * 4))
            }
        }
    }

    private nonisolated static func referenceElevation(_ samples: ElevationSamples, count: Int) -> Float {
        var reference: Float = 0
        withSampleBytes(samples, count: count) { reference = MicroTopographyReference.referenceElevation($0) }
        return reference
    }

    private nonisolated static func sampleBilinear(
        _ samples: ElevationSamples, _ g: RasterGeometry, x: Float, y: Float
    ) -> Float? {
        guard x >= 0, y >= 0, x <= Float(g.width - 1), y <= Float(g.height - 1) else { return nil }
        var result: Float?
        withSampleBytes(samples, count: g.count) { bytes in
            func at(_ cx: Int, _ cy: Int) -> Float? {
                let v = bytes.load(fromByteOffset: (cy * g.width + cx) * 4, as: Float.self)
                return v.isFinite && MicroTopographyReference.validElevationRange.contains(v) ? v : nil
            }
            let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
            let x1 = min(x0 + 1, g.width - 1), y1 = min(y0 + 1, g.height - 1)
            guard let v00 = at(x0, y0), let v10 = at(x1, y0), let v01 = at(x0, y1), let v11 = at(x1, y1) else { return }
            let fx = x - Float(x0), fy = y - Float(y0)
            let top = v00 + (v10 - v00) * fx
            let bottom = v01 + (v11 - v01) * fx
            result = top + (bottom - top) * fy
        }
        return result
    }

    // MARK: - Dispatch helpers

    private func dispatch(
        _ encoder: any MTLComputeCommandEncoder, _ name: String, width: Int, height: Int,
        configure: (any MTLComputeCommandEncoder) -> Void
    ) -> Bool {
        guard let pipeline = computePipelines[name], width > 0, height > 0 else { return false }
        encoder.setComputePipelineState(pipeline)
        configure(encoder)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: Self.threadgroupSize(pipeline, width: width, height: height)
        )
        return true
    }

    /// Threadgroups sized from the pipeline's execution width, the brief's
    /// "optimize dynamically" option: `threadExecutionWidth` wide, as tall as
    /// the pipeline's thread limit allows.
    private nonisolated static func threadgroupSize(
        _ pipeline: any MTLComputePipelineState, width: Int, height: Int
    ) -> MTLSize {
        let w = max(pipeline.threadExecutionWidth, 1)
        let h = max(pipeline.maxTotalThreadsPerThreadgroup / w, 1)
        return MTLSize(width: max(min(w, width), 1), height: max(min(h, height), 1), depth: 1)
    }

    private nonisolated static func setValue<T>(_ encoder: any MTLComputeCommandEncoder, _ value: T, index: Int) {
        var copy = value
        withUnsafeBytes(of: &copy) { raw in
            if let base = raw.baseAddress {
                encoder.setBytes(base, length: MemoryLayout<T>.stride, index: index)
            }
        }
    }

    /// Binds an array argument, inline when small and as a buffer otherwise.
    private func setArray<T>(_ encoder: any MTLComputeCommandEncoder, _ values: [T], index: Int) -> Bool {
        let length = max(values.count, 1) * MemoryLayout<T>.stride
        if length <= 4_000 {
            values.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    encoder.setBytes(base, length: raw.count, index: index)
                }
            }
            return !values.isEmpty
        }
        guard let device,
              let buffer = values.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
        else { return false }
        encoder.setBuffer(buffer, offset: 0, index: index)
        return true
    }

    private struct RayTableKey: Hashable {
        let rays: Int
        let radiusBits: UInt32
        let macroRadiusBits: UInt32
        let cellSizeXBits: UInt32
        let cellSizeYBits: UInt32
        let minimumStepBits: UInt32

        init(
            rays: Int,
            radiusMeters: Float,
            macroRadiusMeters: Float = 0,
            cellSizeX: Float,
            cellSizeY: Float,
            minimumStep: Float
        ) {
            self.rays = rays
            self.radiusBits = radiusMeters.bitPattern
            self.macroRadiusBits = macroRadiusMeters.bitPattern
            self.cellSizeXBits = cellSizeX.bitPattern
            self.cellSizeYBits = cellSizeY.bitPattern
            self.minimumStepBits = minimumStep.bitPattern
        }
    }

    private var rayTableCache: [RayTableKey: RayTable] = [:]

    private func rayTable(rays: Int, radiusMeters: Float, geometry g: RasterGeometry, minimumStep: Float) -> RayTable {
        let key = RayTableKey(rays: rays, radiusMeters: radiusMeters, cellSizeX: g.cellSizeX, cellSizeY: g.cellSizeY, minimumStep: minimumStep)
        if let cached = rayTableCache[key] { return cached }
        let table = RayTable(rayCount: rays, radiusMeters: radiusMeters, cellSizeX: g.cellSizeX,
                             cellSizeY: g.cellSizeY, minimumStepMeters: minimumStep)
        if rayTableCache.count > 32 { rayTableCache.removeAll() }
        rayTableCache[key] = table
        return table
    }

    private var dualRadiusRayTableCache: [RayTableKey: DualRadiusRayTable] = [:]

    private func dualRadiusRayTable(
        rays: Int, microRadiusMeters: Float, macroRadiusMeters: Float,
        geometry g: RasterGeometry, minimumStep: Float
    ) -> DualRadiusRayTable {
        let key = RayTableKey(
            rays: rays, radiusMeters: microRadiusMeters, macroRadiusMeters: macroRadiusMeters,
            cellSizeX: g.cellSizeX, cellSizeY: g.cellSizeY, minimumStep: minimumStep
        )
        if let cached = dualRadiusRayTableCache[key] { return cached }
        let table = DualRadiusRayTable(
            rayCount: rays, microRadiusMeters: microRadiusMeters, macroRadiusMeters: macroRadiusMeters,
            cellSizeX: g.cellSizeX, cellSizeY: g.cellSizeY, minimumStepMeters: minimumStep
        )
        if dualRadiusRayTableCache.count > 32 { dualRadiusRayTableCache.removeAll() }
        dualRadiusRayTableCache[key] = table
        return table
    }

    private struct ProductSurfaces {
        let display: Surface
        let scalar: Surface
    }

    // MARK: - Kernel encoders

    private func encodeNoData(_ encoder: any MTLComputeCommandEncoder, elevation: any MTLTexture, raster: ElevationRaster) -> Bool {
        let g = raster.geometry
        let uniforms = GPU.NoData(
            width: UInt32(g.width), height: UInt32(g.height),
            noDataValue: raster.noDataValue ?? 0, hasNoDataValue: raster.noDataValue == nil ? 0 : 1,
            validMinimum: MicroTopographyReference.validElevationRange.lowerBound,
            validMaximum: MicroTopographyReference.validElevationRange.upperBound
        )
        return dispatch(encoder, "normalize_nodata", width: g.width, height: g.height) { e in
            e.setTexture(elevation, index: 0)
            Self.setValue(e, uniforms, index: 0)
        }
    }

    private func encodeLocalRelief(
        _ encoder: any MTLComputeCommandEncoder, elevation: any MTLTexture, raster: ElevationRaster,
        window: DestinationWindow, options: MicroTopographyOptions, temporaries: inout [Surface]
    ) -> ProductSurfaces? {
        let g = raster.geometry
        let rw: MTLTextureUsage = [.shaderRead, .shaderWrite]
        guard let sums = makeSurface(width: g.width, height: g.height, format: .rg32Float, usage: rw),
              let lowpass = makeSurface(width: g.width, height: g.height, format: .r32Float, usage: rw),
              let residual = makeSurface(width: window.width, height: window.height, format: .r32Float, usage: rw),
              let display = makeSurface(width: window.width, height: window.height, format: .rgba8Unorm, usage: rw)
        else { return nil }
        temporaries.append(contentsOf: [sums, lowpass])

        let reference = Self.referenceElevation(raster.samples, count: g.count)
        let tapsX = GaussianTaps(radiusMeters: options.lrmRadiusMeters, cellSize: g.cellSizeX)
        let tapsY = GaussianTaps(radiusMeters: options.lrmRadiusMeters, cellSize: g.cellSizeY)

        var ok = dispatch(encoder, "lrm_gaussian_horizontal", width: g.width, height: g.height) { e in
            e.setTexture(elevation, index: 0)
            e.setTexture(sums.texture, index: 1)
            Self.setValue(e, GPU.GaussianPass(width: UInt32(g.width), height: UInt32(g.height),
                                              radius: Int32(tapsX.radius), referenceElevation: reference), index: 0)
            _ = self.setArray(e, tapsX.weights, index: 1)
        }
        ok = ok && dispatch(encoder, "lrm_gaussian_vertical", width: g.width, height: g.height) { e in
            e.setTexture(sums.texture, index: 0)
            e.setTexture(lowpass.texture, index: 1)
            Self.setValue(e, GPU.GaussianPass(width: UInt32(g.width), height: UInt32(g.height),
                                              radius: Int32(tapsY.radius), referenceElevation: reference), index: 0)
            _ = self.setArray(e, tapsY.weights, index: 1)
        }

        let effectiveLowpass: Surface
        if options.lrmRobustTukey,
           let momentsA = makeSurface(width: g.width, height: g.height, format: .rgba32Float, usage: rw),
           let momentsB = makeSurface(width: g.width, height: g.height, format: .rgba32Float, usage: rw),
           let robustLowpass = makeSurface(width: g.width, height: g.height, format: .r32Float, usage: rw) {
            temporaries.append(contentsOf: [momentsA, momentsB, robustLowpass])
            let invRadius = 1.0 / max(Float(tapsX.radius), 1.0)
            let invC = 1.0 / max(options.lrmTukeyCutoffMeters, 0.1)

            ok = ok && dispatch(encoder, "lrm_robust_horizontal", width: g.width, height: g.height) { e in
                e.setTexture(elevation, index: 0)
                e.setTexture(lowpass.texture, index: 1)
                e.setTexture(momentsA.texture, index: 2)
                e.setTexture(momentsB.texture, index: 3)
                Self.setValue(e, GPU.RobustTrend(
                    width: UInt32(g.width), height: UInt32(g.height),
                    radius: Int32(tapsX.radius), referenceElevation: reference,
                    invRadius: invRadius, invTukeyC: invC, minimumSupport: 0.1, hasPrevious: 1
                ), index: 0)
                _ = self.setArray(e, tapsX.weights, index: 1)
            }
            ok = ok && dispatch(encoder, "lrm_robust_vertical", width: g.width, height: g.height) { e in
                e.setTexture(momentsA.texture, index: 0)
                e.setTexture(momentsB.texture, index: 1)
                e.setTexture(lowpass.texture, index: 2)
                e.setTexture(robustLowpass.texture, index: 3)
                Self.setValue(e, GPU.RobustTrend(
                    width: UInt32(g.width), height: UInt32(g.height),
                    radius: Int32(tapsY.radius), referenceElevation: reference,
                    invRadius: invRadius, invTukeyC: invC, minimumSupport: 0.1, hasPrevious: 1
                ), index: 0)
                _ = self.setArray(e, tapsY.weights, index: 1)
            }
            effectiveLowpass = robustLowpass
        } else {
            effectiveLowpass = lowpass
        }

        ok = ok && dispatch(encoder, "lrm_residual_to_texture", width: window.width, height: window.height) { e in
            e.setTexture(elevation, index: 0)
            e.setTexture(effectiveLowpass.texture, index: 1)
            e.setTexture(residual.texture, index: 2)
            e.setTexture(display.texture, index: 3)
            Self.setValue(e, GPU.LocalRelief(
                destWidth: UInt32(window.width), destHeight: UInt32(window.height),
                originX: UInt32(window.originX), originY: UInt32(window.originY),
                referenceElevation: reference, scaleMeters: options.lrmScaleMeters,
                colorMode: options.lrmDiverging ? 1 : 0
            ), index: 0)
        }
        guard ok else {
            recycle(residual)
            recycle(display)
            return nil
        }
        return ProductSurfaces(display: display, scalar: residual)
    }

    private func encodeRedRelief(
        _ encoder: any MTLComputeCommandEncoder, elevation: any MTLTexture, raster: ElevationRaster,
        window: DestinationWindow, options: MicroTopographyOptions
    ) -> ProductSurfaces? {
        let g = raster.geometry
        let rw: MTLTextureUsage = [.shaderRead, .shaderWrite]
        guard let display = makeSurface(width: window.width, height: window.height, format: .rgba8Unorm, usage: rw),
              let scalar = makeSurface(width: window.width, height: window.height, format: .r32Float, usage: rw)
        else { return nil }
        let table = rayTable(rays: options.rrimAzimuthRays, radiusMeters: options.opennessRadiusMeters,
                             geometry: g, minimumStep: options.minimumRayStepMeters)
        let ok = dispatch(encoder, "compute_rrim", width: window.width, height: window.height) { e in
            e.setTexture(elevation, index: 0)
            e.setTexture(display.texture, index: 1)
            e.setTexture(scalar.texture, index: 2)
            Self.setValue(e, GPU.RedRelief(
                width: UInt32(g.width), height: UInt32(g.height),
                destWidth: UInt32(window.width), destHeight: UInt32(window.height),
                originX: UInt32(window.originX), originY: UInt32(window.originY),
                rayCount: UInt32(table.rayCount), stepsPerRay: UInt32(table.stepsPerRay),
                maxReach: Int32(table.maxReach),
                inv8CellX: 1 / (8 * g.cellSizeX), inv8CellY: 1 / (8 * g.cellSizeY),
                slopeMultiplier: options.slopeMultiplier,
                slopeSaturationDegrees: options.rrimSlopeSaturationDegrees,
                opennessRangeDegrees: options.rrimOpennessRangeDegrees
            ), index: 0)
            _ = self.setArray(e, table.steps, index: 1)
        }
        guard ok else { recycle(display); recycle(scalar); return nil }
        return ProductSurfaces(display: display, scalar: scalar)
    }

    private func encodeSkyView(
        _ encoder: any MTLComputeCommandEncoder, elevation: any MTLTexture, raster: ElevationRaster,
        window: DestinationWindow, options: MicroTopographyOptions
    ) -> ProductSurfaces? {
        let g = raster.geometry
        let rw: MTLTextureUsage = [.shaderRead, .shaderWrite]
        guard let display = makeSurface(width: window.width, height: window.height, format: .rgba8Unorm, usage: rw),
              let scalar = makeSurface(width: window.width, height: window.height, format: .r32Float, usage: rw)
        else { return nil }
        let table = dualRadiusRayTable(
            rays: options.svfAzimuthRays,
            microRadiusMeters: options.svfRadiusMeters,
            macroRadiusMeters: options.svfMacroRadiusMeters,
            geometry: g,
            minimumStep: options.minimumRayStepMeters
        )
        let ok = dispatch(encoder, "compute_svf", width: window.width, height: window.height) { e in
            e.setTexture(elevation, index: 0)
            e.setTexture(scalar.texture, index: 1)
            e.setTexture(display.texture, index: 2)
            Self.setValue(e, GPU.SkyView(
                width: UInt32(g.width), height: UInt32(g.height),
                destWidth: UInt32(window.width), destHeight: UInt32(window.height),
                originX: UInt32(window.originX), originY: UInt32(window.originY),
                rayCount: UInt32(table.rayCount),
                microStepsPerRay: UInt32(table.microStepsPerRay),
                macroStepsPerRay: UInt32(table.macroStepsPerRay),
                maxReach: Int32(table.maxReach),
                displayMinimum: options.svfDisplayMinimum,
                blendWeight: options.svfBlendWeight
            ), index: 0)
            _ = self.setArray(e, table.steps, index: 1)
        }
        guard ok else { recycle(display); recycle(scalar); return nil }
        return ProductSurfaces(display: display, scalar: scalar)
    }

    private func encodeRakingLight(
        _ encoder: any MTLComputeCommandEncoder, elevation: any MTLTexture, raster: ElevationRaster,
        window: DestinationWindow, options: MicroTopographyOptions
    ) -> ProductSurfaces? {
        let g = raster.geometry
        let rw: MTLTextureUsage = [.shaderRead, .shaderWrite]
        guard let display = makeSurface(width: window.width, height: window.height, format: .rgba8Unorm, usage: rw),
              let scalar = makeSurface(width: window.width, height: window.height, format: .r32Float, usage: rw)
        else { return nil }
        let ok = dispatch(encoder, "dynamic_raking_hillshade", width: window.width, height: window.height) { e in
            e.setTexture(elevation, index: 0)
            e.setTexture(scalar.texture, index: 1)
            e.setTexture(display.texture, index: 2)
            Self.setValue(e, GPU.RakingLight(
                width: UInt32(g.width), height: UInt32(g.height),
                destWidth: UInt32(window.width), destHeight: UInt32(window.height),
                originX: UInt32(window.originX), originY: UInt32(window.originY),
                inv8CellX: 1 / (8 * g.cellSizeX), inv8CellY: 1 / (8 * g.cellSizeY),
                sunAzimuth: options.sunAzimuthDegrees * .pi / 180,
                sunAltitude: options.sunAltitudeDegrees * .pi / 180,
                zFactor: options.zFactor, ambient: options.ambient
            ), index: 0)
        }
        guard ok else { recycle(display); recycle(scalar); return nil }
        return ProductSurfaces(display: display, scalar: scalar)
    }

    private func encodeRelativeElevation(
        _ encoder: any MTLComputeCommandEncoder, elevation: any MTLTexture, raster: ElevationRaster,
        window: DestinationWindow, options: MicroTopographyOptions, thalweg: [ThalwegVertex],
        palette: any MTLTexture
    ) -> ProductSurfaces? {
        guard !thalweg.isEmpty else { return nil }
        let g = raster.geometry
        let rw: MTLTextureUsage = [.shaderRead, .shaderWrite]
        guard let display = makeSurface(width: window.width, height: window.height, format: .rgba8Unorm, usage: rw),
              let scalar = makeSurface(width: window.width, height: window.height, format: .r32Float, usage: rw)
        else { return nil }
        let segments = ThalwegSegment.makeSegments(from: thalweg)
        let fallback = thalweg.first?.waterSurface ?? 0
        let ok = dispatch(encoder, "detrend_river_elevation", width: window.width, height: window.height) { e in
            e.setTexture(elevation, index: 0)
            e.setTexture(elevation, index: 1)
            e.setTexture(palette, index: 2)
            e.setTexture(scalar.texture, index: 3)
            e.setTexture(display.texture, index: 4)
            Self.setValue(e, GPU.RelativeElevation(
                width: UInt32(g.width), height: UInt32(g.height),
                destWidth: UInt32(window.width), destHeight: UInt32(window.height),
                originX: UInt32(window.originX), originY: UInt32(window.originY),
                segmentCount: UInt32(segments.count), mode: 0,
                cellSizeX: g.cellSizeX, cellSizeY: g.cellSizeY, idwPower: options.remIDWPower,
                rangeMinimum: options.remRange.lowerBound, rangeMaximum: options.remRange.upperBound,
                bandMeters: options.remBandMeters,
                fallbackWaterSurface: fallback
            ), index: 0)
            _ = self.setArray(e, segments, index: 1)
        }
        guard ok else { recycle(display); recycle(scalar); return nil }
        return ProductSurfaces(display: display, scalar: scalar)
    }

    private func encodeCurvature(
        _ encoder: any MTLComputeCommandEncoder, elevation: any MTLTexture, raster: ElevationRaster,
        window: DestinationWindow
    ) -> ProductSurfaces? {
        let g = raster.geometry
        let rw: MTLTextureUsage = [.shaderRead, .shaderWrite]
        guard let display = makeSurface(width: window.width, height: window.height, format: .rgba8Unorm, usage: rw),
              let scalar = makeSurface(width: window.width, height: window.height, format: .rg32Float, usage: rw)
        else { return nil }
        let ok = dispatch(encoder, "compute_topographic_curvature", width: window.width, height: window.height) { e in
            e.setTexture(elevation, index: 0)
            e.setTexture(scalar.texture, index: 1)
            e.setTexture(display.texture, index: 2)
            Self.setValue(e, GPU.Curvature(
                width: UInt32(g.width), height: UInt32(g.height),
                destWidth: UInt32(window.width), destHeight: UInt32(window.height),
                originX: UInt32(window.originX), originY: UInt32(window.originY),
                cellSizeX: g.cellSizeX, cellSizeY: g.cellSizeY
            ), index: 0)
        }
        guard ok else { recycle(display); recycle(scalar); return nil }
        return ProductSurfaces(display: display, scalar: scalar)
    }

    private func encodeDirectionalOcclusion(
        _ encoder: any MTLComputeCommandEncoder, elevation: any MTLTexture, raster: ElevationRaster,
        window: DestinationWindow, options: MicroTopographyOptions
    ) -> ProductSurfaces? {
        let g = raster.geometry
        let rw: MTLTextureUsage = [.shaderRead, .shaderWrite]
        guard let display = makeSurface(width: window.width, height: window.height, format: .rgba8Unorm, usage: rw),
              let scalar = makeSurface(width: window.width, height: window.height, format: .r32Float, usage: rw)
        else { return nil }
        let ok = dispatch(encoder, "compute_directional_occlusion", width: window.width, height: window.height) { e in
            e.setTexture(elevation, index: 0)
            e.setTexture(scalar.texture, index: 1)
            e.setTexture(display.texture, index: 2)
            Self.setValue(e, GPU.DirectionalOcclusion(
                width: UInt32(g.width), height: UInt32(g.height),
                destWidth: UInt32(window.width), destHeight: UInt32(window.height),
                originX: UInt32(window.originX), originY: UInt32(window.originY),
                sunAzimuth: options.directionalOcclusionAzimuthDegrees * .pi / 180,
                sunAltitude: options.directionalOcclusionAltitudeDegrees * .pi / 180,
                maxDistanceMeters: options.directionalOcclusionDistanceMeters,
                cellSizeX: g.cellSizeX, cellSizeY: g.cellSizeY
            ), index: 0)
        }
        guard ok else { recycle(display); recycle(scalar); return nil }
        return ProductSurfaces(display: display, scalar: scalar)
    }

    private func encodeOpennessSplit(
        _ encoder: any MTLComputeCommandEncoder, elevation: any MTLTexture, raster: ElevationRaster,
        window: DestinationWindow, options: MicroTopographyOptions, mode: UInt32
    ) -> ProductSurfaces? {
        let g = raster.geometry
        let rw: MTLTextureUsage = [.shaderRead, .shaderWrite]
        guard let display = makeSurface(width: window.width, height: window.height, format: .rgba8Unorm, usage: rw),
              let scalar = makeSurface(width: window.width, height: window.height, format: .r32Float, usage: rw)
        else { return nil }
        let table = rayTable(rays: options.rrimAzimuthRays, radiusMeters: options.opennessRadiusMeters,
                             geometry: g, minimumStep: options.minimumRayStepMeters)
        let ok = dispatch(encoder, "compute_openness_split", width: window.width, height: window.height) { e in
            e.setTexture(elevation, index: 0)
            e.setTexture(scalar.texture, index: 1)
            e.setTexture(display.texture, index: 2)
            Self.setValue(e, GPU.OpennessSplit(
                width: UInt32(g.width), height: UInt32(g.height),
                destWidth: UInt32(window.width), destHeight: UInt32(window.height),
                originX: UInt32(window.originX), originY: UInt32(window.originY),
                rayCount: UInt32(table.rayCount), stepsPerRay: UInt32(table.stepsPerRay),
                maxReach: Int32(table.maxReach),
                mode: mode
            ), index: 0)
            _ = self.setArray(e, table.steps, index: 1)
        }
        guard ok else { recycle(display); recycle(scalar); return nil }
        return ProductSurfaces(display: display, scalar: scalar)
    }

    private func encodeVectorRuggedness(
        _ encoder: any MTLComputeCommandEncoder, elevation: any MTLTexture, raster: ElevationRaster,
        window: DestinationWindow, options: MicroTopographyOptions
    ) -> ProductSurfaces? {
        let g = raster.geometry
        let rw: MTLTextureUsage = [.shaderRead, .shaderWrite]
        guard let display = makeSurface(width: window.width, height: window.height, format: .rgba8Unorm, usage: rw),
              let scalar = makeSurface(width: window.width, height: window.height, format: .r32Float, usage: rw)
        else { return nil }
        let ok = dispatch(encoder, "compute_vector_ruggedness", width: window.width, height: window.height) { e in
            e.setTexture(elevation, index: 0)
            e.setTexture(scalar.texture, index: 1)
            e.setTexture(display.texture, index: 2)
            Self.setValue(e, GPU.VRM(
                width: UInt32(g.width), height: UInt32(g.height),
                destWidth: UInt32(window.width), destHeight: UInt32(window.height),
                originX: UInt32(window.originX), originY: UInt32(window.originY),
                inv8CellX: 1.0 / (8.0 * g.cellSizeX), inv8CellY: 1.0 / (8.0 * g.cellSizeY),
                maxDisplayVRM: options.vrmMaxDisplay
            ), index: 0)
        }
        guard ok else { recycle(display); recycle(scalar); return nil }
        return ProductSurfaces(display: display, scalar: scalar)
    }

    private func encodeDifferenceOfGaussians(
        _ encoder: any MTLComputeCommandEncoder, elevation: any MTLTexture, raster: ElevationRaster,
        window: DestinationWindow, options: MicroTopographyOptions, temporaries: inout [Surface]
    ) -> ProductSurfaces? {
        let g = raster.geometry
        let rw: MTLTextureUsage = [.shaderRead, .shaderWrite]
        guard let sums1 = makeSurface(width: g.width, height: g.height, format: .rg32Float, usage: rw),
              let lowpass1 = makeSurface(width: g.width, height: g.height, format: .r32Float, usage: rw),
              let sums2 = makeSurface(width: g.width, height: g.height, format: .rg32Float, usage: rw),
              let lowpass2 = makeSurface(width: g.width, height: g.height, format: .r32Float, usage: rw),
              let residual = makeSurface(width: window.width, height: window.height, format: .r32Float, usage: rw),
              let display = makeSurface(width: window.width, height: window.height, format: .rgba8Unorm, usage: rw)
        else { return nil }
        temporaries.append(contentsOf: [sums1, lowpass1, sums2, lowpass2])

        let reference = Self.referenceElevation(raster.samples, count: g.count)
        let taps1X = GaussianTaps(radiusMeters: options.dogSigma1Meters * 2, cellSize: g.cellSizeX)
        let taps1Y = GaussianTaps(radiusMeters: options.dogSigma1Meters * 2, cellSize: g.cellSizeY)
        let taps2X = GaussianTaps(radiusMeters: options.dogSigma2Meters * 2, cellSize: g.cellSizeX)
        let taps2Y = GaussianTaps(radiusMeters: options.dogSigma2Meters * 2, cellSize: g.cellSizeY)

        // Lowpass 1 (sigma 1)
        var ok = dispatch(encoder, "lrm_gaussian_horizontal", width: g.width, height: g.height) { e in
            e.setTexture(elevation, index: 0)
            e.setTexture(sums1.texture, index: 1)
            Self.setValue(e, GPU.GaussianPass(width: UInt32(g.width), height: UInt32(g.height),
                                              radius: Int32(taps1X.radius), referenceElevation: reference), index: 0)
            _ = self.setArray(e, taps1X.weights, index: 1)
        }
        ok = ok && dispatch(encoder, "lrm_gaussian_vertical", width: g.width, height: g.height) { e in
            e.setTexture(sums1.texture, index: 0)
            e.setTexture(lowpass1.texture, index: 1)
            Self.setValue(e, GPU.GaussianPass(width: UInt32(g.width), height: UInt32(g.height),
                                              radius: Int32(taps1Y.radius), referenceElevation: reference), index: 0)
            _ = self.setArray(e, taps1Y.weights, index: 1)
        }

        // Lowpass 2 (sigma 2)
        ok = ok && dispatch(encoder, "lrm_gaussian_horizontal", width: g.width, height: g.height) { e in
            e.setTexture(elevation, index: 0)
            e.setTexture(sums2.texture, index: 1)
            Self.setValue(e, GPU.GaussianPass(width: UInt32(g.width), height: UInt32(g.height),
                                              radius: Int32(taps2X.radius), referenceElevation: reference), index: 0)
            _ = self.setArray(e, taps2X.weights, index: 1)
        }
        ok = ok && dispatch(encoder, "lrm_gaussian_vertical", width: g.width, height: g.height) { e in
            e.setTexture(sums2.texture, index: 0)
            e.setTexture(lowpass2.texture, index: 1)
            Self.setValue(e, GPU.GaussianPass(width: UInt32(g.width), height: UInt32(g.height),
                                              radius: Int32(taps2Y.radius), referenceElevation: reference), index: 0)
            _ = self.setArray(e, taps2Y.weights, index: 1)
        }

        // DoG residual
        ok = ok && dispatch(encoder, "dog_residual_to_texture", width: window.width, height: window.height) { e in
            e.setTexture(lowpass1.texture, index: 0)
            e.setTexture(lowpass2.texture, index: 1)
            e.setTexture(residual.texture, index: 2)
            e.setTexture(display.texture, index: 3)
            Self.setValue(e, GPU.LocalRelief(
                destWidth: UInt32(window.width), destHeight: UInt32(window.height),
                originX: UInt32(window.originX), originY: UInt32(window.originY),
                referenceElevation: 0, scaleMeters: options.lrmScaleMeters,
                colorMode: options.lrmDiverging ? 1 : 0
            ), index: 0)
        }

        guard ok else {
            recycle(residual)
            recycle(display)
            return nil
        }
        return ProductSurfaces(display: display, scalar: residual)
    }

    /// Jump-flood step schedule: from the power of two at or above the radius
    /// (in cells) down to 1, then 2 and 1 again (JFA+2), which removes the
    /// rare seeds plain JFA propagates to the wrong cell.
    nonisolated static func jumpFloodSteps(radiusCells: Int, maxDimension: Int) -> [Int] {
        var k = 1
        let limit = max(min(radiusCells, maxDimension), 1)
        while k < limit { k <<= 1 }
        var steps: [Int] = []
        while k >= 1 {
            steps.append(k)
            k >>= 1
        }
        if steps.count > 1 { steps.append(contentsOf: [2, 1]) }
        return steps
    }

    private func encodeHabitation(
        _ encoder: any MTLComputeCommandEncoder, elevation: any MTLTexture, raster: ElevationRaster,
        window: DestinationWindow, options: MicroTopographyOptions, temporaries: inout [Surface]
    ) -> ProductSurfaces? {
        let g = raster.geometry
        let rw: MTLTextureUsage = [.shaderRead, .shaderWrite]
        guard let slope = makeSurface(width: g.width, height: g.height, format: .r32Float, usage: rw),
              let seedsA = makeSurface(width: g.width, height: g.height, format: .rg32Float, usage: rw),
              let seedsB = makeSurface(width: g.width, height: g.height, format: .rg32Float, usage: rw),
              let mask = makeSurface(width: window.width, height: window.height, format: .r32Float, usage: rw),
              let display = makeSurface(width: window.width, height: window.height, format: .rgba8Unorm, usage: rw)
        else { return nil }
        temporaries.append(contentsOf: [slope, seedsA, seedsB])

        var ok = dispatch(encoder, "habitation_slope_seed", width: g.width, height: g.height) { e in
            e.setTexture(elevation, index: 0)
            e.setTexture(slope.texture, index: 1)
            e.setTexture(seedsA.texture, index: 2)
            Self.setValue(e, GPU.HabitationSeed(
                width: UInt32(g.width), height: UInt32(g.height),
                inv8CellX: 1 / (8 * g.cellSizeX), inv8CellY: 1 / (8 * g.cellSizeY),
                steepSlopeMinimumDegrees: options.steepSlopeMinimumDegrees
            ), index: 0)
        }
        let radiusCells = Int((options.habitationRadiusMeters / min(g.cellSizeX, g.cellSizeY)).rounded(.up))
        var read = seedsA
        var write = seedsB
        for step in Self.jumpFloodSteps(radiusCells: radiusCells, maxDimension: max(g.width, g.height)) {
            let source = read, destination = write
            ok = ok && dispatch(encoder, "habitation_jump_flood", width: g.width, height: g.height) { e in
                e.setTexture(source.texture, index: 0)
                e.setTexture(destination.texture, index: 1)
                Self.setValue(e, GPU.JumpFlood(
                    width: UInt32(g.width), height: UInt32(g.height), step: Int32(step),
                    cellSizeX: g.cellSizeX, cellSizeY: g.cellSizeY
                ), index: 0)
            }
            swap(&read, &write)
        }
        let seeds = read
        ok = ok && dispatch(encoder, "evaluate_habitation_potential", width: window.width, height: window.height) { e in
            e.setTexture(slope.texture, index: 0)
            e.setTexture(seeds.texture, index: 1)
            e.setTexture(mask.texture, index: 2)
            e.setTexture(display.texture, index: 3)
            Self.setValue(e, GPU.Habitation(
                width: UInt32(g.width), height: UInt32(g.height),
                destWidth: UInt32(window.width), destHeight: UInt32(window.height),
                originX: UInt32(window.originX), originY: UInt32(window.originY),
                cellSizeX: g.cellSizeX, cellSizeY: g.cellSizeY,
                flatSlopeMaximumDegrees: options.flatSlopeMaximumDegrees,
                radiusMeters: options.habitationRadiusMeters,
                highlightRed: 1.0, highlightGreen: 0.72, highlightBlue: 0.0, highlightAlpha: 0.8
            ), index: 0)
        }
        guard ok else { recycle(mask); recycle(display); return nil }
        return ProductSurfaces(display: display, scalar: mask)
    }

    // MARK: - Products

    /// Produces one micro-topography product over `window`, optionally
    /// composited with contours, the habitation mask and sky-view shading at
    /// `outputScale` times the window's resolution.
    ///
    /// Returns `nil` when the pipeline is unavailable, the window does not fit
    /// the raster, or (for `.relativeElevation`) no thalweg is given.
    public func render(
        _ product: MicroTopographyProduct,
        raster: ElevationRaster,
        window requestedWindow: DestinationWindow? = nil,
        options: MicroTopographyOptions = MicroTopographyOptions(),
        thalweg: [ThalwegVertex] = [],
        overlays: CompositeOverlays = CompositeOverlays(),
        outputScale: Int = 1
    ) async -> MicroTopographyResult? {
        let signpost = Signpost.raster.beginInterval("microTopography")
        defer { Signpost.raster.endInterval("microTopography", signpost) }

        prepareIfNeeded()
        let g = raster.geometry
        let window = requestedWindow ?? .full(g)
        guard let queue, let compositePipeline,
              g.width >= 3, g.height >= 3, window.width > 0, window.height > 0,
              window.originX >= 0, window.originY >= 0,
              window.originX + window.width <= g.width, window.originY + window.height <= g.height,
              g.cellSizeX > 0, g.cellSizeY > 0,
              product != .relativeElevation || !thalweg.isEmpty,
              let commandBuffer = queue.makeCommandBuffer()
        else { return nil }
        commandBuffer.label = "microTopography.\(product.rawValue)"

        var temporaries: [Surface] = []
        var retained: [AnyObject] = []

        func abandon(_ extra: [Surface]) {
            for s in temporaries + extra { recycle(s) }
        }

        // Static textures first: in blit mode their uploads must precede use.
        let palette = product == .relativeElevation
            ? relativeElevationPalette(range: options.remRange, commandBuffer: commandBuffer) : nil
        let placeholderMask = transparentPlaceholder(commandBuffer)
        let placeholderSky = unitPlaceholder(commandBuffer)

        guard let elevation = bindElevation(raster, commandBuffer: commandBuffer, temporaries: &temporaries, retained: &retained),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { abandon([]); return nil }

        if raster.needsNoDataNormalization, !encodeNoData(encoder, elevation: elevation.texture, raster: raster) {
            encoder.endEncoding()
            abandon([])
            return nil
        }

        let produced: ProductSurfaces?
        switch product {
        case .localRelief:
            produced = encodeLocalRelief(encoder, elevation: elevation.texture, raster: raster, window: window,
                                         options: options, temporaries: &temporaries)
        case .redRelief:
            produced = encodeRedRelief(encoder, elevation: elevation.texture, raster: raster, window: window, options: options)
        case .skyView:
            produced = encodeSkyView(encoder, elevation: elevation.texture, raster: raster, window: window, options: options)
        case .rakingLight:
            produced = encodeRakingLight(encoder, elevation: elevation.texture, raster: raster, window: window, options: options)
        case .relativeElevation:
            if let palette {
                produced = encodeRelativeElevation(encoder, elevation: elevation.texture, raster: raster, window: window,
                                                   options: options, thalweg: thalweg, palette: palette)
            } else {
                produced = nil
            }
        case .habitation:
            produced = encodeHabitation(encoder, elevation: elevation.texture, raster: raster, window: window,
                                        options: options, temporaries: &temporaries)
        case .curvature:
            produced = encodeCurvature(encoder, elevation: elevation.texture, raster: raster, window: window)
        case .directionalOcclusion:
            produced = encodeDirectionalOcclusion(encoder, elevation: elevation.texture, raster: raster, window: window, options: options)
        case .positiveOpenness:
            produced = encodeOpennessSplit(encoder, elevation: elevation.texture, raster: raster, window: window, options: options, mode: 0)
        case .negativeOpenness:
            produced = encodeOpennessSplit(encoder, elevation: elevation.texture, raster: raster, window: window, options: options, mode: 1)
        case .vectorRuggedness:
            produced = encodeVectorRuggedness(encoder, elevation: elevation.texture, raster: raster, window: window, options: options)
        case .differenceOfGaussians:
            produced = encodeDifferenceOfGaussians(encoder, elevation: elevation.texture, raster: raster, window: window, options: options, temporaries: &temporaries)
        }
        guard let produced else {
            encoder.endEncoding()
            abandon([])
            return nil
        }

        // Overlay inputs the composite needs, reusing the product where it is one.
        var habitationDisplay: Surface?
        var skyScalar: Surface?
        if overlays.habitationOpacity > 0 {
            if product == .habitation {
                habitationDisplay = produced.display
            } else if let h = encodeHabitation(encoder, elevation: elevation.texture, raster: raster, window: window,
                                               options: options, temporaries: &temporaries) {
                temporaries.append(contentsOf: [h.display, h.scalar])
                habitationDisplay = h.display
            }
        }
        if overlays.skyViewStrength > 0 {
            if product == .skyView {
                skyScalar = produced.scalar
            } else if let s = encodeSkyView(encoder, elevation: elevation.texture, raster: raster, window: window, options: options) {
                temporaries.append(contentsOf: [s.display, s.scalar])
                skyScalar = s.scalar
            }
        }
        encoder.endEncoding()

        var finalDisplay = produced.display
        if !overlays.isEmpty {
            let scale = max(outputScale, 1)
            guard let target = makeSurface(width: window.width * scale, height: window.height * scale,
                                           format: .rgba8Unorm, usage: [.renderTarget, .shaderRead]),
                  let placeholderMask, let placeholderSky
            else { abandon([produced.display, produced.scalar]); return nil }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target.texture
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let render = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                abandon([produced.display, produced.scalar, target])
                return nil
            }
            var uniforms = GPU.Composite(
                elevationWidth: UInt32(g.width), elevationHeight: UInt32(g.height),
                originX: UInt32(window.originX), originY: UInt32(window.originY),
                destWidth: UInt32(window.width), destHeight: UInt32(window.height),
                contourInterval: overlays.contourIntervalMeters, indexInterval: overlays.indexIntervalMeters,
                habitationOpacity: habitationDisplay == nil ? 0 : overlays.habitationOpacity,
                skyViewStrength: skyScalar == nil ? 0 : overlays.skyViewStrength
            )
            render.setRenderPipelineState(compositePipeline)
            render.setFragmentTexture(produced.display.texture, index: 0)
            render.setFragmentTexture(elevation.texture, index: 1)
            render.setFragmentTexture(habitationDisplay?.texture ?? placeholderMask, index: 2)
            render.setFragmentTexture(skyScalar?.texture ?? placeholderSky, index: 3)
            render.setFragmentBytes(&uniforms, length: MemoryLayout<GPU.Composite>.stride, index: 0)
            render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            render.endEncoding()
            temporaries.append(produced.display)
            finalDisplay = target
        }

        guard let displayOut = prepareOutput(finalDisplay, commandBuffer: commandBuffer, temporaries: &temporaries),
              let scalarOut = prepareOutput(produced.scalar, commandBuffer: commandBuffer, temporaries: &temporaries)
        else { abandon([finalDisplay, produced.scalar]); return nil }

        let (succeeded, milliseconds) = await complete(commandBuffer)
        withExtendedLifetime(retained) {}
        for s in temporaries { recycle(s) }

        guard succeeded else {
            recycleBuffer(displayOut.buffer)
            recycleBuffer(scalarOut.buffer)
            return nil
        }
        return MicroTopographyResult(
            product: product,
            display: DisplayBitmap(lease: makeLease(buffer: displayOut.buffer, width: finalDisplay.width,
                                                     height: finalDisplay.height, bytesPerRow: displayOut.bytesPerRow,
                                                     bytesPerPixel: 4)),
            scalar: ScalarPlane(lease: makeLease(buffer: scalarOut.buffer, width: produced.scalar.width,
                                                  height: produced.scalar.height, bytesPerRow: scalarOut.bytesPerRow,
                                                  bytesPerPixel: 4)),
            gpuMilliseconds: milliseconds,
            elevationBinding: elevation.binding
        )
    }

    private struct PreparedOutput {
        let buffer: any MTLBuffer
        let bytesPerRow: Int
    }

    /// The buffer an output leaves in. Linear surfaces already are one; a
    /// private texture is blitted into a pooled shared buffer.
    private func prepareOutput(
        _ surface: Surface, commandBuffer: any MTLCommandBuffer, temporaries: inout [Surface]
    ) -> PreparedOutput? {
        if let buffer = surface.buffer {
            return PreparedOutput(buffer: buffer, bytesPerRow: surface.bytesPerRow)
        }
        let bytesPerRow = surface.width * surface.bytesPerPixel
        guard let buffer = obtainBuffer(length: bytesPerRow * surface.height),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else { return nil }
        blit.copy(
            from: surface.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: surface.width, height: surface.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * surface.height
        )
        blit.endEncoding()
        temporaries.append(surface)
        return PreparedOutput(buffer: buffer, bytesPerRow: bytesPerRow)
    }

    /// Commits and awaits completion through a handler, so no thread waits on
    /// the GPU. Returns success and the GPU execution time in milliseconds.
    private func complete(_ commandBuffer: any MTLCommandBuffer) async -> (Bool, Double) {
        await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { cb in
                let ok = cb.error == nil && cb.status == .completed
                continuation.resume(returning: (ok, max(cb.gpuEndTime - cb.gpuStartTime, 0) * 1000))
            }
            commandBuffer.commit()
        }
    }

    // MARK: - Nodata

    /// Runs only the nodata pass over `raster`, in the caller's own memory.
    ///
    /// Only meaningful where the pass writes that memory, so this returns
    /// `true` solely when the raster bound zero-copy and the GPU rewrote its
    /// sentinels. Anything else -- no GPU, blit-mode surfaces, a misaligned row
    /// stride, a heap array -- returns `false` and the caller normalises on the
    /// CPU instead.
    public func normalizeNoDataInPlace(_ raster: ElevationRaster) async -> Bool {
        prepareIfNeeded()
        guard let queue, surfaceMode == .linear, case .mapped = raster.samples,
              let commandBuffer = queue.makeCommandBuffer()
        else { return false }
        commandBuffer.label = "microTopography.nodata"
        var temporaries: [Surface] = []
        var retained: [AnyObject] = []
        guard let bound = bindElevation(raster, commandBuffer: commandBuffer, temporaries: &temporaries, retained: &retained),
              bound.binding == .zeroCopy,
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            for s in temporaries { recycle(s) }
            return false
        }
        let encoded = encodeNoData(encoder, elevation: bound.texture, raster: raster)
        encoder.endEncoding()
        let (succeeded, _) = await complete(commandBuffer)
        withExtendedLifetime(retained) {}
        return encoded && succeeded
    }

    // MARK: - Viewshed

    /// Radial-sweep viewshed from a fractional observer cell.
    ///
    /// `eyeHeight` is added to the observer's ground and `targetHeight` to every
    /// target cell. Returns `nil` when the pipeline is unavailable or the
    /// observer is outside the raster or over a void.
    public func viewshed(
        raster: ElevationRaster,
        observerColumn: Float,
        observerRow: Float,
        eyeHeight: Float = 2.0,
        targetHeight: Float = 0.5,
        maxRadiusMeters: Float,
        angularSteps: Int = 720,
        highlight: SIMD4<Float> = SIMD4(0.16, 0.78, 0.42, 0.55)
    ) async -> ViewshedResult? {
        let signpost = Signpost.raster.beginInterval("viewshedSweep")
        defer { Signpost.raster.endInterval("viewshedSweep", signpost) }

        prepareIfNeeded()
        let g = raster.geometry
        guard let queue, g.width >= 2, g.height >= 2, maxRadiusMeters > 0, angularSteps > 0,
              let ground = Self.sampleBilinear(raster.samples, g, x: observerColumn, y: observerRow),
              let commandBuffer = queue.makeCommandBuffer()
        else { return nil }
        commandBuffer.label = "microTopography.viewshed"

        let stepMeters = MicroTopographyReference.viewshedStepMeters(g, maxRadiusMeters: maxRadiusMeters)
        let radialSteps = max(Int((maxRadiusMeters / stepMeters).rounded(.up)), 1)
        var temporaries: [Surface] = []
        var retained: [AnyObject] = []

        guard let horizon = obtainBuffer(length: angularSteps * radialSteps * MemoryLayout<Float>.stride),
              let elevation = bindElevation(raster, commandBuffer: commandBuffer, temporaries: &temporaries, retained: &retained),
              let mask = makeSurface(width: g.width, height: g.height, format: .r32Float, usage: [.shaderRead, .shaderWrite]),
              let display = makeSurface(width: g.width, height: g.height, format: .rgba8Unorm, usage: [.shaderRead, .shaderWrite]),
              let encoder = commandBuffer.makeComputeCommandEncoder(),
              let sweep = computePipelines["viewshed_radial_sweep"]
        else {
            for s in temporaries { recycle(s) }
            return nil
        }

        if raster.needsNoDataNormalization {
            _ = encodeNoData(encoder, elevation: elevation.texture, raster: raster)
        }
        let sweepUniforms = GPU.ViewshedSweep(
            width: UInt32(g.width), height: UInt32(g.height),
            angularSteps: UInt32(angularSteps), radialSteps: UInt32(radialSteps),
            observerX: observerColumn, observerY: observerRow, eyeElevation: ground + eyeHeight,
            cellSizeX: g.cellSizeX, cellSizeY: g.cellSizeY, stepMeters: stepMeters
        )
        encoder.setComputePipelineState(sweep)
        encoder.setTexture(elevation.texture, index: 0)
        encoder.setBuffer(horizon, offset: 0, index: 0)
        Self.setValue(encoder, sweepUniforms, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: angularSteps, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: max(min(sweep.threadExecutionWidth, angularSteps), 1), height: 1, depth: 1)
        )
        _ = dispatch(encoder, "compute_viewshed", width: g.width, height: g.height) { e in
            e.setTexture(elevation.texture, index: 0)
            e.setBuffer(horizon, offset: 0, index: 0)
            e.setTexture(mask.texture, index: 1)
            e.setTexture(display.texture, index: 2)
            Self.setValue(e, GPU.ViewshedMask(
                width: UInt32(g.width), height: UInt32(g.height),
                angularSteps: UInt32(angularSteps), radialSteps: UInt32(radialSteps),
                observerX: observerColumn, observerY: observerRow, eyeElevation: ground + eyeHeight,
                targetHeight: targetHeight, cellSizeX: g.cellSizeX, cellSizeY: g.cellSizeY,
                stepMeters: stepMeters, maxRadiusMeters: maxRadiusMeters,
                highlightRed: highlight.x, highlightGreen: highlight.y,
                highlightBlue: highlight.z, highlightAlpha: highlight.w
            ), index: 1)
        }
        encoder.endEncoding()

        guard let displayOut = prepareOutput(display, commandBuffer: commandBuffer, temporaries: &temporaries),
              let maskOut = prepareOutput(mask, commandBuffer: commandBuffer, temporaries: &temporaries)
        else {
            for s in temporaries { recycle(s) }
            recycleBuffer(horizon)
            return nil
        }

        let (succeeded, milliseconds) = await complete(commandBuffer)
        withExtendedLifetime(retained) {}
        for s in temporaries { recycle(s) }
        recycleBuffer(horizon)
        guard succeeded else {
            recycleBuffer(displayOut.buffer)
            recycleBuffer(maskOut.buffer)
            return nil
        }
        return ViewshedResult(
            display: DisplayBitmap(lease: makeLease(buffer: displayOut.buffer, width: g.width, height: g.height,
                                                     bytesPerRow: displayOut.bytesPerRow, bytesPerPixel: 4)),
            mask: ScalarPlane(lease: makeLease(buffer: maskOut.buffer, width: g.width, height: g.height,
                                                bytesPerRow: maskOut.bytesPerRow, bytesPerPixel: 4)),
            gpuMilliseconds: milliseconds,
            elevationBinding: elevation.binding
        )
    }
}

// MARK: - Uniform mirrors

/// Swift mirrors of the uniform structs in `TerrainKernels.metal`. Every field
/// is a 4-byte scalar in both languages and the order matches, so the layouts
/// are identical with no padding to reason about.
private nonisolated enum GPU {
    struct NoData {
        var width: UInt32
        var height: UInt32
        var noDataValue: Float
        var hasNoDataValue: UInt32
        var validMinimum: Float
        var validMaximum: Float
    }

    struct GaussianPass {
        var width: UInt32
        var height: UInt32
        var radius: Int32
        var referenceElevation: Float
    }

    struct LocalRelief {
        var destWidth: UInt32
        var destHeight: UInt32
        var originX: UInt32
        var originY: UInt32
        var referenceElevation: Float
        var scaleMeters: Float
        var colorMode: UInt32
    }

    struct RedRelief {
        var width: UInt32
        var height: UInt32
        var destWidth: UInt32
        var destHeight: UInt32
        var originX: UInt32
        var originY: UInt32
        var rayCount: UInt32
        var stepsPerRay: UInt32
        var maxReach: Int32
        var inv8CellX: Float
        var inv8CellY: Float
        var slopeMultiplier: Float
        var slopeSaturationDegrees: Float
        var opennessRangeDegrees: Float
    }

    struct SkyView {
        var width: UInt32
        var height: UInt32
        var destWidth: UInt32
        var destHeight: UInt32
        var originX: UInt32
        var originY: UInt32
        var rayCount: UInt32
        var microStepsPerRay: UInt32
        var macroStepsPerRay: UInt32
        var maxReach: Int32
        var displayMinimum: Float
        var blendWeight: Float
    }

    struct RakingLight {
        var width: UInt32
        var height: UInt32
        var destWidth: UInt32
        var destHeight: UInt32
        var originX: UInt32
        var originY: UInt32
        var inv8CellX: Float
        var inv8CellY: Float
        var sunAzimuth: Float
        var sunAltitude: Float
        var zFactor: Float
        var ambient: Float
    }

    struct RelativeElevation {
        var width: UInt32
        var height: UInt32
        var destWidth: UInt32
        var destHeight: UInt32
        var originX: UInt32
        var originY: UInt32
        var segmentCount: UInt32
        var mode: UInt32
        var cellSizeX: Float
        var cellSizeY: Float
        var idwPower: Float
        var rangeMinimum: Float
        var rangeMaximum: Float
        var bandMeters: Float
        var fallbackWaterSurface: Float
    }

    struct Curvature {
        var width: UInt32
        var height: UInt32
        var destWidth: UInt32
        var destHeight: UInt32
        var originX: UInt32
        var originY: UInt32
        var cellSizeX: Float
        var cellSizeY: Float
    }

    struct HabitationSeed {
        var width: UInt32
        var height: UInt32
        var inv8CellX: Float
        var inv8CellY: Float
        var steepSlopeMinimumDegrees: Float
    }

    struct JumpFlood {
        var width: UInt32
        var height: UInt32
        var step: Int32
        var cellSizeX: Float
        var cellSizeY: Float
    }

    struct Habitation {
        var width: UInt32
        var height: UInt32
        var destWidth: UInt32
        var destHeight: UInt32
        var originX: UInt32
        var originY: UInt32
        var cellSizeX: Float
        var cellSizeY: Float
        var flatSlopeMaximumDegrees: Float
        var radiusMeters: Float
        var highlightRed: Float
        var highlightGreen: Float
        var highlightBlue: Float
        var highlightAlpha: Float
    }

    struct ViewshedSweep {
        var width: UInt32
        var height: UInt32
        var angularSteps: UInt32
        var radialSteps: UInt32
        var observerX: Float
        var observerY: Float
        var eyeElevation: Float
        var cellSizeX: Float
        var cellSizeY: Float
        var stepMeters: Float
    }

    struct ViewshedMask {
        var width: UInt32
        var height: UInt32
        var angularSteps: UInt32
        var radialSteps: UInt32
        var observerX: Float
        var observerY: Float
        var eyeElevation: Float
        var targetHeight: Float
        var cellSizeX: Float
        var cellSizeY: Float
        var stepMeters: Float
        var maxRadiusMeters: Float
        var highlightRed: Float
        var highlightGreen: Float
        var highlightBlue: Float
        var highlightAlpha: Float
    }

    struct Composite {
        var elevationWidth: UInt32
        var elevationHeight: UInt32
        var originX: UInt32
        var originY: UInt32
        var destWidth: UInt32
        var destHeight: UInt32
        var contourInterval: Float
        var indexInterval: Float
        var habitationOpacity: Float
        var skyViewStrength: Float
    }

    struct DirectionalOcclusion {
        var width: UInt32
        var height: UInt32
        var destWidth: UInt32
        var destHeight: UInt32
        var originX: UInt32
        var originY: UInt32
        var sunAzimuth: Float
        var sunAltitude: Float
        var maxDistanceMeters: Float
        var cellSizeX: Float
        var cellSizeY: Float
    }

    struct OpennessSplit {
        var width: UInt32
        var height: UInt32
        var destWidth: UInt32
        var destHeight: UInt32
        var originX: UInt32
        var originY: UInt32
        var rayCount: UInt32
        var stepsPerRay: UInt32
        var maxReach: Int32
        var mode: UInt32
    }

    struct VRM {
        var width: UInt32
        var height: UInt32
        var destWidth: UInt32
        var destHeight: UInt32
        var originX: UInt32
        var originY: UInt32
        var inv8CellX: Float
        var inv8CellY: Float
        var maxDisplayVRM: Float
    }

    struct RobustTrend {
        var width: UInt32
        var height: UInt32
        var radius: Int32
        var referenceElevation: Float
        var invRadius: Float
        var invTukeyC: Float
        var minimumSupport: Float
        var hasPrevious: UInt32
    }
}
