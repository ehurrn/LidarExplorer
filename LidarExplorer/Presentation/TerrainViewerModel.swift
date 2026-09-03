//
//  TerrainViewerModel.swift
//  LidarExplorer
//
//  Main-actor state for the terrain viewer.
//

import CoreLocation
import MapKit
import Observation
import SwiftUI
import os

/// Observable state for the viewer.
///
/// Built on `@Observable` rather than `ObservableObject`, so dragging the
/// light azimuth invalidates only the views that read it.
///
/// Terrain itself is not state here. It streams through
/// ``TerrainTileOverlay``, which lets MapKit decide what to fetch and when —
/// so there is no "current raster", no load button, and no modal wait.
@MainActor
@Observable
public final class TerrainViewerModel {

    // MARK: - Basemap

    public var basemap: TerrainBasemap = .shadedRelief
    public var basemapOpacity: Double = 1.0

    // MARK: - Terrain shading

    public var style: ReliefStyle = .multiDirectional {
        didSet { if style != oldValue { pushSettings() } }
    }
    /// Light compass bearing, degrees clockwise from north.
    public var azimuth: Double = 315 {
        didSet { if azimuth != oldValue, style.usesIllumination { pushSettings() } }
    }
    /// Light elevation above the horizon, degrees.
    public var altitude: Double = 35 {
        didSet { if altitude != oldValue, style.usesIllumination { pushSettings() } }
    }
    public var terrainOpacity: Double = 0.85
    public var showsTerrain: Bool = true

    /// Bumped whenever tiles must be redrawn. The map view watches this.
    public private(set) var terrainVersion: Int = 0

    // MARK: - Readout

    public private(set) var inspectedElevation: Float?
    public private(set) var inspectedCoordinate: CLLocationCoordinate2D?
    /// Ground sample distance of the finest tile loaded, for display.
    public private(set) var currentResolution: Double?
    public private(set) var statusMessage: String?

    // MARK: - Map

    public var visibleRegion: MKCoordinateRegion
    public var pendingRecenter: CLLocationCoordinate2D?

    public private(set) var userCoordinate: CLLocationCoordinate2D?
    public private(set) var locationAuthorization: CLAuthorizationStatus = .notDetermined

    // MARK: - Dependencies

    /// Shared with the tile overlay, which reads shading settings from it.
    public let terrainProvider: TerrainTileProvider
    private let location: any LocationProviding
    private var settingsTask: Task<Void, Never>?

    public init(
        terrainProvider: TerrainTileProvider? = nil,
        location: (any LocationProviding)? = nil,
        initialCenter: CLLocationCoordinate2D = CLLocationCoordinate2D(
            latitude: 38.6605, longitude: -90.0621  // Cahokia Mounds
        )
    ) {
        self.terrainProvider = terrainProvider ?? TerrainTileProvider()
        self.location = location ?? LocationService()
        self.visibleRegion = MKCoordinateRegion(
            center: initialCenter,
            span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
        )
    }

    // MARK: - Lifecycle

    public func start() {
        location.onUpdate = { [weak self] coordinate, authorization in
            guard let self else { return }
            self.userCoordinate = coordinate
            self.locationAuthorization = authorization
        }
        location.start()
        pushSettings()
    }

    /// Sends shading settings to the provider and asks for a redraw.
    ///
    /// Coalesced through a single task so dragging a slider does not queue a
    /// reload per frame; only the latest settings survive.
    private func pushSettings() {
        settingsTask?.cancel()
        var settings = TerrainStyleSettings()
        settings.style = style
        settings.azimuthDegrees = azimuth
        settings.altitudeDegrees = altitude

        settingsTask = Task { [terrainProvider] in
            // Brief coalescing window while a slider is in motion.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let changed = await terrainProvider.update(settings)
            guard !Task.isCancelled, changed else { return }
            self.terrainVersion &+= 1
        }
    }

    // MARK: - Inspection

    /// Reads the elevation under a coordinate from whatever tiles are loaded.
    public func inspect(_ coordinate: CLLocationCoordinate2D) {
        inspectedCoordinate = coordinate
        Task { [terrainProvider] in
            let value = await terrainProvider.elevation(at: coordinate)
            let resolution = await terrainProvider.finestResolution()
            self.inspectedElevation = value
            self.currentResolution = resolution
        }
    }

    /// Refreshes the displayed resolution after tiles settle.
    public func refreshResolution() {
        Task { [terrainProvider] in
            self.currentResolution = await terrainProvider.finestResolution()
        }
    }

    // MARK: - Location

    /// Centres on the user, awaiting the first fix if none has arrived.
    ///
    /// Reading a cached location synchronously returns `nil` on the first
    /// launch after permission is granted, because authorisation precedes the
    /// first fix — which is why this button used to need two taps.
    public func goToUserLocation() async {
        if let known = userCoordinate {
            pendingRecenter = known
            return
        }
        statusMessage = "Finding your location…"
        if let coordinate = await location.currentLocation() {
            userCoordinate = coordinate
            pendingRecenter = coordinate
            statusMessage = nil
        } else {
            statusMessage = "Location unavailable"
        }
    }
}
