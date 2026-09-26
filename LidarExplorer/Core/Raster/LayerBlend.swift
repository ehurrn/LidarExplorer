//
//  LayerBlend.swift
//  LidarExplorer
//
//  One micro-topography product draped over the one being shown: which, how, and how strongly.
//

import Foundation

public nonisolated struct LayerBlend: Sendable, Equatable, Hashable {
    public var product: MicroTopographyProduct
    public var mode: RasterBlendMode
    public var opacity: Float

    public init(product: MicroTopographyProduct, mode: RasterBlendMode = .softLight, opacity: Float = 0.7) {
        self.product = product
        self.mode = mode
        self.opacity = opacity
    }
}

extension MicroTopographyProduct {
    /// The name shown for the product. A product that is also a style is named as the style is.
    public var displayName: String {
        switch self {
        case .localRelief: "Local Relief"
        case .redRelief: "Red Relief"
        case .skyView: "Sky-View"
        case .rakingLight: "Raking Light"
        case .relativeElevation: "Relative Elevation"
        case .habitation: "Habitation Potential"
        case .curvature: "Curvature"
        case .directionalOcclusion: "Directional Occlusion"
        case .positiveOpenness: "Positive Openness"
        case .negativeOpenness: "Negative Openness"
        case .vectorRuggedness: "VRM Ruggedness"
        case .differenceOfGaussians: "Difference of Gaussians"
        }
    }

    /// Whether the dock's sun direction changes this product, shown as the style or draped as a layer.
    ///
    /// The low-sun products take the sun from the viewer's settings; see `TerrainStyleSettings.analysisOptions`.
    public nonisolated var usesSunDirection: Bool {
        self == .rakingLight || self == .directionalOcclusion
    }

    /// Whether the Grazing Sun Altitude control changes this product, shown as the style or draped as a layer.
    public nonisolated var usesGrazingSunAltitude: Bool {
        self == .rakingLight || self == .directionalOcclusion
    }
}

extension RasterBlendMode {
    public var displayName: String {
        switch self {
        case .multiply: "Multiply"
        case .softLight: "Soft Light"
        case .overlay: "Overlay"
        case .screen: "Screen"
        }
    }
}
