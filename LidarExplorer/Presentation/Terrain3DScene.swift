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
    /// What the 3D view says about the ground it shows when the elevation it was built from covers only part of the view
    /// (``TerrainViewerModel/coverageNotice(share:inFile:)``); nil when it covers the view.
    public let coverageNotice: String?

    public init(mesh: TerrainMesh, texture: CGImage?, coverageNotice: String? = nil) {
        self.mesh = mesh
        self.texture = texture
        self.coverageNotice = coverageNotice
    }
}
