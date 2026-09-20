//
//  Terrain3DScene.swift
//  LidarExplorer
//
//  What the 3D view is given: the terrain as a mesh, and the picture to drape over it.
//

import CoreGraphics
import Foundation

public struct Terrain3DScene: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let mesh: TerrainMesh
    /// The map's shaded tiles stitched over the mesh's ground, or nil where none have drawn.
    public let texture: CGImage?

    public init(mesh: TerrainMesh, texture: CGImage?) {
        self.mesh = mesh
        self.texture = texture
    }
}
