//
//  GlassSurface.swift
//  LidarExplorer
//
//  The one glass treatment every floating panel shares: regular material, an adaptive rim (a lit top
//  edge in dark, a hairline in light — a fixed white rim disappears over snow-white hillshade), and
//  the house shadow. Panels use 20 pt continuous corners; capsules and circles pass their own shape
//  and cast a tighter, lighter shadow sized for a control.
//

import SwiftUI

struct GlassSurface<S: InsettableShape>: ViewModifier {

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    let shape: S
    var elevation: GlassElevation = .panel

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: rimColors, startPoint: .top, endPoint: .bottom),
                    lineWidth: contrast == .increased ? 1 : 0.75))
            .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowOffset)
    }

    private var shadowOpacity: Double {
        switch elevation {
        case .panel: scheme == .dark ? 0.35 : 0.16
        case .control: scheme == .dark ? 0.26 : 0.12
        }
    }

    private var shadowRadius: CGFloat { elevation == .panel ? 14 : 6 }
    private var shadowOffset: CGFloat { elevation == .panel ? 5 : 2 }

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

/// How far a piece of glass lifts off the map.
enum GlassElevation {
    /// A panel: the house shadow.
    case panel
    /// A control-sized circle or capsule. The panel's 14 pt blur is a third of a 44 pt button's width: under
    /// a row of them it fills the 10 pt gaps and merges into one grey band (heaviest in dark, 0.35 over a
    /// light map). The control shadow keeps the 6 pt blur and 2 pt drop the top bar's buttons had before
    /// they took the glass, at three quarters of the panel's opacity.
    case control
}

extension View {
    /// A floating panel: 20 pt continuous corners over the map.
    func glassPanel() -> some View {
        modifier(GlassSurface(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)))
    }

    /// The same glass on a control-sized shape (a capsule readout, a circular button), with the lighter
    /// control shadow.
    func glassSurface<S: InsettableShape>(in shape: S) -> some View {
        modifier(GlassSurface(shape: shape, elevation: .control))
    }
}
