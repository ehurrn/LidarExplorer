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
        didSet {
            if style != oldValue {
                pushSettings()
                if style == .elevation { refreshElevationRange() }
            }
        }
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
    public var contourInterval: ContourInterval = {
        guard let raw = UserDefaults.standard.string(forKey: "contourInterval"),
              let interval = ContourInterval(rawValue: raw) else {
            return .off
        }
        return interval
    }() {
        didSet {
            UserDefaults.standard.set(contourInterval.rawValue, forKey: "contourInterval")
            if contourInterval != oldValue {
                pushSettings()
            }
        }
    }
    public var palette: HypsometricPalette = {
        guard let raw = UserDefaults.standard.string(forKey: "hypsometricPalette"),
              let pal = HypsometricPalette(rawValue: raw) else {
            return .topo
        }
        return pal
    }() {
        didSet {
            UserDefaults.standard.set(palette.rawValue, forKey: "hypsometricPalette")
            if palette != oldValue {
                pushSettings()
            }
        }
    }

    /// Shared absolute-elevation range for the .elevation style, fitted to the
    /// visible area (nil until tiles report extents; render falls back).
    private var elevationExtent: ClosedRange<Float>?
    public var showsTerrain: Bool = true

    /// Bumped whenever tiles must be redrawn. The map view watches this.
    public private(set) var terrainVersion: Int = 0

    // MARK: - Disk Cache & Storage

    public private(set) var diskCacheSizeFormatted: String = "—"

    /// Share of tile lookups served from disk, as "72% of 1,431".
    ///
    /// Shown beside the cache's size because the two only mean something
    /// together: bytes are what the cache costs, hit rate is what it returns.
    public private(set) var diskCacheHitRateFormatted: String = "—"

    public func refreshDiskCacheStats() async {
        if let size = await terrainProvider.diskCacheSize() {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
            formatter.countStyle = .file
            diskCacheSizeFormatted = formatter.string(fromByteCount: size)
        } else {
            diskCacheSizeFormatted = "—"
        }

        let stats = await terrainProvider.diskCacheStatistics()
        if stats.reads == 0 {
            diskCacheHitRateFormatted = "—"
        } else {
            let percent = Int((stats.hitRate * 100).rounded())
            let reads = NumberFormatter.localizedString(
                from: NSNumber(value: stats.reads), number: .decimal
            )
            diskCacheHitRateFormatted = "\(percent)% of \(reads)"
        }
    }

    public func clearDiskCache() async {
        await terrainProvider.clearDiskCache()
        terrainVersion &+= 1
        await refreshDiskCacheStats()
    }

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
    public var activeSpot: SpotInspection? = nil

    /// Elevation from the active inspection, if available.
    public var inspectedElevation: Float? {
        if let activeSpot {
            return activeSpot.elevationMeters
        }
        if case .elevation(let elevation, _) = inspectionState {
            return elevation
        }
        return nil
    }

    /// Display unit for elevation values.
    public var elevationUnit: ElevationUnit = {
        if let saved = UserDefaults.standard.string(forKey: "elevationUnit"),
           let unit = ElevationUnit(rawValue: saved) {
            return unit
        }
        return .meters
    }() {
        didSet {
            UserDefaults.standard.set(elevationUnit.rawValue, forKey: "elevationUnit")
        }
    }

    /// Formats an elevation value in metres according to the selected unit.
    public func formattedElevation(_ meters: Float) -> String {
        switch elevationUnit {
        case .meters:
            return String(format: "%.1f m", meters)
        case .feet:
            let feet = meters * 3.28084
            return String(format: "%.0f ft", feet)
        }
    }

    /// Formats a distance in metres according to the selected unit.
    public func formattedDistance(_ meters: Double) -> String {
        switch elevationUnit {
        case .meters:
            if meters >= 1000 {
                return String(format: "%.2f km", meters / 1000.0)
            } else {
                return String(format: "%.0f m", meters)
            }
        case .feet:
            let feet = meters * 3.28084
            if feet >= 5280 {
                return String(format: "%.2f mi", feet / 5280.0)
            } else {
                return String(format: "%.0f ft", feet)
            }
        }
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
    public var pendingRegion: MKCoordinateRegion?

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
        // append only if recording is active, avoiding MainActor task flooding.
        self.terrainProvider = terrainProvider ?? TerrainTileProvider(
            report: { [weak log] event in
                guard log?.isRecordingActive == true else { return }
                Task { @MainActor in log?.record(event) }
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

        // Warm the Metal compute pipelines in the background to avoid a hitch
        // during the first user pan/zoom gesture.
        Task.detached(priority: .utility) {
            _ = await RasterCompute.shared.isGPUAvailable()
        }
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
        settings.elevationRange = elevationExtent
        settings.contourInterval = contourInterval
        settings.palette = palette

        settingsTask = Task { [terrainProvider] in
            // Brief coalescing window (one display frame) for responsive relighting.
            try? await Task.sleep(for: .milliseconds(16))
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
        contourInterval = .off
        palette = .topo
    }

    /// Whether any shading control differs from its default.
    public var hasCustomShading: Bool {
        azimuth != Defaults.azimuth
            || altitude != Defaults.altitude
            || terrainOpacity != Defaults.terrainOpacity
            || contourInterval != .off
            || palette != .topo
    }

    // MARK: - Inspection

    /// 3DEP geographic bounds: contiguous US, Alaska, Hawaii, and territories.
    private static let coverage = GeoRegion(
        minLatitude: 15.0, maxLatitude: 72.0,
        minLongitude: -179.5, maxLongitude: -64.0
    )

    private var inspectTask: Task<Void, Never>?

    public func clearInspection() {
        inspectTask?.cancel()
        activeSpot = nil
        inspectionState = .idle
    }

    /// Reads the elevation under a coordinate from whatever tiles are loaded.
    ///
    /// If no cached tile covers the coordinate yet but tiles are actively
    /// loading (resolution is known), retries after a short delay to allow
    /// in-flight tiles to land rather than prematurely showing "unavailable".
    public func inspect(_ coordinate: CLLocationCoordinate2D) {
        inspectTask?.cancel()
        activeSpot = nil
        inspectionState = .loading(coordinate)
        inspectTask = Task { [terrainProvider] in
            // Allow up to 3 attempts with a brief wait between each,
            // giving in-flight tiles time to land in the cache.
            for attempt in 1...3 {
                let spot = await terrainProvider.inspectSpot(at: coordinate)
                let value: Float? = if let spot { spot.elevationMeters } else { await terrainProvider.elevation(at: coordinate) }
                let resolution = await terrainProvider.finestResolution()
                guard !Task.isCancelled else { return }
                guard case .loading(let target) = self.inspectionState,
                      target.latitude == coordinate.latitude && target.longitude == coordinate.longitude
                else { return }

                if let spot {
                    self.activeSpot = spot
                    self.inspectionState = .elevation(spot.elevationMeters, coordinate)
                    self.currentResolution = resolution
                    #if canImport(UIKit)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    #endif
                    return
                } else if let value {
                    self.activeSpot = SpotInspection(
                        coordinate: coordinate,
                        elevationMeters: value,
                        slopeDegrees: .nan,
                        aspectDegrees: .nan
                    )
                    self.inspectionState = .elevation(value, coordinate)
                    self.currentResolution = resolution
                    #if canImport(UIKit)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    #endif
                    return
                }

                let isOutsideCoverage = !Self.coverage.contains(coordinate)
                if isOutsideCoverage {
                    self.inspectionState = .noCoverage(coordinate)
                    self.currentResolution = resolution
                    return
                }

                // Tiles are loading but haven't arrived yet — wait briefly.
                if attempt < 3 {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    guard case .loading = self.inspectionState else { return }
                }
            }

            // After retries, accept that elevation is genuinely unavailable.
            guard !Task.isCancelled else { return }
            guard case .loading = self.inspectionState else { return }
            self.inspectionState = .failed(coordinate)
            self.currentResolution = await terrainProvider.finestResolution()
        }
    }

    // MARK: - Elevation Profile & Cross-Section

    public var isProfileModeActive: Bool = false {
        didSet {
            if !isProfileModeActive {
                clearProfile()
            } else {
                clearInspection()
            }
        }
    }
    public var profileStart: CLLocationCoordinate2D?
    public var profileEnd: CLLocationCoordinate2D?
    public var activeProfile: ElevationProfile?
    public var isGeneratingProfile: Bool = false
    private var profileTask: Task<Void, Never>?

    public func toggleProfileMode() {
        isProfileModeActive.toggle()
    }

    public func clearProfile() {
        profileTask?.cancel()
        profileStart = nil
        profileEnd = nil
        activeProfile = nil
        isGeneratingProfile = false
    }

    public func handleMapTap(_ coordinate: CLLocationCoordinate2D) {
        if isProfileModeActive {
            if profileStart == nil {
                profileStart = coordinate
                profileEnd = nil
                activeProfile = nil
            } else if profileEnd == nil {
                profileEnd = coordinate
                generateProfile()
            } else {
                profileStart = coordinate
                profileEnd = nil
                activeProfile = nil
            }
        } else {
            inspect(coordinate)
        }
    }

    public func generateProfile() {
        guard let start = profileStart, let end = profileEnd else { return }
        profileTask?.cancel()
        isGeneratingProfile = true
        profileTask = Task { [terrainProvider] in
            let result = await terrainProvider.profile(from: start, to: end)
            guard !Task.isCancelled else { return }
            self.activeProfile = result
            self.isGeneratingProfile = false
        }
    }

    /// Refreshes the displayed resolution after tiles settle.
    /// The visible map region as a projection-free GeoRegion.
    private var visibleGeoRegion: GeoRegion {
        GeoRegion(
            center: visibleRegion.center,
            latitudeSpan: visibleRegion.span.latitudeDelta,
            longitudeSpan: visibleRegion.span.longitudeDelta
        )
    }

    /// Refits the .elevation colour range to the visible area's loaded tiles.
    ///
    /// Only does work in .elevation mode. `ElevationRangePolicy` decides whether
    /// the newly-measured extent is different enough to adopt: a bare `!=` on a
    /// fixed 10 m snap re-tinted the whole screen on every pan wobble and
    /// fragmented the rendered-tile disk cache (its key embeds the range). When
    /// the policy does adopt, `pushSettings` drives a single seam-free re-render
    /// of every on-screen tile against the new shared range.
    public func refreshElevationRange() {
        guard style == .elevation else { return }
        let region = visibleGeoRegion
        Task { [terrainProvider] in
            guard let raw = await terrainProvider.elevationRange(in: region) else { return }
            guard let next = ElevationRangePolicy.next(raw: raw, current: self.elevationExtent)
            else { return }
            self.elevationExtent = next
            self.pushSettings()
        }
    }

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

    // MARK: - Landmarks & Bookmarks

    public var showsLandmarks = false
    public var bookmarks: [Landmark] = {
        guard let data = UserDefaults.standard.data(forKey: "saved_bookmarks"),
              let items = try? JSONDecoder().decode([Landmark].self, from: data) else {
            return []
        }
        return items
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(bookmarks) {
                UserDefaults.standard.set(data, forKey: "saved_bookmarks")
            }
        }
    }

    public func saveBookmark(named name: String) {
        let center = visibleRegion.center
        let latHemisphere = center.latitude >= 0 ? "N" : "S"
        let lonHemisphere = center.longitude >= 0 ? "E" : "W"
        let subtitle = String(
            format: "%.4f°%@, %.4f°%@",
            abs(center.latitude), latHemisphere,
            abs(center.longitude), lonHemisphere
        )
        let altitude = max(500, visibleRegion.span.latitudeDelta * 111_000)
        let bookmark = Landmark(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom Site" : name,
            subtitle: subtitle,
            category: .custom,
            latitude: center.latitude,
            longitude: center.longitude,
            altitudeMeters: altitude,
            recommendedAzimuth: azimuth
        )
        bookmarks.insert(bookmark, at: 0)
    }

    public func deleteBookmark(id: UUID) {
        bookmarks.removeAll { $0.id == id }
    }

    public func flyTo(landmark: Landmark) {
        let region = MKCoordinateRegion(
            center: landmark.coordinate,
            latitudinalMeters: landmark.altitudeMeters,
            longitudinalMeters: landmark.altitudeMeters
        )
        visibleRegion = region
        pendingRegion = region
        azimuth = landmark.recommendedAzimuth
        showsLandmarks = false
    }
}
