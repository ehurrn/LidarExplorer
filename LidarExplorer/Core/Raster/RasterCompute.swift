//
//  RasterCompute.swift
//  LidarExplorer
//
//  GPU-accelerated terrain rasters with a transparent CPU fallback.
//

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
    private var setupAttempted = false

    private struct PooledBuffers {
        let elevation: any MTLBuffer
        let slope: any MTLBuffer
        let aspect: any MTLBuffer
        let relief: any MTLBuffer
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
            let relief = device.makeBuffer(length: byteCount, options: options)
        else { return nil }
        return PooledBuffers(
            elevation: elevation, slope: slope,
            aspect: aspect, relief: relief, byteCount: byteCount
        )
    }

    private func releaseBuffers(_ buffers: PooledBuffers) {
        var list = bufferPool[buffers.byteCount] ?? []
        if list.count < maxBuffersPerSize {
            list.append(buffers)
            bufferPool[buffers.byteCount] = list
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
            if let slopeFn = library.makeFunction(name: "horn_slope_aspect"),
               let reliefFn = library.makeFunction(name: "multidirectional_relief") {
                slopeAspectPipeline = try device.makeComputePipelineState(function: slopeFn)
                reliefPipeline = try device.makeComputePipelineState(function: reliefFn)
            }
            Log.shader.info("Metal terrain pipelines compiled successfully on \(device.name, privacy: .public).")
        } catch {
            Log.shader.error("Pipeline construction failed: \(error.localizedDescription, privacy: .public)")
            fusedPipeline = nil
            slopeAspectPipeline = nil
            reliefPipeline = nil
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
            encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 4)
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

        releaseBuffers(buffers)

        return ReliefProducts(
            slopeDegrees: slope,
            aspectDegrees: aspect,
            multiDirectionalRelief: relief,
            width: grid.width,
            height: grid.height,
            backend: .gpu
        )
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
