//
//  HapticRouting.swift
//  LidarExplorer
//
//  Which feedback a haptic cue plays, and where, decided apart from the generators that play it.
//
//  An iPad has no Taptic Engine. Since iPadOS 17.5 its haptics come from Apple Pencil Pro (and the Magic Keyboard's
//  trackpad), through a feedback generator attached to a view and fired at a point in it. Apple names canvas feedback
//  (UICanvasFeedbackGenerator) as the kind that gives a tactile response on the Pencil Pro, and a test of each kind on
//  an M4 iPad Pro (iOS 18.2) had canvas alignment play on the Pencil while selection, impact and notification feedback
//  stayed silent there. An iPhone's Taptic Engine plays selection and impact feedback and no canvas feedback. So each
//  cue has a voice for each kind of device (or none: the wipe's step on the Pencil), and it is played at the touch that
//  caused it, in the window that touch is in: the Pencil plays feedback fired where the Pencil itself is touching the
//  screen.
//

import CoreGraphics
import Foundation

/// Something that happened under a finger or the Pencil which the hand should feel.
public nonisolated enum HapticCue: String, Sendable, CaseIterable {
    /// The sun dial arrived at one of the eight compass headings (``AzimuthDetents``).
    case azimuthDetent
    /// A relief style was picked.
    case styleChanged
    /// The profile's scrub crossed a break in an earthwork signature (``BreakCrossingDetector``).
    case earthworkBreak
    /// The profile's scrub crossed a place where the slope chart's steepness crosses its 20° flank line
    /// (``SlopeCrossingDetector``).
    case slopeLine
    /// The split wipe's handle crossed or landed on the middle of the screen.
    case wipeCentre
    /// The split wipe's handle jumped more than 2 % of the screen between two readings: an iPhone's texture of speed,
    /// silent on the Pencil.
    case wipeStep
    /// The split wipe was turned between vertical and horizontal.
    case wipeTurned
    /// A spot inspection read the ground under a tap.
    case spotRead
}

/// The weight of an impact, as `UIImpactFeedbackGenerator.FeedbackStyle` names them.
public nonisolated enum HapticImpactStyle: String, Sendable, Hashable, CaseIterable {
    case light, medium, rigid
}

/// A kind of feedback, as the generator that plays it names it.
public nonisolated enum HapticVoice: Equatable, Sendable {
    /// `UICanvasFeedbackGenerator.alignmentOccurred(at:)`: an object snapping to a guide. What Apple Pencil Pro plays.
    case canvasAlignment
    /// `UISelectionFeedbackGenerator.selectionChanged(at:)`: a step through discrete values.
    case selection
    /// `UIImpactFeedbackGenerator.impactOccurred(intensity:at:)`, from a generator of that weight.
    case impact(HapticImpactStyle, intensity: Double)
}

public nonisolated enum HapticRouting {

    /// The feedback `cue` plays, or nil for none. `pencilHaptics` is an iPad, whose haptics are Apple Pencil Pro's:
    /// canvas alignment, the one kind Apple says the Pencil plays and meant for a drawing event such as a snap to a
    /// guide, for each cue that marks something reached or done (a heading, a break, the slope line, the middle, a chip,
    /// the wipe turned, a spot read). The wipe's step is none of these: it marks how fast the handle moves, and a flick
    /// would fire it on every reading, so the Pencil plays nothing for it. Otherwise, an iPhone's Taptic Engine: the
    /// selection ticks and weighted impacts these cues have always played, and for the slope line the earthwork break's
    /// thump, beside which it marks the same scrub.
    public static func voice(for cue: HapticCue, pencilHaptics: Bool) -> HapticVoice? {
        if pencilHaptics { return cue == .wipeStep ? nil : .canvasAlignment }
        switch cue {
        case .azimuthDetent, .styleChanged: return .selection
        case .earthworkBreak, .slopeLine: return .impact(.medium, intensity: 0.7)
        case .wipeCentre: return .impact(.medium, intensity: 1)
        case .wipeStep: return .impact(.light, intensity: 0.4)
        case .wipeTurned: return .impact(.rigid, intensity: 1)
        case .spotRead: return .impact(.light, intensity: 1)
        }
    }

    /// The cue a move of the split wipe's handle from `old` to `new` (fractions of the screen) plays, or nil.
    ///
    /// Crossing the middle, or landing on it from either side, is ``HapticCue/wipeCentre``; otherwise a jump of more
    /// than 2 % between two readings is ``HapticCue/wipeStep``. Leaving the middle is not arriving at it, and a reading
    /// that is not a number plays nothing.
    public static func wipeCue(from old: Double, to new: Double) -> HapticCue? {
        if (old < 0.5 && new >= 0.5) || (old > 0.5 && new <= 0.5) { return .wipeCentre }
        if abs(new - old) > 0.02 { return .wipeStep }
        return nil
    }

    /// `local`, a point in a view's own coordinates, in the coordinates of the window the view lies in at `frame`
    /// (SwiftUI's global space, which is the window's): where a haptic caused by a touch at `local` is played. Nil when
    /// the view has no frame yet or the point is not a number, rather than the window's corner, far from the touch.
    public static func windowPoint(_ local: CGPoint, inViewAt frame: CGRect) -> CGPoint? {
        guard !frame.isNull, !frame.isInfinite, local.x.isFinite, local.y.isFinite else { return nil }
        return CGPoint(x: frame.minX + local.x, y: frame.minY + local.y)
    }
}
