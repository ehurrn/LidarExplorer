//
//  SunDialControl.swift
//  LidarExplorer
//
//  The sun dial with its drag, wherever it is shown: the bearing the dial draws while a finger or the Pencil turns
//  it, the drag's haptics, and when the drag writes the map's sun (SunDialCommit). The dock shows it beside the style
//  tray, and the profile panel's header shows a smaller one while the panel stands in for the dock, so the sun can be
//  turned while a profile is up (the owner: the sun dial always works; decision D6).
//

import SwiftUI

/// A ``SunAzimuthDial`` that turns the map's sun.
///
/// Each one keeps its own drag. Only one is on screen at a time (the profile panel replaces the dock), and each takes the
/// model's sun when it appears and follows it while nobody drags it, so the bearing the pencil's barrel roll or a reset
/// sets shows on whichever dial is up.
struct SunDialControl: View {

    let model: TerrainViewerModel
    /// The dial's diameter at the default text size; it scales with the text from there (``SunAzimuthDial``).
    let baseDiameter: CGFloat
    /// True from the drag's first sample until it ends, however it ends. The dock reads it to stay out from under the
    /// finger or the Pencil on the dial while the camera moves.
    @Binding var isDragging: Bool
    /// Called when a drag ends, after the exact bearing is written.
    let onEnded: () -> Void

    /// The sun while a finger or the Pencil is on the dial. The drag writes the map's sun through ``SunDialCommit``: a
    /// turn of a degree or more at most every 50 ms, the newest bearing trailing, so the map re-lights as the dial
    /// turns without re-shading every visible tile on every sample, or on a touch trembling at rest. The exact bearing
    /// is written on lift.
    @State private var localAzimuth: Double = 315
    /// When the drag writes the map's sun.
    @State private var sunCommit = SunDialCommit(interval: 0.05)
    /// The trailing write ``sunCommit`` asked for, cancelled when the drag ends.
    @State private var trailingTask: Task<Void, Never>?

    init(model: TerrainViewerModel, baseDiameter: CGFloat, isDragging: Binding<Bool>, onEnded: @escaping () -> Void) {
        self.model = model
        self.baseDiameter = baseDiameter
        _isDragging = isDragging
        self.onEnded = onEnded
    }

    var body: some View {
        SunAzimuthDial(
            azimuth: localAzimuth,
            isActive: isDragging,
            baseDiameter: baseDiameter,
            onBegan: {
                isDragging = true
                HapticFeedbackManager.shared.beginAzimuthGesture(at: localAzimuth, in: model.viewerWindow?())
            },
            onChanged: { degrees, location in
                localAzimuth = degrees
                HapticFeedbackManager.shared.azimuthSnap(degrees: degrees, at: location, in: model.viewerWindow?())
                switch sunCommit.sample(degrees, at: ProcessInfo.processInfo.systemUptime) {
                case .write(let value):
                    // A trailing write whose timer is late behind a busy main thread is void: this one supersedes it.
                    trailingTask?.cancel()
                    model.azimuth = value
                case .scheduleTrailing(let due):
                    trailingTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(max(0, due - ProcessInfo.processInfo.systemUptime)))
                        guard !Task.isCancelled, let value = sunCommit.fireTrailing(at: ProcessInfo.processInfo.systemUptime)
                        else { return }
                        model.azimuth = value
                    }
                case .none:
                    break
                }
            },
            onEnded: {
                isDragging = false
                HapticFeedbackManager.shared.endAzimuthGesture()
                trailingTask?.cancel()
                sunCommit.reset()
                // The exact bearing: the drag's last sample may have waited for the trailing write just cancelled, or
                // been skipped as within a degree of the bearing already written.
                model.azimuth = localAzimuth
                onEnded()
            }
        )
        // Read here, not in the init: there it would make the view showing the dial (the profile panel, charts and all)
        // re-evaluate on every write of the sun.
        .onAppear { localAzimuth = model.azimuth }
        .onChange(of: model.azimuth) { _, new in
            // The pencil roll or a reset moved the sun; follow unless a finger owns the dial.
            if !isDragging, abs(localAzimuth - new) > 0.5 { localAzimuth = new }
        }
    }
}
