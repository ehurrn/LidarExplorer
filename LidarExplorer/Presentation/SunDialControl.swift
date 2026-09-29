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
/// Each one keeps its own drag. Only one is on screen at a time (the profile panel replaces the dock), and each draws
/// the model's sun while nobody drags it, so the bearing the pencil's barrel roll or a reset sets shows on whichever dial
/// is up, and a dial that appears shows it from its first frame.
struct SunDialControl: View {

    let model: TerrainViewerModel
    /// The dial's diameter at the default text size; it scales with the text from there (``SunAzimuthDial``).
    let baseDiameter: CGFloat
    /// True from the drag's first sample until it ends, however it ends. The dock reads it to stay out from under the
    /// finger or the Pencil on the dial while the camera moves.
    @Binding var isDragging: Bool
    /// Called when a drag ends, after the exact bearing is written.
    let onEnded: () -> Void

    /// The sun under a finger or the Pencil on the dial, from the drag's first bearing to its lift; nil otherwise, when
    /// the dial draws the model's. The drag writes the map's sun through ``SunDialCommit``: a turn of at least the dial's
    /// least turn at most every 50 ms, the newest bearing trailing, so the map re-lights as the dial turns without
    /// re-shading every visible tile on every sample, or on a touch trembling at rest. The exact bearing is written on
    /// lift.
    ///
    /// Only the drag's own: a copy of the model's bearing kept here started at 315° each time the dial was made (it is
    /// made again whenever a style that takes the sun comes back) and caught up on appearing, so the readout rolled
    /// from 315° to a sun nothing had moved.
    @State private var dragAzimuth: Double?
    /// When the drag writes the map's sun, with the least turn for this dial's size: a smaller dial's sun orbits
    /// nearer its centre, where the same tremor turns the bearing further.
    @State private var sunCommit: SunDialCommit
    /// The trailing write ``sunCommit`` asked for, cancelled when the drag ends.
    @State private var trailingTask: Task<Void, Never>?

    init(model: TerrainViewerModel, baseDiameter: CGFloat, isDragging: Binding<Bool>, onEnded: @escaping () -> Void) {
        self.model = model
        self.baseDiameter = baseDiameter
        _isDragging = isDragging
        self.onEnded = onEnded
        _sunCommit = State(initialValue: SunDialCommit(
            interval: 0.05, minimumTurn: SunDialCommit.minimumTurn(forDiameter: baseDiameter)))
    }

    var body: some View {
        // Read here, not in the init: there it would make the view showing the dial (the profile panel, charts and all)
        // re-evaluate on every write of the sun.
        let azimuth = dragAzimuth ?? model.azimuth
        SunAzimuthDial(
            azimuth: azimuth,
            isActive: isDragging,
            baseDiameter: baseDiameter,
            onBegan: {
                isDragging = true
                HapticFeedbackManager.shared.beginAzimuthGesture(at: azimuth, in: model.viewerWindow?())
            },
            onChanged: { degrees, location in
                dragAzimuth = degrees
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
                // been skipped as within the least turn of the bearing already written. A touch that never swung the
                // sun (a tap on the readout) writes nothing.
                if let dragAzimuth { model.azimuth = dragAzimuth }
                dragAzimuth = nil
                onEnded()
            }
        )
    }
}
