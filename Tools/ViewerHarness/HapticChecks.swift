//
//  HapticChecks.swift
//  ViewerHarness
//
//  When the haptics fire: the azimuth detents, the earthwork-break crossings and the throttle, decided by pure
//  logic so a fast sweep or a hovering finger is tested without a device.
//

import CoreGraphics
import Foundation

@MainActor
func runHapticChecks() {
    print("\n=== Haptics ===")
    checkAzimuthDetents()
    checkBreakCrossings()
    checkHapticThrottle()
    checkHapticRouting()
    checkWipeCues()
    checkHapticWindowPoint()
}

/// The detent indices fired by moving through `angles` in order, the first from rest.
private func fired(_ angles: [Double]) -> [Int] {
    var previous: Double?
    var out: [Int] = []
    for angle in angles {
        if let index = AzimuthDetents.detent(from: previous, to: angle) { out.append(index) }
        previous = angle
    }
    return out
}

@MainActor
private func checkAzimuthDetents() {
    print("\n--- V1. azimuth detents ---")
    check("the detents are the eight compass headings, 1.5 degrees either side",
          AzimuthDetents.headings == [0, 45, 90, 135, 180, 225, 270, 315] && AzimuthDetents.window == 1.5)

    check("entering the window of a heading ticks once, and moving about inside it does not tick again",
          fired([3, 1.4, 0.2, -1.2, 359.5, 0.8]) == [0] && fired([44, 43.6, 44, 45, 46, 46.4]) == [1],
          "\(fired([3, 1.4, 0.2, -1.2, 359.5, 0.8])) \(fired([44, 43.6, 44, 45, 46, 46.4]))")
    check("just outside the window does not tick at either edge, where just inside does",
          fired([10, 43.4, 43.4]).isEmpty && fired([50, 46.6, 46.51]).isEmpty && fired([100, 120, 130]).isEmpty
          && fired([10, 43.6]) == [1] && fired([50, 46.4]) == [1],
          "\(fired([10, 43.4])) \(fired([10, 43.6]))")
    check("leaving a window and coming back ticks again",
          fired([44, 45, 50, 45.5]) == [1, 1], "\(fired([44, 45, 50, 45.5]))")

    // From 3 degrees, outside the north window: the sweep meets each of the eight headings once, north on the way in.
    let sweep = stride(from: 3.0, through: 359.0, by: 0.5).map { $0 }
    check("a slow sweep round the dial ticks exactly eight times, once per heading in order, coming back to north last",
          fired(sweep) == [1, 2, 3, 4, 5, 6, 7, 0], "\(fired(sweep))")
    // From 357.5, outside the north window (a sweep that starts inside it would tick north again on the way round).
    let backwards = stride(from: 357.5, through: 0.0, by: -0.5).map { $0 }
    check("the same sweep backwards ticks eight times too, once per heading, north last",
          fired(backwards) == [7, 6, 5, 4, 3, 2, 1, 0], "\(fired(backwards))")

    check("a fast drag that jumps clean over a window still ticks: 40 to 50 and back, 356 to 3 across north and back",
          fired([40, 50]) == [1] && fired([50, 40]) == [1] && fired([356, 3]) == [0] && fired([3, 356]) == [0],
          "\(fired([40, 50])) \(fired([50, 40])) \(fired([356, 3])) \(fired([3, 356]))")
    check("moving out through the middle of the window it is already in does not tick again",
          fired([44, 50]) == [1] && fired([46, 40]) == [1], "\(fired([44, 50])) \(fired([46, 40]))")
    check("a slow wrap over north ticks: 358 to 0.5 enters the window",
          fired([355, 358, 0.5]) == [0], "\(fired([355, 358, 0.5]))")
    check("angles outside 0...360 and ones that are not numbers are handled: 405 is 45, and NaN or infinity never ticks",
          fired([400, 405]) == [1] && fired([-315, -314]) == [1] && fired([.nan]).isEmpty && fired([10, .infinity, 20]).isEmpty
          && fired([760]).isEmpty && fired([765]) == [1] && fired([-720 - 355]).isEmpty && fired([-720 - 359]) == [0]
          && fired([1080 + 44, 1080 + 50]) == [1]
          && AzimuthDetents.detent(from: .nan, to: 90) == 2,
          "\(fired([400, 405])) \(fired([-315, -314]))")
}

@MainActor
private func checkBreakCrossings() {
    print("\n--- V2. earthwork breaks ---")
    let breaks = [20.0, 45.5, 80.0]
    func hits(_ path: [Double], tolerance: Double = 1) -> Int {
        var detector = BreakCrossingDetector(tolerance: tolerance)
        return path.filter { detector.update(to: $0, breaks: breaks) }.count
    }
    let forward = stride(from: 0.0, through: 100.0, by: 1.0).map { $0 }
    check("scrubbing across three breaks thumps three times, forward and back",
          hits(forward) == 3 && hits(forward.reversed()) == 3, "\(hits(forward)) \(hits(forward.reversed()))")
    check("a hop across a break thumps once, and a hop that skips two breaks thumps once for the update",
          hits([10, 30]) == 1 && hits([10, 60]) == 1 && hits([10, 12]) == 0,
          "\(hits([10, 30])) \(hits([10, 60]))")
    check("a finger hovering on a break does not thump again and again, but does once it has left and returned",
          hits([18, 20.2, 19.9, 20.4, 19.6, 20]) == 1 && hits([18, 20, 25, 20]) == 2, "\(hits([18, 20.2, 19.9, 20.4]))")
    check("landing on a break counts, and so does starting on one",
          hits([0, 20]) == 1 && hits([20]) == 1)

    var detector = BreakCrossingDetector()
    _ = detector.update(to: 19.5, breaks: breaks)
    detector.reset()
    check("lifting the finger forgets the position, so the next touch on the same break thumps",
          detector.update(to: 19.5, breaks: breaks), "")
    var lone = BreakCrossingDetector()
    check("no breaks never thump, and neither does a distance that is not a number",
          !lone.update(to: 50, breaks: []) && !lone.update(to: .nan, breaks: breaks) && !lone.update(to: .infinity, breaks: breaks)
          && hits([10, 30]) == 1)
    check("a break that is not a number is ignored",
          { () -> Bool in
              var d = BreakCrossingDetector()
              _ = d.update(to: 10, breaks: [.nan, 30])
              return d.update(to: 40, breaks: [.nan, 30])
          }())
}

@MainActor
private func checkHapticThrottle() {
    print("\n--- V3. throttle ---")
    var throttle = HapticThrottle(minimumInterval: 0.05)
    let first = throttle.allows(at: 10.000)
    let tooSoon = throttle.allows(at: 10.030)
    let stillSoon = throttle.allows(at: 10.049)
    let due = throttle.allows(at: 10.050)
    let afterDue = throttle.allows(at: 10.080)
    check("the first tick fires, ones inside 50 ms are dropped, and one at 50 ms fires again",
          first && !tooSoon && !stillSoon && due && !afterDue, "\(first) \(tooSoon) \(stillSoon) \(due) \(afterDue)")
    var burst = HapticThrottle(minimumInterval: 0.05)
    let count = (0..<200).map { Double($0) / 200 }.filter { burst.allows(at: $0) }.count
    check("a stream of 200 events a second is held to 20 a second, the queue never floods",
          count == 20, "\(count) ticks")
    var dropped = HapticThrottle(minimumInterval: 0.05)
    let fireAtOne = dropped.allows(at: 1.0)
    let droppedTick = dropped.allows(at: 1.04)     // dropped: must not push the next allowance back
    check("a dropped tick does not restart the clock", fireAtOne && !droppedTick && dropped.allows(at: 1.05))
    var backwards = HapticThrottle(minimumInterval: 0.05)
    _ = backwards.allows(at: 100)
    check("a clock that goes backwards cannot silence the haptics for good",
          backwards.allows(at: 5) && !backwards.allows(at: 5.01) && backwards.allows(at: 5.06))
}

@MainActor
private func checkHapticRouting() {
    print("\n--- V4. which feedback each cue plays ---")
    let cues = HapticCue.allCases
    let marks = cues.filter { $0 != .wipeStep }
    let onPad = marks.map { HapticRouting.voice(for: $0, pencilHaptics: true) }
    check("on an iPad every cue that marks an arrival plays as canvas alignment feedback, the kind Apple Pencil Pro plays",
          cues.count == 7 && marks.count == 6 && onPad.allSatisfy { $0 == .canvasAlignment }, "\(onPad)")
    let padStep = HapticRouting.voice(for: .wipeStep, pencilHaptics: true)
    check("on an iPad the split wipe's step plays nothing: a jump between two readings is speed, not a snap, and a flick of the handle would buzz the Pencil",
          padStep == nil, "\(String(describing: padStep))")

    func phone(_ cue: HapticCue) -> HapticVoice? { HapticRouting.voice(for: cue, pencilHaptics: false) }
    func said(_ cue: HapticCue) -> String { String(describing: phone(cue)) }
    check("on an iPhone a compass detent on the dial and a style change are selection ticks, as before",
          phone(.azimuthDetent) == .selection && phone(.styleChanged) == .selection,
          "\(said(.azimuthDetent)) \(said(.styleChanged))")
    check("on an iPhone the earthwork break is the medium thump at 0.7 and a spot read the light impact, as before",
          phone(.earthworkBreak) == .impact(.medium, intensity: 0.7) && phone(.spotRead) == .impact(.light, intensity: 1),
          "\(said(.earthworkBreak)) \(said(.spotRead))")
    check("on an iPhone the split wipe keeps its three: medium at the middle, light at 0.4 per step, rigid when turned",
          phone(.wipeCentre) == .impact(.medium, intensity: 1) && phone(.wipeStep) == .impact(.light, intensity: 0.4)
              && phone(.wipeTurned) == .impact(.rigid, intensity: 1),
          "\(said(.wipeCentre)) \(said(.wipeStep)) \(said(.wipeTurned))")
    let phoneVoices = cues.map(phone)
    check("on an iPhone every cue plays, and none as canvas feedback, which its Taptic Engine does not play",
          phoneVoices.allSatisfy { $0 != nil } && !phoneVoices.contains(.canvasAlignment), "\(phoneVoices.map { String(describing: $0) })")
}

@MainActor
private func checkWipeCues() {
    print("\n--- V5. split wipe cues ---")
    func cue(_ old: Double, _ new: Double) -> HapticCue? { HapticRouting.wipeCue(from: old, to: new) }
    check("crossing the middle either way is the middle's cue, however small the move",
          cue(0.4, 0.6) == .wipeCentre && cue(0.6, 0.4) == .wipeCentre && cue(0.499, 0.501) == .wipeCentre
              && cue(0.501, 0.499) == .wipeCentre,
          "\(String(describing: cue(0.4, 0.6))) \(String(describing: cue(0.499, 0.501)))")
    check("landing on the middle from either side is the middle's cue",
          cue(0.45, 0.5) == .wipeCentre && cue(0.55, 0.5) == .wipeCentre,
          "\(String(describing: cue(0.45, 0.5))) \(String(describing: cue(0.55, 0.5)))")
    check("leaving the middle is not arriving at it: a small move off it is silent, a long one a step",
          cue(0.5, 0.51) == nil && cue(0.5, 0.49) == nil && cue(0.5, 0.6) == .wipeStep && cue(0.5, 0.4) == .wipeStep,
          "\(String(describing: cue(0.5, 0.51))) \(String(describing: cue(0.5, 0.6)))")
    check("a jump of more than 2 % between two readings is a step, either way",
          cue(0.1, 0.13) == .wipeStep && cue(0.13, 0.1) == .wipeStep && cue(0.7, 0.95) == .wipeStep,
          "\(String(describing: cue(0.1, 0.13))) \(String(describing: cue(0.13, 0.1)))")
    check("2 % or less between two readings is silent, as is no move at all",
          cue(0.1, 0.115) == nil && cue(0.3, 0.3) == nil && cue(0.8, 0.785) == nil,
          "\(String(describing: cue(0.1, 0.115))) \(String(describing: cue(0.3, 0.3)))")
    check("a reading that is not a number never ticks",
          cue(.nan, 0.6) == nil && cue(0.4, .nan) == nil && cue(.nan, .nan) == nil)
}

@MainActor
private func checkHapticWindowPoint() {
    print("\n--- V6. where a haptic is played ---")
    let dial = CGRect(x: 900, y: 1250, width: 76, height: 76)
    let point = HapticRouting.windowPoint(CGPoint(x: 38, y: 10), inViewAt: dial)
    check("a touch in a view is played at the view's place in the window plus the touch's place in the view",
          point == CGPoint(x: 938, y: 1260), "\(String(describing: point))")
    let outside = HapticRouting.windowPoint(CGPoint(x: -20, y: 90), inViewAt: dial)
    check("a drag that has left the view is still played where the touch is, not clamped to the view",
          outside == CGPoint(x: 880, y: 1340), "\(String(describing: outside))")
    check("a view not yet laid out, or a reading that is not a number, gives no place, not the window's corner",
          HapticRouting.windowPoint(CGPoint(x: 10, y: 10), inViewAt: .null) == nil
              && HapticRouting.windowPoint(CGPoint(x: CGFloat.nan, y: 10), inViewAt: dial) == nil
              && HapticRouting.windowPoint(CGPoint(x: 10, y: 10), inViewAt: .infinite) == nil)
}
