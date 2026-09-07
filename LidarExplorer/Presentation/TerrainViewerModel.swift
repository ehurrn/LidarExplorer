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
    /// Factory settings for the terrain shading controls.
    ///
    /// 315 degrees is the cartographic convention: light from the north-west.
    /// Terrain lit from below-left reads as inverted to most people, an
    /// illusion strong enough that relief maps have used this angle for a
    /// century.
    public nonisolated enum Defaults {
        public static let azimuth: Double = 315
        public static let altitude: Double = 35
        public static let terrainOpacity: Double = 0.85
    }

    /// Light compass bearing, degrees clockwise from north.
    public var azimuth: Double = Defaults.azimuth {
        didSet { if azimuth != oldValue, style.usesIllumination { pushSettings() } }
    }
    /// Light elevation above the horizon, degrees.
    public var altitude: Double = Defaults.altitude {
        didSet { if altitude != oldValue, style.usesIllumination { pushSettings() } }
    }
    public var terrainOpacity: Double = Defaults.terrainOpacity
    public var showsTerrain: Bool = true

    /// Bumped whenever tiles must be redrawn. The map view watches this.
    public private(set) var terrainVersion: Int = 0

    // MARK: - Readout

    public enum InspectionState: Sendable, Equatable {
        case idle
        case loading(CLLocationCoordinate2D)
        case elevation(Float, CLLocationCoordinate2D)
        case noCoverage(CLLocationCoordinate2D)
        case failed(CLLocationCoordinate2D)

        public static func == (lhs: InspectionState, rhs: InspectionState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle):
                return true
            case (.loading(let a), .loading(let b)),
                 (.noCoverage(let a), .noCoverage(let b)),
                 (.failed(let a), .failed(let b)):
                return a.latitude == b.latitude && a.longitude == b.longitude
            case (.elevation(let e1, let c1), .elevation(let e2, let c2)):
                return e1 == e2 && c1.latitude == c2.latitude && c1.longitude == c2.longitude
            default:
                return false
            }
        }
    }

    public private(set) var inspectionState: InspectionState = .idle

    /// Elevation from the active inspection, if available.
    public var inspectedElevation: Float? {
        if case .elevation(let elevation, _) = inspectionState {
            return elevation
        }
        return nil
    }

    /// Coordinate of the active inspection, if any.
    public var inspectedCoordinate: CLLocationCoordinate2D? {
        switch inspectionState {
        case .idle:
            return nil
        case .loading(let coordinate),
             .elevation(_, let coordinate),
             .noCoverage(let coordinate),
             .failed(let coordinate):
            return coordinate
        }
    }
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
    /// Recent tile activity, for the in-app debug panel.
    public let tileLog: TileActivityLog
    private let location: any LocationProviding
    private var settingsTask: Task<Void, Never>?

    public init(
        terrainProvider: TerrainTileProvider? = nil,
        location: (any LocationProviding)? = nil,
        initialCenter: CLLocationCoordinate2D = CLLocationCoordinate2D(
            latitude: 38.6605, longitude: -90.0621  // Cahokia Mounds
        )
    ) {
        let log = TileActivityLog()
        self.tileLog = log
        // The provider reports from its own actor; hop to the main actor to
        // append. Recording is gated inside the log, so this is inert until
        // the debug panel switches it on.
        self.terrainProvider = terrainProvider ?? TerrainTileProvider(
            report: { event in
                Task { @MainActor in log.record(event) }
            }
        )
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

    /// Restores the shading controls to their defaults.
    ///
    /// Style is deliberately left alone: it is a choice of what to look at,
    /// not a tuning that can drift into an unhelpful state.
    public func resetShading() {
        azimuth = Defaults.azimuth
        altitude = Defaults.altitude
        terrainOpacity = Defaults.terrainOpacity
    }

    /// Whether any shading control differs from its default.
    public var hasCustomShading: Bool {
        azimuth != Defaults.azimuth
            || altitude != Defaults.altitude
            || terrainOpacity != Defaults.terrainOpacity
    }

    // MARK: - Inspection

    /// 3DEP geographic bounds: contiguous US, Alaska, Hawaii, and territories.
    private static let coverage = GeoRegion(
        minLatitude: 15.0, maxLatitude: 72.0,
        minLongitude: -179.5, maxLongitude: -64.0
    )

    private var inspectTask: Task<Void, Never>?

    /// Reads the elevation under a coordinate from whatever tiles are loaded.
    public func inspect(_ coordinate: CLLocationCoordinate2D) {
        inspectTask?.cancel()
        inspectionState = .loading(coordinate)
        inspectTask = Task { [terrainProvider] in
            let value = await terrainProvider.elevation(at: coordinate)
            let resolution = await terrainProvider.finestResolution()
            guard !Task.isCancelled else { return }
            guard case .loading(let target) = self.inspectionState,
                  target.latitude == coordinate.latitude && target.longitude == coordinate.longitude
            else { return }

            if let value {
                self.inspectionState = .elevation(value, coordinate)
            } else {
                let isOutsideCoverage = !Self.coverage.contains(coordinate) || resolution == nil
                if isOutsideCoverage {
                    self.inspectionState = .noCoverage(coordinate)
                } else {
                    self.inspectionState = .failed(coordinate)
                }
            }
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
