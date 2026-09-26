//
//  PencilAzimuthRing.swift
//  LidarExplorer
//
//  The instrument a Pencil Pro barrel roll projects onto the glass: a ring above the hover point with
//  the sun riding its rim and the compass detents drawn, so the roll's effect is seen where the hand
//  is, not only in the re-shaded tiles. Also the transient pill that names what a squeeze or
//  double-tap just did.
//
//  Each overlay is its own view taking the model, so only its body reads the value it shows: the ring
//  moves with every hover sample (up to 120 Hz), and read by the viewer's body each sample would
//  rebuild the whole screen, map view included.
//

import SwiftUI

struct PencilAzimuthRing: View {

    let azimuth: Double

    private let diameter: CGFloat = 92

    var body: some View {
        ZStack {
            // The house glass, whose rim holds over snow-white hillshade and turns solid under Increase Contrast.
            Color.clear
                .glassSurface(in: Circle())

            ForEach(DialGeometry.compassDetents, id: \.self) { heading in
                let near = DialGeometry.nearestDetent(to: azimuth, tolerance: 6) == heading
                // A concrete colour, not the hierarchical `.tertiary`: under rotationEffect that style draws
                // nothing (see the dock's dial), so only the unrotated north tick would show.
                Capsule()
                    .fill(near ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color(uiColor: .tertiaryLabel)))
                    .frame(width: near ? 2.5 : 1.5,
                           height: heading.truncatingRemainder(dividingBy: 90) == 0 ? 8 : 5)
                    .offset(y: -(diameter / 2 - 7))
                    .rotationEffect(.degrees(heading))
            }

            // The sun, on an orbit inside the ticks (it ends where the longest begin), so the one that glows is
            // never under it.
            Circle()
                .fill(Color.orange.gradient)
                .frame(width: 12, height: 12)
                .shadow(color: .orange.opacity(0.7), radius: 5)
                .offset(y: -(diameter / 2 - 17))
                .rotationEffect(.degrees(azimuth))

            Text(String(format: "%03d°", DialGeometry.wholeDegrees(azimuth)))
                .font(.caption.weight(.semibold).monospacedDigit())
                // The ring is a fixed 92 pt instrument hidden from VoiceOver (the dock's dial carries the value
                // and scales), so its readout stops growing before it reaches the sun's orbit.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// The ring, placed above the hover point (beside it just under the top bar), clear of the top bar and never over the
/// tip (``TerrainViewerModel/PencilRollIndication/ringCentre(in:lift:margin:)``). Laid out in the map view's own
/// space: the ring is placed in a reader that ignores the safe area, as the map does, so a point the coordinator
/// reads with `location(in: map)` lands where the pencil is. The viewer places the layer inside the safe area, so the
/// outer reader sees the insets (status bar, top bar, dock) that the inner one, ignoring them, reports as zero.
struct PencilRollRingLayer: View {

    let model: TerrainViewerModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far from the pencil the ring's centre rides, clear of the hand and the tip.
    private let lift: CGFloat = 80
    /// Half the ring and a margin: the ring's centre stays this far inside the safe area.
    private let inset: CGFloat = 60

    var body: some View {
        GeometryReader { safeArea in
            let insets = safeArea.safeAreaInsets
            GeometryReader { map in
                if let indication = model.pencilRollIndication {
                    let safe = CGRect(x: insets.leading, y: insets.top,
                                      width: max(map.size.width - insets.leading - insets.trailing, 0),
                                      height: max(map.size.height - insets.top - insets.bottom, 0))
                    let centre = indication.ringCentre(in: safe, lift: lift, margin: inset)
                    // `.position` fills the map, so the scale is anchored at the ring's centre, not the map's: the ring
                    // grows and shrinks where it is instead of flying in from the middle of the screen.
                    let anchor = UnitPoint(x: centre.x / max(map.size.width, 1), y: centre.y / max(map.size.height, 1))
                    let activity = indication.activity
                    PencilAzimuthRing(azimuth: indication.azimuth)
                        .position(centre)
                        .transition(reduceMotion
                                    ? .opacity : .scale(scale: 0.6, anchor: anchor).combined(with: .opacity))
                        // Keyed on the roll's activity, not the whole indication: the point moves with every hover
                        // sample, so the ring follows the pencil and fades about a second after the roll stops. Only
                        // its own clock takes it down: a newer ring, stirred or shown since, stays.
                        .task(id: activity) {
                            try? await Task.sleep(for: .milliseconds(900))
                            guard !Task.isCancelled else { return }
                            model.dismissPencilRollIndication(activity: activity)
                        }
                }
            }
            .ignoresSafeArea()
        }
        .allowsHitTesting(false)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: model.pencilRollIndication == nil)
    }
}

/// A transient pill naming what a Pencil squeeze or double-tap just did, dropped in just below the top bar.
struct ToolNoticeOverlay: View {

    let model: TerrainViewerModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let notice = model.toolNotice {
                Text(notice.text)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassSurface(in: Capsule())
                    .padding(.top, 12)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    // Keyed on the notice, which is new each time one is posted, even in the same words: the clock
                    // restarts and VoiceOver hears it again. Only its own clock takes it down.
                    .task(id: notice) {
                        // VoiceOver hears the change the pill shows.
                        AccessibilityNotification.Announcement(notice.text).post()
                        try? await Task.sleep(for: .milliseconds(1400))
                        guard !Task.isCancelled else { return }
                        model.dismissToolNotice(notice)
                    }
            }
        }
        .allowsHitTesting(false)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.toolNotice)
    }
}
