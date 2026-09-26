//
//  GlassSurface.swift
//  LidarExplorer
//
//  The one glass treatment every floating panel shares: regular material, an adaptive rim (a lit top
//  edge in dark, a hairline in light — a fixed white rim disappears over snow-white hillshade), and
//  the house shadow. Panels use 20 pt continuous corners; capsules and circles pass their own shape.
//

import SwiftUI

struct GlassSurface<S: InsettableShape>: ViewModifier {

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    let shape: S

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: rimColors, startPoint: .top, endPoint: .bottom),
                    lineWidth: contrast == .increased ? 1 : 0.75))
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.16), radius: 14, y: 5)
    }

    /// Increase Contrast gets a solid rim all the way round; otherwise the rim fades toward the bottom.
    private var rimColors: [Color] {
        switch (scheme == .dark, contrast == .increased) {
        case (true, true): [Color.white.opacity(0.45), Color.white.opacity(0.45)]
        case (true, false): [Color.white.opacity(0.28), Color.white.opacity(0.06)]
        case (false, true): [Color.black.opacity(0.25), Color.black.opacity(0.25)]
        case (false, false): [Color.black.opacity(0.10), Color.black.opacity(0.04)]
        }
    }
}

extension View {
    /// A floating panel: 20 pt continuous corners over the map.
    func glassPanel() -> some View {
        modifier(GlassSurface(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)))
    }

    /// The same glass on another shape (a capsule readout, a circular button).
    func glassSurface<S: InsettableShape>(in shape: S) -> some View {
        modifier(GlassSurface(shape: shape))
    }
}
