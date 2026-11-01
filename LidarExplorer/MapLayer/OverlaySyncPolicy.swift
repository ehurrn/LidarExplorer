//
//  OverlaySyncPolicy.swift
//  LidarExplorer
//
//  Whether a polyline the map bridge draws has to be rebuilt, decided apart from MapKit so the harness checks it.
//
//  `TerrainMapView.updateUIView` runs for every change SwiftUI sees, the sun's azimuth included (the terrain version
//  moves with it), so through a dial drag it ran twenty times a second. The profile's line and the thalweg's trace were
//  removed and added again on each run, and MapKit tore down and rebuilt their polyline renderers under the gesture.
//

import CoreLocation
import Foundation

public nonisolated enum OverlaySyncPolicy {

    /// Whether a polyline drawn through `from` has to be rebuilt to show `to`: a different count, or any coordinate
    /// that differs. A coordinate that is not a number never equals itself, so a line through one is always rebuilt
    /// (it draws nothing either way).
    public static func polylineChanged(from: [CLLocationCoordinate2D], to: [CLLocationCoordinate2D]) -> Bool {
        guard from.count == to.count else { return true }
        return zip(from, to).contains { a, b in a.latitude != b.latitude || a.longitude != b.longitude }
    }
}
