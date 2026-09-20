//
//  TerrainMeshChecks.swift
//  ViewerHarness
//
//  Tessellating an elevation grid into a metric 3D mesh: counts, positions, exaggeration, normals, winding, voids.
//

import CoreLocation
import Foundation
import simd

@MainActor
func runTerrainMeshChecks() async {
    print("\n=== 3D terrain mesh ===")
    checkMeshTopology()
    checkMeshGeometry()
    checkMeshExaggeration()
    checkMeshNormalsAndWinding()
    checkMeshVoidsAndDegenerates()
}

/// A grid whose elevation is `f(x metres east, y metres south)`, 1 m between samples.
private func meshGrid(width: Int, height: Int, gsd: Double = 1, _ f: (Double, Double) -> Float) -> ElevationGrid {
    sceneGrid(width: width, height: height, gsd: gsd) { column, row in f(Double(column) * gsd, Double(row) * gsd) }
}

/// A vertex, or NaN where the mesh has none, so a wrong mesh fails a check instead of trapping the harness.
private func vertex(_ mesh: TerrainMesh, _ i: Int) -> SIMD3<Float> {
    mesh.positions.indices.contains(i) ? mesh.positions[i] : SIMD3<Float>(repeating: .nan)
}

private func texel(_ mesh: TerrainMesh, _ i: Int) -> SIMD2<Float> {
    mesh.uvs.indices.contains(i) ? mesh.uvs[i] : SIMD2<Float>(repeating: .nan)
}

private func triangles(_ mesh: TerrainMesh) -> [(Int, Int, Int)] {
    stride(from: 0, to: mesh.indices.count, by: 3).map { (Int(mesh.indices[$0]), Int(mesh.indices[$0 + 1]), Int(mesh.indices[$0 + 2])) }
}

// MARK: - Topology

@MainActor
private func checkMeshTopology() {
    print("\n--- T1. counts and ranges ---")
    let ten = meshGrid(width: 10, height: 10) { x, y in 100 + Float(x + y) }
    let mesh = TerrainMeshBuilder.build(grid: ten, maxDimension: 128, zExaggeration: 1)
    check("a 10 x 10 grid is 100 vertices and 486 indices (81 quads of 6)",
          mesh.positions.count == 100 && mesh.normals.count == 100 && mesh.uvs.count == 100 && mesh.indices.count == 486
          && mesh.columns == 10 && mesh.rows == 10,
          "\(mesh.positions.count) vertices, \(mesh.indices.count) indices")

    let wide = TerrainMeshBuilder.build(grid: meshGrid(width: 7, height: 5) { x, _ in Float(x) }, maxDimension: 128, zExaggeration: 1)
    check("a 7 x 5 grid is W x H vertices and (W-1)(H-1) x 6 indices",
          wide.positions.count == 35 && wide.indices.count == 6 * 4 * 6, "\(wide.positions.count), \(wide.indices.count)")

    check("every index names a vertex, no triangle is degenerate, and each vertex is used",
          mesh.indices.allSatisfy { Int($0) < mesh.positions.count }
          && triangles(mesh).allSatisfy { $0.0 != $0.1 && $0.1 != $0.2 && $0.0 != $0.2 }
          && Set(mesh.indices).count == mesh.positions.count && !mesh.indices.isEmpty)

    check("uv runs 0 to 1 across the mesh: (0,0) at the north-west corner, (1,1) at the south-east",
          texel(mesh, 0) == SIMD2<Float>(0, 0) && texel(mesh, 99) == SIMD2<Float>(1, 1) && texel(mesh, 9) == SIMD2<Float>(1, 0)
          && texel(mesh, 90) == SIMD2<Float>(0, 1) && mesh.uvs.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) },
          "\(String(describing: mesh.uvs.first)) \(String(describing: mesh.uvs.last))")

    // A big grid is decimated to the cap, keeping its shape and its corners.
    let big = meshGrid(width: 600, height: 400) { x, y in 100 + Float(x) * 0.05 + Float(sin(y * 0.1)) }
    let small = TerrainMeshBuilder.build(grid: big, maxDimension: 128, zExaggeration: 1)
    check("a 600 x 400 grid at a cap of 128 becomes 128 x 85 keeping its aspect, with consistent counts",
          small.columns == 128 && abs(small.rows - 85) <= 1 && small.positions.count == small.columns * small.rows
          && small.indices.count == (small.columns - 1) * (small.rows - 1) * 6,
          "\(small.columns) x \(small.rows), \(small.indices.count) indices")
    let corners = [0, small.columns - 1, (small.rows - 1) * small.columns, small.positions.count - 1].map { vertex(small, $0).y + small.minimumElevation }
    let sourceCorners = [big.samples[0], big.samples[599], big.samples[399 * 600], big.samples[big.count - 1]]
    check("decimation keeps the four corner elevations exactly",
          zip(corners, sourceCorners).allSatisfy { abs($0 - $1) < 1e-3 } && small.positions.count > 10_000,
          "\(corners) vs \(sourceCorners)")
    let full = TerrainMeshBuilder.build(grid: big, maxDimension: 1_000, zExaggeration: 1)
    check("a grid under the cap is not resampled at all", full.columns == 600 && full.rows == 400, "\(full.columns) x \(full.rows)")
}

// MARK: - Geometry

@MainActor
private func checkMeshGeometry() {
    print("\n--- T2. metric positions ---")
    let grid = meshGrid(width: 21, height: 11, gsd: 2) { x, y in 250 + Float(x) * 0.1 + Float(y) * 0.05 }
    let mesh = TerrainMeshBuilder.build(grid: grid, maxDimension: 128, zExaggeration: 1)
    let spacingX = Double(vertex(mesh, 1).x - vertex(mesh, 0).x)
    let spacingZ = Double(vertex(mesh, 21).z - vertex(mesh, 0).z)
    check("vertices are a metre apart on the ground as the grid is: x east, z south, at its own spacing",
          abs(spacingX - grid.metersPerColumn) < 0.01 && abs(spacingZ - grid.metersPerRow) < 0.01
          && vertex(mesh, 1).z == vertex(mesh, 0).z && vertex(mesh, 21).x == vertex(mesh, 0).x,
          "\(spacingX) vs \(grid.metersPerColumn), \(spacingZ) vs \(grid.metersPerRow)")
    let meanX = mesh.positions.map(\.x).reduce(0, +) / Float(max(mesh.positions.count, 1))
    let meanZ = mesh.positions.map(\.z).reduce(0, +) / Float(max(mesh.positions.count, 1))
    check("the mesh is centred on the origin: its bounds and its actual vertices",
          abs(mesh.bounds.minimum.x + mesh.bounds.maximum.x) < 1e-3 && abs(mesh.bounds.minimum.z + mesh.bounds.maximum.z) < 1e-3
          && mesh.bounds.maximum.x > 0 && mesh.bounds.maximum.z > 0
          && abs(meanX) < 1e-3 && abs(meanZ) < 1e-3 && abs(vertex(mesh, 0).x + mesh.bounds.maximum.x) < 1e-3
          && abs(vertex(mesh, 230).z - mesh.bounds.maximum.z) < 1e-3 && abs(vertex(mesh, 230).x - mesh.bounds.maximum.x) < 1e-3,
          "\(mesh.bounds), mean \(meanX), \(meanZ)")
    let rebuilt = (0..<mesh.positions.count).map { mesh.positions[$0].y + mesh.minimumElevation }
    check("at 1x, height above the lowest sample plus that sample is the source elevation at every vertex",
          rebuilt.count == grid.count && zip(rebuilt, grid.samples).allSatisfy { abs($0 - $1) < 1e-3 } && mesh.bounds.minimum.y == 0
          && abs(mesh.minimumElevation - (grid.samples.min() ?? .nan)) < 1e-4,
          "min \(mesh.minimumElevation), bounds \(mesh.bounds)")
}

// MARK: - Exaggeration

@MainActor
private func checkMeshExaggeration() {
    print("\n--- T3. vertical exaggeration ---")
    let grid = meshGrid(width: 30, height: 30) { x, y in 100 + Float(6 * exp(-((x - 15) * (x - 15) + (y - 15) * (y - 15)) / 30)) }
    let one = TerrainMeshBuilder.build(grid: grid, maxDimension: 128, zExaggeration: 1)
    let two = TerrainMeshBuilder.build(grid: grid, maxDimension: 128, zExaggeration: 2)
    let five = TerrainMeshBuilder.build(grid: grid, maxDimension: 128, zExaggeration: 5)
    let relief = [one, two, five].map { $0.bounds.maximum.y - $0.bounds.minimum.y }
    check("2x exaggeration doubles the height between the peak and the base vertices, and 5x makes it five",
          relief[0] > 5 && abs(relief[1] / relief[0] - 2) < 1e-4 && abs(relief[2] / relief[0] - 5) < 1e-4,
          "\(relief)")
    check("exaggeration leaves every base coordinate (x and z) untouched, bit for bit, and the base at height 0",
          one.positions.count == 900 && zip(one.positions, five.positions).allSatisfy { $0.x == $1.x && $0.z == $1.z }
          && one.bounds.minimum.y == 0 && five.bounds.minimum.y == 0)
    check("every vertex scales by the same factor, so shape is kept",
          one.positions.count == 900 && zip(one.positions, five.positions).allSatisfy { abs($1.y - 5 * $0.y) < 1e-4 }
          && one.indices == five.indices && !one.indices.isEmpty)
    let unusual = [Float(0), -3, .nan, .infinity].map { TerrainMeshBuilder.build(grid: grid, maxDimension: 128, zExaggeration: $0) }
    check("an exaggeration that is not a positive number counts as 1",
          !one.positions.isEmpty && unusual.allSatisfy { $0.positions == one.positions }, "\(unusual.map { $0.bounds.maximum.y })")
}

// MARK: - Normals and winding

@MainActor
private func checkMeshNormalsAndWinding() {
    print("\n--- T4. normals and winding ---")
    let flat = TerrainMeshBuilder.build(grid: meshGrid(width: 12, height: 12) { _, _ in 300 }, maxDimension: 128, zExaggeration: 1)
    check("flat ground has straight-up normals everywhere",
          flat.normals.allSatisfy { abs($0.x) < 1e-6 && abs($0.y - 1) < 1e-6 && abs($0.z) < 1e-6 } && flat.normals.count == 144)

    // Rising 1 m per metre to the east: the surface faces up and to the west.
    let ramp = TerrainMeshBuilder.build(grid: meshGrid(width: 12, height: 12) { x, _ in 300 + Float(x) }, maxDimension: 128, zExaggeration: 1)
    let expected = SIMD3<Float>(-1, 1, 0) / Float(2).squareRoot()
    check("a 45 degree east-rising slope tilts every normal, edges included, up and to the west",
          ramp.normals.count == 144 && ramp.normals.allSatisfy { simd_length($0 - expected) < 1e-4 }, "\(ramp.normals.first ?? .zero)")
    // Falling to the south: rising to the north, so the surface faces south (+z).
    let south = TerrainMeshBuilder.build(grid: meshGrid(width: 12, height: 12) { _, y in 300 - Float(y) }, maxDimension: 128, zExaggeration: 1)
    check("ground falling to the south faces south, so z really is south",
          south.normals.count == 144 && south.normals.allSatisfy { $0.z > 0.7 && abs($0.x) < 1e-6 && $0.y > 0.7 })
    let steepened = TerrainMeshBuilder.build(grid: meshGrid(width: 12, height: 12) { x, _ in 300 + 0.5 * Float(x) }, maxDimension: 128, zExaggeration: 2)
    check("normals follow the exaggeration: a 0.5 slope at 2x is a 45 degree face",
          steepened.normals.count == 144 && steepened.normals.allSatisfy { simd_length($0 - expected) < 1e-4 })
    check("normals are unit length on rough ground",
          { () -> Bool in
              let rough = TerrainMeshBuilder.build(
                grid: meshGrid(width: 40, height: 40) { x, y in 100 + Float(3 * sin(x * 0.4) * cos(y * 0.3)) },
                maxDimension: 128, zExaggeration: 3)
              return rough.normals.allSatisfy { abs(simd_length($0) - 1) < 1e-4 } && rough.normals.count == 1600
          }())

    // Winding: every face of gentle ground must point up, agreeing with the vertex normals.
    let bumpy = TerrainMeshBuilder.build(
        grid: meshGrid(width: 30, height: 30) { x, y in 100 + Float(2 * sin(x * 0.3) * cos(y * 0.25)) }, maxDimension: 128, zExaggeration: 1)
    var facingUp = 0, agreeing = 0
    for (a, b, c) in triangles(bumpy) {
        let n = simd_cross(bumpy.positions[b] - bumpy.positions[a], bumpy.positions[c] - bumpy.positions[a])
        if n.y > 0 { facingUp += 1 }
        if simd_dot(n, bumpy.normals[a] + bumpy.normals[b] + bumpy.normals[c]) > 0 { agreeing += 1 }
    }
    check("every triangle winds counter-clockwise seen from above, agreeing with its vertex normals",
          facingUp == bumpy.indices.count / 3 && agreeing == facingUp && facingUp > 1_000, "\(facingUp) up, \(agreeing) agree")
}

// MARK: - Voids and degenerate input

@MainActor
private func checkMeshVoidsAndDegenerates() {
    print("\n--- T5. voids and degenerate input ---")
    var samples = meshGrid(width: 20, height: 20) { x, y in 100 + Float(x + y) * 0.1 }.samples
    for y in 8..<11 { for x in 8..<11 { samples[y * 20 + x] = .nan } }
    let holed = ElevationGrid(width: 20, height: 20, samples: samples, region: makeGrid(width: 20, height: 20, gsd: 1).region)
    let mesh = TerrainMeshBuilder.build(grid: holed, maxDimension: 128, zExaggeration: 1)
    // Quads touching a void cell: the 3 x 3 patch is touched by (3 + 1)^2 = 16 quads.
    check("a void leaves a hole: the 16 quads touching it are dropped, every position and normal stays finite",
          mesh.positions.count == 400 && mesh.indices.count == (19 * 19 - 16) * 6
          && mesh.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
          && mesh.normals.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite },
          "\(mesh.indices.count) indices")
    // A void in one column beside mesh vertices that fall exactly on the column before it: 61 x 50 at a cap of 31 is
    // 31 columns sitting on even samples but 25 rows between samples, so nothing may read the void column.
    var narrow = meshGrid(width: 61, height: 50) { x, y in 100 + Float(x + y) * 0.1 }.samples
    for y in 15..<40 { narrow[y * 61 + 21] = .nan }
    let mixed = TerrainMeshBuilder.build(
        grid: ElevationGrid(width: 61, height: 50, samples: narrow, region: makeGrid(width: 61, height: 50, gsd: 1).region),
        maxDimension: 31, zExaggeration: 1)
    check("a void beside a vertex that lands exactly on a sample column does not leak into it when the rows are fractional",
          mixed.columns == 31 && mixed.rows == 25 && mixed.indices.count == 30 * 24 * 6,
          "\(mixed.columns) x \(mixed.rows), \(mixed.indices.count) indices, expected \(30 * 24 * 6)")
    let voidVertices = Set((8..<11).flatMap { y in (8..<11).map { UInt32(y * 20 + $0) } })
    check("no triangle uses a vertex that was a void, though the rest of the mesh has triangles",
          !mesh.indices.isEmpty && mesh.indices.allSatisfy { !voidVertices.contains($0) })

    let empty = TerrainMeshBuilder.build(
        grid: ElevationGrid(width: 5, height: 5, samples: [Float](repeating: .nan, count: 25), region: makeGrid(width: 5, height: 5, gsd: 1).region),
        maxDimension: 128, zExaggeration: 1)
    let thin = TerrainMeshBuilder.build(grid: meshGrid(width: 1, height: 9) { _, y in Float(y) }, maxDimension: 128, zExaggeration: 1)
    let uncapped = TerrainMeshBuilder.build(grid: meshGrid(width: 9, height: 9) { x, _ in Float(x) }, maxDimension: 1, zExaggeration: 1)
    check("an all-void grid, a one-column grid and a cap below 2 give an empty mesh rather than a trap",
          empty.positions.isEmpty && empty.indices.isEmpty && thin.positions.isEmpty && uncapped.positions.isEmpty
          && TerrainMeshBuilder.build(grid: meshGrid(width: 9, height: 9) { x, _ in Float(x) }, maxDimension: 128, zExaggeration: 1).positions.count == 81)
}
