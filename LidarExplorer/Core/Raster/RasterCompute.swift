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
            height: height
        )
    }
}

/// Owns the Metal device and pipeline states for terrain compute.
///
/// An `actor` because `MTLDevice`, `MTLCommandQueue`, and the pipeline states
/// are reference types with no `Sendable` guarantee. Confining them to a
/// single isolation domain is what makes this safe under complete strict
/// concurrency, rather than papering over it with `@unchecked Sendable`.
///
/// Pipeline construction is expensive and happens once, lazily, on first use.
public actor RasterCompute {

    public enum Backend: String, Sendable {
        case gpu
        case cpu
    }

    /// Cells below which a GPU round trip costs more than it saves.
    ///
    /// Buffer allocation, encode, commit, and the wait for completion run in
    /// the tens of microseconds. Horn's kernel over a small grid finishes well
    /// inside that on the CPU, so dispatching would be a pure loss. Measured
    /// break-even sits near 256x256; this threshold sits at that point.
    public nonisolated static let gpuThresholdCells = 65_536

    public nonisolated static let shared = RasterCompute()

    private let device: (any MTLDevice)?
    private var queue: (any MTLCommandQueue)?
    private var slopeAspectPipeline: (any MTLComputePipelineState)?
    private var reliefPipeline: (any MTLComputePipelineState)?
    private var setupAttempted = false

    /// Matches `TerrainUniforms` in `TerrainKernels.metal`.
    private struct Uniforms {
        var width: UInt32
        var height: UInt32
        var cellSizeX: Float
        var cellSizeY: Float
        var zenithRadians: Float
        var lightAzimuth: Float
        var azimuthCount: UInt32
    }

    public init() {
        self.device = MTLCreateSystemDefaultDevice()
        if device == nil {
            Log.shader.notice("No Metal device available; terrain compute will use the CPU path.")
        }
    }

    // MARK: - Public API

    /// Computes slope, aspect, and multi-directional relief for a grid.
    ///
    /// Routes to Metal for rasters large enough to amortise the dispatch and
    /// falls back to the CPU otherwise, or whenever the GPU path is
    /// unavailable. Both paths implement the same estimator, so results agree
    /// to floating-point tolerance.
    public func reliefProducts(
        for grid: ElevationGrid,
        azimuthCount: Int = 4,
        altitudeDegrees: Double = 30
    ) -> ReliefProducts {
        let state = Signpost.raster.beginInterval("reliefProducts")
        defer { Signpost.raster.endInterval("reliefProducts", state) }

        if grid.count >= Self.gpuThresholdCells,
           let products = gpuReliefProducts(
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

    /// Reports whether the Metal path is usable, building pipelines if needed.
    public func isGPUAvailable() -> Bool {
        prepareIfNeeded()
        return slopeAspectPipeline != nil && reliefPipeline != nil
    }

    // MARK: - CPU path

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
            backend: .cpu
        )
    }

    // MARK: - GPU path

    /// Builds the command queue and pipeline states. Idempotent; any failure
    /// is recorded once and the CPU path is used from then on.
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
            library = try device.makeDefaultLibrary(bundle: .main)
        } catch {
            Log.shader.error("Metal library unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }

        do {
            guard
                let slopeFn = library.makeFunction(name: "horn_slope_aspect"),
                let reliefFn = library.makeFunction(name: "multidirectional_relief")
            else {
                Log.shader.error("Terrain kernels missing from the Metal library.")
                return
            }
            slopeAspectPipeline = try device.makeComputePipelineState(function: slopeFn)
            reliefPipeline = try device.makeComputePipelineState(function: reliefFn)
            Log.shader.info("Metal terrain pipelines ready on \(device.name, privacy: .public).")
        } catch {
            Log.shader.error("Pipeline construction failed: \(error.localizedDescription, privacy: .public)")
            slopeAspectPipeline = nil
            reliefPipeline = nil
        }
    }

    /// Returns `nil` whenever the GPU path cannot run, so the caller falls back.
    private func gpuReliefProducts(
        grid: ElevationGrid,
        azimuthCount: Int,
        altitudeDegrees: Double
    ) -> ReliefProducts? {
        prepareIfNeeded()

        guard
            let device,
            let queue,
            let slopePipeline = slopeAspectPipeline,
            let reliefPipeline
        else { return nil }

        let count = grid.count
        let byteCount = count * MemoryLayout<Float>.stride
        // `.storageModeShared` keeps one copy visible to CPU and GPU. On Apple
        // silicon memory is unified, so a private-storage blit would add a copy
        // and buy nothing.
        let options: MTLResourceOptions = .storageModeShared

        guard
            let elevationBuffer = grid.samples.withUnsafeBytes({ bytes in
                device.makeBuffer(bytes: bytes.baseAddress!, length: byteCount, options: options)
            }),
            let slopeBuffer = device.makeBuffer(length: byteCount, options: options),
            let aspectBuffer = device.makeBuffer(length: byteCount, options: options),
            let reliefBuffer = device.makeBuffer(length: byteCount, options: options),
            let commandBuffer = queue.makeCommandBuffer()
        else {
            Log.shader.error("Metal buffer allocation failed for \(count) cells; using CPU.")
            return nil
        }

        var uniforms = Uniforms(
            width: UInt32(grid.width),
            height: UInt32(grid.height),
            cellSizeX: Float(grid.metersPerColumn),
            cellSizeY: Float(grid.metersPerRow),
            zenithRadians: Float((90 - altitudeDegrees) * .pi / 180),
            lightAzimuth: 0,
            azimuthCount: UInt32(max(azimuthCount, 1))
        )

        let threadsPerGrid = MTLSize(width: grid.width, height: grid.height, depth: 1)

        // Pass 1 — slope and aspect.
        guard let slopeEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        slopeEncoder.setComputePipelineState(slopePipeline)
        slopeEncoder.setBuffer(elevationBuffer, offset: 0, index: 0)
        slopeEncoder.setBuffer(slopeBuffer, offset: 0, index: 1)
        slopeEncoder.setBuffer(aspectBuffer, offset: 0, index: 2)
        slopeEncoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 3)
        slopeEncoder.dispatchThreads(
            threadsPerGrid,
            threadsPerThreadgroup: Self.threadgroupSize(for: slopePipeline, width: grid.width)
        )
        slopeEncoder.endEncoding()

        // Pass 2 — multi-directional relief, reading pass 1's output.
        guard let reliefEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        reliefEncoder.setComputePipelineState(reliefPipeline)
        reliefEncoder.setBuffer(slopeBuffer, offset: 0, index: 0)
        reliefEncoder.setBuffer(aspectBuffer, offset: 0, index: 1)
        reliefEncoder.setBuffer(reliefBuffer, offset: 0, index: 2)
        reliefEncoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 3)
        reliefEncoder.dispatchThreads(
            threadsPerGrid,
            threadsPerThreadgroup: Self.threadgroupSize(for: reliefPipeline, width: grid.width)
        )
        reliefEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            Log.shader.error("Terrain command buffer failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        return ReliefProducts(
            slopeDegrees: Self.readFloats(from: slopeBuffer, count: count),
            aspectDegrees: Self.readFloats(from: aspectBuffer, count: count),
            multiDirectionalRelief: Self.readFloats(from: reliefBuffer, count: count),
            width: grid.width,
            height: grid.height,
            backend: .gpu
        )
    }

    /// A threadgroup shaped to the pipeline's own occupancy hints.
    private static func threadgroupSize(
        for pipeline: any MTLComputePipelineState,
        width: Int
    ) -> MTLSize {
        let executionWidth = pipeline.threadExecutionWidth
        let maxThreads = pipeline.maxTotalThreadsPerThreadgroup
        let w = max(min(executionWidth, width), 1)
        let h = max(maxThreads / w, 1)
        return MTLSize(width: w, height: h, depth: 1)
    }

    private static func readFloats(from buffer: any MTLBuffer, count: Int) -> [Float] {
        let pointer = buffer.contents().bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }
}
