//
//  TerrainMeshBuilder.swift
//  LidarExplorer
//
//  Tessellates an elevation grid into a triangle mesh in metres, for a 3D view of the ground.
//
//  Pure geometry, no SceneKit or UIKit: it produces arrays a renderer wraps, and it compiles and is tested
//  host-side. The mesh is right-handed with y up, x east and z south (rows run southward), centred on the origin
//  in x and z, with the lowest sample at y = 0.
//

import Foundation
import simd

public nonisolated struct TerrainMesh: Sendable, Equatable {
    public struct Bounds: Sendable, Equatable {
        public var minimum: SIMD3<Float>
        public var maximum: SIMD3<Float>
    }

    /// Vertices across and down. `positions` is `columns * rows`, row by row from the north-west.
    public let columns: Int
    public let rows: Int
    /// Metres: x east, y up from the lowest sample (times the exaggeration), z south.
    public let positions: [SIMD3<Float>]
    /// Unit normals, from the exaggerated surface.
    public let normals: [SIMD3<Float>]
    /// `u` runs west to east and `v` north to south, both 0...1, so an image of the ground drapes on with its
    /// top edge to the north.
    public let uvs: [SIMD2<Float>]
    /// Triangles, counter-clockwise seen from above. A quad touching a void is left out.
    public let indices: [UInt32]
    public let bounds: Bounds
    /// The source elevation that y = 0 stands for.
    public let minimumElevation: Float
}

public nonisolated enum TerrainMeshBuilder {

    /// A mesh of `grid`, at most `maxDimension` vertices on its longer side, with heights scaled by
    /// `zExaggeration` (`y = (elevation - lowest) * zExaggeration`; anything not a positive number counts as 1).
    ///
    /// A grid within the cap is meshed sample for sample. A larger one is resampled bilinearly onto a coarser
    /// lattice that keeps its corners and its proportions. Voids get height 0 and an upward normal but no
    /// triangles, so they show as holes. Returns an empty mesh for a grid with fewer than two samples a side, a
    /// cap below 2, or no valid elevation at all.
    public static func build(grid: ElevationGrid, maxDimension: Int, zExaggeration: Float) -> TerrainMesh {
        let empty = TerrainMesh(
            columns: 0, rows: 0, positions: [], normals: [], uvs: [], indices: [],
            bounds: TerrainMesh.Bounds(minimum: .zero, maximum: .zero), minimumElevation: 0)
        let sourceWidth = grid.width, sourceHeight = grid.height
        guard sourceWidth >= 2, sourceHeight >= 2, maxDimension >= 2, grid.samples.count == sourceWidth * sourceHeight
        else { return empty }
        let scale = zExaggeration.isFinite && zExaggeration > 0 ? zExaggeration : 1

        let longest = max(sourceWidth, sourceHeight)
        let columns: Int, rows: Int
        if longest <= maxDimension {
            columns = sourceWidth
            rows = sourceHeight
        } else {
            let ratio = Double(maxDimension) / Double(longest)
            columns = max(2, Int((Double(sourceWidth) * ratio).rounded()))
            rows = max(2, Int((Double(sourceHeight) * ratio).rounded()))
        }

        // Elevations on the mesh lattice.
        var elevations = [Float](repeating: .nan, count: columns * rows)
        for j in 0..<rows {
            let row = Double(j) * Double(sourceHeight - 1) / Double(rows - 1)
            for i in 0..<columns {
                let column = Double(i) * Double(sourceWidth - 1) / Double(columns - 1)
                elevations[j * columns + i] = interpolate(grid, column: column, row: row)
            }
        }
        guard let lowest = elevations.filter(\.isFinite).min() else { return empty }

        // Ground spacing, and heights above the lowest sample, exaggerated.
        let dx = Float(grid.metersPerColumn) * Float(sourceWidth - 1) / Float(columns - 1)
        let dz = Float(grid.metersPerRow) * Float(sourceHeight - 1) / Float(rows - 1)
        let heights = elevations.map { $0.isFinite ? ($0 - lowest) * scale : Float.nan }

        var positions = [SIMD3<Float>](repeating: .zero, count: columns * rows)
        var uvs = [SIMD2<Float>](repeating: .zero, count: columns * rows)
        var normals = [SIMD3<Float>](repeating: SIMD3<Float>(0, 1, 0), count: columns * rows)
        var highest: Float = 0
        for j in 0..<rows {
            for i in 0..<columns {
                let index = j * columns + i
                let y = heights[index].isFinite ? heights[index] : 0
                positions[index] = SIMD3<Float>(
                    (Float(i) - Float(columns - 1) / 2) * dx, y, (Float(j) - Float(rows - 1) / 2) * dz)
                uvs[index] = SIMD2<Float>(Float(i) / Float(columns - 1), Float(j) / Float(rows - 1))
                highest = max(highest, y)
                guard heights[index].isFinite else { continue }
                let gradientX = slope(heights, index: index, step: 1, valid: i > 0, i < columns - 1, spacing: dx)
                let gradientZ = slope(heights, index: index, step: columns, valid: j > 0, j < rows - 1, spacing: dz)
                normals[index] = simd_normalize(SIMD3<Float>(-gradientX, 1, -gradientZ))
            }
        }

        // Two triangles a quad, counter-clockwise from above (x east, z south): a-c-b then b-c-d.
        var indices: [UInt32] = []
        indices.reserveCapacity((columns - 1) * (rows - 1) * 6)
        for j in 0..<(rows - 1) {
            for i in 0..<(columns - 1) {
                let a = j * columns + i, b = a + 1, c = a + columns, d = c + 1
                guard heights[a].isFinite, heights[b].isFinite, heights[c].isFinite, heights[d].isFinite else { continue }
                indices.append(contentsOf: [UInt32(a), UInt32(c), UInt32(b), UInt32(b), UInt32(c), UInt32(d)])
            }
        }

        let halfWidth = Float(columns - 1) / 2 * dx, halfDepth = Float(rows - 1) / 2 * dz
        return TerrainMesh(
            columns: columns, rows: rows, positions: positions, normals: normals, uvs: uvs, indices: indices,
            bounds: TerrainMesh.Bounds(
                minimum: SIMD3<Float>(-halfWidth, 0, -halfDepth), maximum: SIMD3<Float>(halfWidth, highest, halfDepth)),
            minimumElevation: lowest)
    }

    /// Bilinear elevation at a fractional sample position, NaN if a sample it needs is a void. A position on a
    /// node reads that node alone, so a void beside it does not spoil it.
    private static func interpolate(_ grid: ElevationGrid, column: Double, row: Double) -> Float {
        let w = grid.width, h = grid.height
        let c0 = min(Int(column.rounded(.down)), w - 1), r0 = min(Int(row.rounded(.down)), h - 1)
        let c1 = min(c0 + 1, w - 1), r1 = min(r0 + 1, h - 1)
        let fx = column - Double(c0), fy = row - Double(r0)
        func at(_ c: Int, _ r: Int) -> Double { Double(grid.samples[r * w + c]) }
        let v00 = at(c0, r0)
        if fx == 0 && fy == 0 { return Float(v00) }
        if fy == 0 { return Float(v00 * (1 - fx) + at(c1, r0) * fx) }
        if fx == 0 { return Float(v00 * (1 - fy) + at(c0, r1) * fy) }
        return Float(
            v00 * (1 - fx) * (1 - fy) + at(c1, r0) * fx * (1 - fy) + at(c0, r1) * (1 - fx) * fy + at(c1, r1) * fx * fy)
    }

    /// Rise per metre along an axis: central where both neighbours are valid, one-sided at an edge or void.
    private static func slope(
        _ heights: [Float], index: Int, step: Int, valid before: Bool, _ after: Bool, spacing: Float
    ) -> Float {
        let here = heights[index]
        let previous: Float? = before && heights[index - step].isFinite ? heights[index - step] : nil
        let next: Float? = after && heights[index + step].isFinite ? heights[index + step] : nil
        switch (previous, next) {
        case (let p?, let n?): return (n - p) / (2 * spacing)
        case (nil, let n?): return (n - here) / spacing
        case (let p?, nil): return (here - p) / spacing
        case (nil, nil): return 0
        }
    }
}
