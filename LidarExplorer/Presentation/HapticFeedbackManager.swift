//
//  HapticFeedbackManager.swift
//  LidarExplorer
//
//  The one place that owns the device's feedback generators. Whether a tick is due is decided by the pure types
//  in HapticDetents.swift; this only fires it, at most once every 50 ms per kind so a fast gesture cannot queue
//  more feedback than the Taptic Engine can play.
//

#if canImport(UIKit)
import os
import UIKit

@MainActor
public final class HapticFeedbackManager {

    public static let shared = HapticFeedbackManager()

    private let selection = UISelectionFeedbackGenerator()
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private var azimuthThrottle = HapticThrottle(minimumInterval: 0.05)
    private var signatureThrottle = HapticThrottle(minimumInterval: 0.05)
    private var lastAzimuth: Double?
    private var breakCrossings = BreakCrossingDetector()

    private init() {}

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - Sun azimuth

    /// A drag on the azimuth control has begun at `degrees`. Starting on a heading is not arriving at it.
    public func beginAzimuthGesture(at degrees: Double) {
        lastAzimuth = degrees
        selection.prepare()
    }

    public func endAzimuthGesture() {
        lastAzimuth = nil
    }

    /// Ticks when the drag arrives at one of the eight compass headings (N, NE, E, SE, S, SW, W, NW), within
    /// 1.5 degrees, or passes over one between two readings.
    public func azimuthSnap(degrees: Double) {
        let arrived = AzimuthDetents.detent(from: lastAzimuth, to: degrees)
        lastAzimuth = degrees
        guard let detent = arrived else { return }
        guard azimuthThrottle.allows(at: now) else {
            Log.ui.debug("Haptic: azimuth detent \(detent) reached at \(degrees, format: .fixed(precision: 1)) degrees, dropped by the throttle")
            return
        }
        Log.ui.debug("Haptic: azimuth tick, detent \(detent) at \(degrees, format: .fixed(precision: 1)) degrees")
        selection.selectionChanged()
        selection.prepare()
    }

    // MARK: - Earthwork breaks

    /// A firm thump, for the scrub crossing a break in an earthwork signature.
    public func signatureHit() {
        guard signatureThrottle.allows(at: now) else { return }
        Log.ui.debug("Haptic: earthwork break thump")
        impact.impactOccurred(intensity: 0.7)
        impact.prepare()
    }

    /// Feeds the scrub position along a profile, in metres, and thumps as it crosses one of `breaks`. `nil` is
    /// the finger lifting.
    public func scrub(distance: Double?, breaks: [Double]) {
        guard let distance else {
            breakCrossings.reset()
            return
        }
        if breakCrossings.update(to: distance, breaks: breaks) { signatureHit() }
    }
}
#endif
