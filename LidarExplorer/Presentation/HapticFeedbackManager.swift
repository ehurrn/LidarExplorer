//
//  HapticFeedbackManager.swift
//  LidarExplorer
//
//  The one place that owns the device's feedback generators. Whether a tick is due is decided by the pure types
//  in HapticDetents.swift, and what it plays by HapticRouting.swift; this only fires it, at the touch that caused it,
//  and the dial's ticks and the scrub's cues (an earthwork break's thump, the slope line's tick) at most once every
//  50 ms each, so a fast gesture cannot queue more feedback than the hardware can play.
//
//  Every generator is attached to the window the touch is in and fired at a point in it. An iPad plays no haptics of
//  its own: since iPadOS 17.5 Apple Pencil Pro plays them, and only from a generator attached to a view, fired at the
//  point where the Pencil is touching (HapticRouting). An iPhone's Taptic Engine plays these generators as it always
//  has.
//

#if canImport(UIKit)
import os
import SwiftUI
import UIKit

@MainActor
public final class HapticFeedbackManager {

    public static let shared = HapticFeedbackManager()

    /// The window the generators are attached to, whose coordinates a location is given in. They are made the first
    /// time each is needed and made again only when a cue comes from another window, never per sample.
    private weak var host: UIWindow?
    private var canvas: UICanvasFeedbackGenerator?
    private var selection: UISelectionFeedbackGenerator?
    private var impacts: [HapticImpactStyle: UIImpactFeedbackGenerator] = [:]
    /// An iPad: its haptics are Apple Pencil Pro's, not a Taptic Engine's (``HapticRouting/voice(for:pencilHaptics:)``).
    private let pencilHaptics: Bool

    private var azimuthThrottle = HapticThrottle(minimumInterval: 0.05)
    /// The profile scrub's: one for both of its cues, which the Pencil plays alike.
    private var scrubThrottle = HapticThrottle(minimumInterval: 0.05)
    private var lastAzimuth: Double?
    private var scrubCues = ProfileScrubCues()

    private init() {
        pencilHaptics = UIDevice.current.userInterfaceIdiom == .pad
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - Playing a cue

    /// Plays `cue` at `location`, a point in `touched`'s coordinates (SwiftUI's global space): where the touch that
    /// caused it is, so the Pencil plays it when the Pencil is that touch. `touched` is the window it is in (the
    /// viewer's, ``TerrainViewerModel/viewerWindow``): an iPad can show two of this app's windows side by side, both
    /// active, and a point means a different place in each. Nil when the place, or the window, is not known.
    public func play(_ cue: HapticCue, at location: CGPoint?, in touched: UIWindow?) {
        guard let voice = HapticRouting.voice(for: cue, pencilHaptics: pencilHaptics) else {
            Log.ui.debug("Haptic: \(cue.rawValue, privacy: .public) plays nothing on this device")
            return
        }
        guard let window = attachedWindow(preferring: touched) else { return }
        let windowName = Self.describe(window) + (touched == nil ? ", an active scene's key window" : "")
        Log.ui.debug("Haptic: \(cue.rawValue, privacy: .public) as \(String(describing: voice), privacy: .public) at \(Self.describe(location), privacy: .public) in \(windowName, privacy: .public)")
        switch voice {
        case .canvasAlignment:
            let generator = canvasGenerator(in: window)
            // The canvas generator has no form without a place: the window's middle, when the touch's is not known.
            generator.alignmentOccurred(at: location ?? CGPoint(x: window.bounds.midX, y: window.bounds.midY))
            generator.prepare()
        case .selection:
            let generator = selectionGenerator(in: window)
            if let location { generator.selectionChanged(at: location) } else { generator.selectionChanged() }
            generator.prepare()
        case .impact(let style, let intensity):
            let generator = impactGenerator(style, in: window)
            if let location {
                generator.impactOccurred(intensity: intensity, at: location)
            } else {
                generator.impactOccurred(intensity: intensity)
            }
            generator.prepare()
        }
    }

    /// Readies the generator `cue` plays through, for a gesture about to begin in `window`.
    private func prepare(_ cue: HapticCue, in window: UIWindow?) {
        guard let voice = HapticRouting.voice(for: cue, pencilHaptics: pencilHaptics),
              let window = attachedWindow(preferring: window) else { return }
        switch voice {
        case .canvasAlignment: canvasGenerator(in: window).prepare()
        case .selection: selectionGenerator(in: window).prepare()
        case .impact(let style, _): impactGenerator(style, in: window).prepare()
        }
    }

    /// The window the generators are attached to: `touched`, the one the touch is in, when it is known. Otherwise the
    /// key window of an active scene, which is the touch's only while one of this app's windows is up: since iOS 15
    /// each scene has its own key window, so with two side by side neither says which was touched. A window other
    /// than the last drops the generators made for that one.
    private func attachedWindow(preferring touched: UIWindow?) -> UIWindow? {
        let window: UIWindow
        if let touched {
            window = touched
        } else {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            guard let found = scene?.keyWindow ?? scene?.windows.first else { return nil }
            window = found
        }
        if window !== host {
            host = window
            canvas = nil
            selection = nil
            impacts = [:]
        }
        return window
    }

    private func canvasGenerator(in window: UIWindow) -> UICanvasFeedbackGenerator {
        if let canvas { return canvas }
        let made = UICanvasFeedbackGenerator(view: window)
        canvas = made
        return made
    }

    private func selectionGenerator(in window: UIWindow) -> UISelectionFeedbackGenerator {
        if let selection { return selection }
        let made = UISelectionFeedbackGenerator(view: window)
        selection = made
        return made
    }

    private func impactGenerator(_ style: HapticImpactStyle, in window: UIWindow) -> UIImpactFeedbackGenerator {
        if let existing = impacts[style] { return existing }
        let feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle = switch style {
        case .light: .light
        case .medium: .medium
        case .rigid: .rigid
        }
        let made = UIImpactFeedbackGenerator(style: feedbackStyle, view: window)
        impacts[style] = made
        return made
    }

    private nonisolated static func describe(_ location: CGPoint?) -> String {
        guard let location else { return "no place" }
        return String(format: "(%.0f, %.0f)", location.x, location.y)
    }

    /// The window, for the log: its scene's session, which tells two of this app's windows apart.
    private static func describe(_ window: UIWindow) -> String {
        "scene " + (window.windowScene.map { String($0.session.persistentIdentifier.prefix(8)) } ?? "none")
    }

    // MARK: - Sun azimuth

    /// A drag on the azimuth control has begun at `degrees`, in `window`. Starting on a heading is not arriving at it.
    public func beginAzimuthGesture(at degrees: Double, in window: UIWindow?) {
        lastAzimuth = degrees
        prepare(.azimuthDetent, in: window)
    }

    public func endAzimuthGesture() {
        lastAzimuth = nil
    }

    /// Ticks when the drag arrives at one of the eight compass headings (N, NE, E, SE, S, SW, W, NW), within
    /// 1.5 degrees, or passes over one between two readings. `location` is the touch, in the coordinates of `window`,
    /// the one it is in.
    public func azimuthSnap(degrees: Double, at location: CGPoint?, in window: UIWindow?) {
        let arrived = AzimuthDetents.detent(from: lastAzimuth, to: degrees)
        lastAzimuth = degrees
        guard let detent = arrived else { return }
        guard azimuthThrottle.allows(at: now) else {
            Log.ui.debug("Haptic: azimuth detent \(detent) reached at \(degrees, format: .fixed(precision: 1)) degrees, dropped by the throttle")
            return
        }
        Log.ui.debug("Haptic: azimuth tick, detent \(detent) at \(degrees, format: .fixed(precision: 1)) degrees")
        play(.azimuthDetent, at: location, in: window)
    }

    // MARK: - The profile scrub

    /// Feeds the scrub position along a profile, in metres: a firm thump as it crosses one of `breaks`, the breaks of
    /// the earthwork signatures shown, and a tick as it crosses a place where `slopeLine`, the steepness the slope chart
    /// draws (distance, degrees), crosses its 20° flank line (``ProfileScrubCues``). `nil` is the finger lifting.
    /// `location` is the touch, in the coordinates of `window`, the one it is in.
    public func scrub(
        distance: Double?, breaks: [Double], slopeLine: [(distance: Double, slope: Double)],
        at location: CGPoint?, in window: UIWindow?
    ) {
        guard let distance else {
            scrubCues.reset()
            return
        }
        guard let cue = scrubCues.update(to: distance, breaks: breaks, slopeLine: slopeLine) else { return }
        guard scrubThrottle.allows(at: now) else {
            Log.ui.debug("Haptic: \(cue.rawValue, privacy: .public) at \(distance, format: .fixed(precision: 1)) m along the profile, dropped by the throttle")
            return
        }
        Log.ui.debug("Haptic: \(cue.rawValue, privacy: .public) at \(distance, format: .fixed(precision: 1)) m along the profile")
        play(cue, at: location, in: window)
    }
}

// MARK: - Where a view is

/// Where a view lies in its window, kept for haptics fired at a touch in it, without redrawing the view as it moves:
/// the view holds one in `@State` and ``SwiftUI/View/hapticAnchor(_:)`` writes it.
@MainActor
final class HapticAnchor {
    /// The view's frame in its window (SwiftUI's global space); null until it is laid out.
    var frame: CGRect = .null

    /// The view's middle, in its window's coordinates.
    var windowCentre: CGPoint? {
        HapticRouting.windowPoint(CGPoint(x: frame.width / 2, y: frame.height / 2), inViewAt: frame)
    }
}

extension View {
    /// Keeps `anchor` at this view's frame in its window. Written from a geometry change, not state, so a view that
    /// moves (a tray scrolling, a dock easing in) is not redrawn for it.
    func hapticAnchor(_ anchor: HapticAnchor) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchor.frame = $0 }
    }
}
#endif
