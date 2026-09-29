//
//  TopBarLayout.swift
//  LidarExplorer
//
//  The top bar's layout arithmetic: the gap between the buttons, whether the readout keeps a readable width beside
//  them, and how the bar keeps clear of iPadOS's window controls. Pure, so the harness checks it (Y1);
//  ViewerTopBarView measures the widths and the controls' corner, and draws what this decides.
//

import CoreGraphics
import Foundation

public nonisolated struct TopBarLayout: Equatable, Sendable {

    /// The gap between the buttons where the bar has room for the row at this gap.
    public static let regularSpacing: CGFloat = 10
    /// The gap where it does not: the four tools' row is 350 pt at 10 (three 44 pt buttons, the cluster's 4 × 46 + 4,
    /// three gaps) and 338 at 6, inside a 375 pt phone's 343 pt between the margins.
    public static let tightSpacing: CGFloat = 6
    /// The gaps in the row of buttons: location, 3D, the mode cluster, More.
    public static let buttonGaps: CGFloat = 3
    /// The first row's gap between its pieces, and the least room the spacer leaves between the readout and the buttons.
    public static let rowSpacing: CGFloat = 10
    public static let readoutToButtonsMinimum: CGFloat = 8
    /// The gap the bar leaves beside the window controls' corner, as between its own pieces. The corner the system
    /// reports ends about 3 pt past the controls' glass, which put the location button hard against it.
    public static let windowControlsGap: CGFloat = 8

    /// The bar's width inside its margins, as the bar is offered it; nil until measured.
    public var barWidth: CGFloat?
    /// The buttons' width without the gaps between them.
    public var buttonsWidth: CGFloat
    /// The width the readout needs for a whole prompt.
    public var readableReadoutWidth: CGFloat
    /// The window controls' corner (close, minimize and resize, which iPadOS draws over the top-leading corner of an
    /// app in a window), from the top-leading corner of the bar's content inside its margins: how far it reaches
    /// across and down. Zero or less where it does not reach the content: full screen, where the system reports no
    /// corner, and an iPhone.
    public var windowControls: CGSize

    public init(barWidth: CGFloat?, buttonsWidth: CGFloat, readableReadoutWidth: CGFloat, windowControls: CGSize = .zero) {
        self.barWidth = barWidth
        self.buttonsWidth = buttonsWidth
        self.readableReadoutWidth = readableReadoutWidth
        self.windowControls = windowControls
    }

    /// The gap between the buttons, chosen from the room the bar has rather than the size class, which does not
    /// measure it: a 375 pt and a 390 pt phone are both compact, and a regular-width map column that the Map Styles
    /// inspector narrows went down to 448 pt in the Simulator (iPadOS 27), where the inspector started to float over
    /// the map instead.
    public var controlsSpacing: CGFloat {
        guard let barWidth else { return Self.regularSpacing }
        return barWidth >= buttonsWidth + Self.buttonGaps * Self.regularSpacing ? Self.regularSpacing : Self.tightSpacing
    }

    /// The row of buttons' width at ``controlsSpacing``.
    public var controlsWidth: CGFloat { buttonsWidth + Self.buttonGaps * controlsSpacing }

    /// Wider than the bar even at the tight gap (a bar under 338 pt, which no window the Simulator offered reaches:
    /// the plan's 320 pt Slide Over case): the row then overflows evenly at both ends, into the margins first, rather
    /// than all at one.
    public var controlsOverflow: Bool {
        guard let barWidth else { return false }
        return controlsWidth > barWidth
    }

    /// How far into the first row the window controls reach, with ``windowControlsGap`` beside them: 0 where they do
    /// not reach the content.
    public var windowControlsReach: CGFloat {
        windowControls.height > 0 && windowControls.width > 0 ? windowControls.width + Self.windowControlsGap : 0
    }

    /// Whether the readout keeps a readable width beside the buttons: what is left of the bar after the window
    /// controls' corner, the buttons, the spacer's minimum and the row's gap either side of it.
    public var fitsOneRow: Bool {
        guard let barWidth else { return true }
        return barWidth - windowControlsReach - controlsWidth - (Self.readoutToButtonsMinimum + 2 * Self.rowSpacing)
            >= readableReadoutWidth
    }

    /// Where the readout starts on a one-row bar: past the window controls and the gap beside them.
    public var readoutLeadingInset: CGFloat { fitsOneRow ? windowControlsReach : 0 }

    /// How far the bar drops so that its first row sits below the window controls: when the buttons hold that row
    /// alone, at its trailing edge, and still reach under the controls (the narrowest windows). Drops by the whole
    /// corner the system reports, the only extent it gives. Elsewhere 0: a one-row bar starts its readout past the
    /// controls, and a two-row bar whose buttons clear them keeps its place. The readout's row under the buttons
    /// starts 52 pt below the first row's top, below the controls themselves, though the system's corner reaches
    /// further (a toolbar's band).
    public var topInset: CGFloat {
        // A one-row bar never drops: its room for the readout already leaves the buttons clear of the corner.
        guard let barWidth, windowControlsReach > 0, barWidth - controlsWidth < windowControlsReach else { return 0 }
        return windowControls.height
    }
}
