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

/// Supported export formats for GIS and map sharing.
public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case geoTIFF = "GeoTIFF"
    case pngWithWorldFile = "PNG + PGW"

    public var id: String { rawValue }
}

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

    public var basemap: BasemapChoice = .usgs(.shadedRelief)
    public var basemapOpacity: Double = 1.0

    // MARK: - Terrain shading

    public var style: ReliefStyle = .multiDirectional {
        didSet {
            if style != oldValue {
                pushSettings()
                if style == .elevation || style == .relativeElevation { refreshElevationRange() }
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
        public static let rakingAltitude: Double = 10
        public static let terrainOpacity: Double = 0.85
    }

    /// Light compass bearing, degrees clockwise from north.
    public var azimuth: Double = Defaults.azimuth {
        didSet { if azimuth != oldValue, style.usesSunDirection { pushSettings() } }
    }
    /// Light elevation above the horizon, degrees.
    public var altitude: Double = Defaults.altitude {
        didSet { if altitude != oldValue, style.usesSunAltitude { pushSettings() } }
    }
    /// Light elevation for the grazing-light styles, degrees.
    public var rakingAltitude: Double = Defaults.rakingAltitude {
        didSet { if rakingAltitude != oldValue, style.usesGrazingSunAltitude { pushSettings() } }
    }
    public var showsHabitationMask = false {
        didSet { if showsHabitationMask != oldValue { pushSettings() } }
    }
    public var skyViewShading: Double = 0 {
        didSet { if skyViewShading != oldValue { pushSettings() } }
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
    public var microTopographyOptions: MicroTopographyOptions = MicroTopographyOptions() {
        didSet {
            if microTopographyOptions != oldValue {
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
    public var showsExportSheet = false
    public var exportURL: URL?
    public var exportFormat: ExportFormat = .geoTIFF

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
        settings.rakingAltitudeDegrees = rakingAltitude
        settings.showsHabitationMask = showsHabitationMask
        settings.skyViewShading = Float(skyViewShading)
        settings.elevationRange = elevationExtent
        settings.contourInterval = contourInterval
        settings.palette = palette
        settings.microTopographyOptions = microTopographyOptions
        settings.thalweg = thalweg

        settingsTask = Task { [terrainProvider] in
            // Brief coalescing window (one display frame) for responsive relighting.
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            let changed = await terrainProvider.update(settings)
            if changed {
                self.terrainVersion &+= 1
            }
        }
    }

    /// Restores the shading controls to their defaults.
    ///
    /// Style is deliberately left alone: it is a choice of what to look at,
    /// not a tuning that can drift into an unhelpful state.
    public func resetShading() {
        azimuth = Defaults.azimuth
        altitude = Defaults.altitude
        rakingAltitude = Defaults.rakingAltitude
        showsHabitationMask = false
        skyViewShading = 0
        terrainOpacity = Defaults.terrainOpacity
        contourInterval = .off
        palette = .topo
        microTopographyOptions = MicroTopographyOptions()
    }

    /// Whether any shading control differs from its default.
    public var hasCustomShading: Bool {
        azimuth != Defaults.azimuth
            || altitude != Defaults.altitude
            || rakingAltitude != Defaults.rakingAltitude
            || showsHabitationMask
            || skyViewShading != 0
            || terrainOpacity != Defaults.terrainOpacity
            || contourInterval != .off
            || palette != .topo
            || microTopographyOptions != MicroTopographyOptions()
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

    // MARK: - Interaction Modes & Micro-Topography Analysis

    public enum InteractionMode: String, Sendable, CaseIterable {
        case explore
        case transect
        case viewshed
        case thalweg
        case historicalWipe
    }

    public var interactionMode: InteractionMode = .explore {
        didSet {
            if interactionMode != .transect {
                clearProfile()
            }
            if interactionMode != .explore {
                clearInspection()
            }
            if interactionMode != .viewshed {
                clearViewshed()
            }
            if interactionMode != .thalweg {
                thalwegDraft = []
            }
        }
    }

    public var isProfileModeActive: Bool {
        get { interactionMode == .transect }
        set { interactionMode = newValue ? .transect : .explore }
    }

    public var profileStart: CLLocationCoordinate2D?
    public var profileEnd: CLLocationCoordinate2D?
    public var activeProfile: ElevationProfile?
    public var activeTransectAnalysis: TransectAnalysis?
    public var transectParameters = TransectSignatureParameters()
    public var previewTransectSamples: [ProfileSample] = []
    public var isTransectDragging: Bool = false
    public var isGeneratingProfile: Bool = false
    private var profileTask: Task<Void, Never>?
    private var transectDebounceTask: Task<Void, Never>?

    public enum ProfileMetric: String, CaseIterable, Sendable {
        case elevation = "Elevation"
        case slope = "Slope"
        case curvature = "Curvature"
    }

    public var activeProfileMetric: ProfileMetric = .elevation
    public var showsTransectSignatures: Bool = true

    public func cycleProfileMetric() {
        let sequence: [ProfileMetric] = [.elevation, .slope, .curvature]
        if let idx = sequence.firstIndex(of: activeProfileMetric) {
            activeProfileMetric = sequence[(idx + 1) % sequence.count]
        } else {
            activeProfileMetric = .elevation
        }
    }

    public func toggleSignaturesOverlay() {
        showsTransectSignatures.toggle()
    }

    public func toggleProfileMode() {
        interactionMode = (interactionMode == .transect) ? .explore : .transect
    }

    public func clearProfile() {
        profileTask?.cancel()
        transectDebounceTask?.cancel()
        profileStart = nil
        profileEnd = nil
        activeProfile = nil
        activeTransectAnalysis = nil
        previewTransectSamples = []
        isTransectDragging = false
        isGeneratingProfile = false
    }

    public func beginTransectDrag(at coordinate: CLLocationCoordinate2D) {
        profileStart = coordinate
        profileEnd = coordinate
        isTransectDragging = true
        activeProfile = nil
        activeTransectAnalysis = nil
        previewTransectSamples = []
    }

    public func updateTransectDrag(to coordinate: CLLocationCoordinate2D) {
        guard let start = profileStart else { return }
        profileEnd = coordinate
        transectDebounceTask?.cancel()
        let parameters = self.transectParameters
        transectDebounceTask = Task { [terrainProvider] in
            let samples = await terrainProvider.previewTransect(from: start, to: coordinate, maxPoints: 256)
            guard !Task.isCancelled else { return }
            self.previewTransectSamples = samples
            if samples.count >= 2 {
                let pts = samples.enumerated().map { i, s in
                    ElevationProfilePoint(
                        id: i, distanceMeters: Double(s.distance),
                        elevationMeters: s.elevation.isNaN ? 0 : s.elevation,
                        coordinate: coordinate, isHighResolution: true
                    )
                }
                self.activeProfile = ElevationProfile(start: start, end: coordinate, points: pts)
            }

            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let field = await terrainProvider.transectMosaic(around: start, and: coordinate)
            let analysis = await Task.detached(priority: .userInitiated) {
                ElevationTransectEngine(field: field, parameters: parameters).analyze(from: start, to: coordinate)
            }.value
            guard !Task.isCancelled else { return }
            self.activeTransectAnalysis = analysis
        }
    }

    public func endTransectDrag(to coordinate: CLLocationCoordinate2D) {
        guard profileStart != nil else { return }
        profileEnd = coordinate
        isTransectDragging = false
        transectDebounceTask?.cancel()
        generateProfile()
    }

    public func handleMapTap(_ coordinate: CLLocationCoordinate2D) {
        switch interactionMode {
        case .transect:
            if profileStart == nil {
                profileStart = coordinate
                profileEnd = nil
                activeProfile = nil
                activeTransectAnalysis = nil
            } else if profileEnd == nil {
                profileEnd = coordinate
                generateProfile()
            } else {
                profileStart = coordinate
                profileEnd = nil
                activeProfile = nil
                activeTransectAnalysis = nil
            }
        case .viewshed:
            setViewshedObserver(coordinate)
        case .explore:
            inspect(coordinate)
        case .thalweg:
            break
        case .historicalWipe:
            break
        }
    }

    public func generateProfile() {
        guard let start = profileStart, let end = profileEnd else { return }
        profileTask?.cancel()
        isGeneratingProfile = true
        let parameters = self.transectParameters
        profileTask = Task { [terrainProvider] in
            async let legacyProfile = terrainProvider.profile(from: start, to: end)
            let field = await terrainProvider.transectMosaic(around: start, and: end)
            let analysis = await Task.detached(priority: .userInitiated) {
                ElevationTransectEngine(field: field, parameters: parameters).analyze(from: start, to: end)
            }.value
            let prof = await legacyProfile
            guard !Task.isCancelled else { return }
            self.activeProfile = prof
            self.activeTransectAnalysis = analysis
            self.isGeneratingProfile = false
        }
    }

    // MARK: - Viewshed State

    public var viewshedObserverCoordinate: CLLocationCoordinate2D?
    public var viewshedObserverEyeHeight: Float = 2.0
    public var viewshedTargetHeight: Float = 0.5
    public var viewshedRadiusMeters: Float = 2500
    public var viewshedResult: ViewshedResult?
    public var isComputingViewshed: Bool = false
    private var viewshedTask: Task<Void, Never>?

    /// The drawn mask and where it goes; replaced wholesale on every result.
    public struct ViewshedOverlayImage {
        public let image: CGImage
        public let region: GeoRegion
    }
    public private(set) var viewshedOverlay: ViewshedOverlayImage?
    /// Bumped per result so the map view swaps its overlay exactly once.
    public private(set) var viewshedVersion = 0

    /// Called continuously while the observer pin is dragged; coalesces to one
    /// computation per 60 ms of stillness.
    public func moveViewshedObserver(_ coordinate: CLLocationCoordinate2D) {
        if let current = viewshedObserverCoordinate,
           current.latitude == coordinate.latitude, current.longitude == coordinate.longitude { return }
        viewshedObserverCoordinate = coordinate
        viewshedTask?.cancel()
        viewshedTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            self?.computeViewshed()
        }
    }

    public func toggleViewshedMode() {
        interactionMode = (interactionMode == .viewshed) ? .explore : .viewshed
    }

    public func clearViewshed() {
        viewshedTask?.cancel()
        viewshedObserverCoordinate = nil
        viewshedResult = nil
        viewshedOverlay = nil
        viewshedVersion &+= 1
        isComputingViewshed = false
    }

    public func setViewshedObserver(_ coordinate: CLLocationCoordinate2D) {
        viewshedObserverCoordinate = coordinate
        computeViewshed()
    }

    public func computeViewshed() {
        guard let observer = viewshedObserverCoordinate else { return }
        viewshedTask?.cancel()
        isComputingViewshed = true
        viewshedTask = Task { [terrainProvider] in
            let result = await terrainProvider.viewshed(
                at: observer,
                eyeHeight: self.viewshedObserverEyeHeight,
                targetHeight: self.viewshedTargetHeight,
                maxRadiusMeters: self.viewshedRadiusMeters
            )
            guard !Task.isCancelled else { return }
            self.viewshedResult = result?.result
            self.viewshedOverlay = result.flatMap { snapshot in
                snapshot.result.display.makeImage().map { ViewshedOverlayImage(image: $0, region: snapshot.region) }
            }
            self.viewshedVersion &+= 1
            self.isComputingViewshed = false
        }
    }

    // MARK: - River Thalweg Drawing (REM)

    public var thalweg: [ThalwegPoint] = [] { didSet { if thalweg != oldValue { pushSettings() } } }
    public private(set) var thalwegDraft: [CLLocationCoordinate2D] = []

    public func extendThalwegDraft(_ coordinate: CLLocationCoordinate2D) { thalwegDraft.append(coordinate) }

    public func commitThalwegDraft() {
        let drawn = thalwegDraft
        thalwegDraft = []
        interactionMode = .explore
        Task { [terrainProvider] in
            let points = await terrainProvider.thalweg(from: drawn)
            self.thalweg = points
        }
    }

    // MARK: - Historical Maps

    public private(set) var historicalMaps: [HistoricalMapOverlay] = []
    public var historicalOpacity: Double = 0.8
    public enum WipeOrientation: String, CaseIterable, Sendable {
        case vertical = "Vertical"
        case horizontal = "Horizontal"
    }

    public var historicalAboveTerrain = true
    /// 0...1 of the screen width/height drawn with the historical map; nil shows all of it.
    public var historicalWipeFraction: Double?
    public var historicalWipeOrientation: WipeOrientation = .vertical

    public func importHistoricalMaps(from urls: [URL]) {
        let fallback = visibleGeoRegion
        let images = urls.filter { ["png", "jpg", "jpeg", "tif", "tiff"].contains($0.pathExtension.lowercased()) }
        Task {
            for url in images {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let worldURL = HistoricalMapImporter.worldFileURL(for: url, among: urls)
                let world = worldURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.flatMap(WorldFile.init(text:))
                if let imported = try? await Task.detached(priority: .userInitiated, operation: {
                    try HistoricalMapImporter.importMap(imageURL: url, worldFile: world, fallbackRegion: fallback)
                }).value {
                    historicalMaps.append(HistoricalMapOverlay(imported: imported))
                }
            }
        }
    }

    public func removeHistoricalMaps() { historicalMaps = []; historicalWipeFraction = nil }

    // MARK: - SSURGO Soils

    public var showsSoils = false { didSet { if showsSoils { loadSoils() } else { soilSurvey = nil; soilVersion &+= 1 } } }
    public private(set) var soilSurvey: SoilSurvey?
    public private(set) var soilVersion = 0

    public func loadSoils() {
        let region = visibleGeoRegion
        Task {
            let survey = await SoilDataAccessClient.shared.survey(covering: region)
            guard self.showsSoils else { return }
            self.soilSurvey = survey
            self.soilVersion &+= 1
        }
    }

    public func importSoilGeoJSON(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let polygons = try? SoilGeoJSON.polygons(from: data) else { return }
        soilSurvey = SoilSurvey(polygons: polygons)
        showsSoils = true
        soilVersion &+= 1
    }

    public func soilUnit(at coordinate: CLLocationCoordinate2D) -> SoilMapUnit? { soilSurvey?.unit(at: coordinate) }


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
        guard style == .elevation || style == .relativeElevation else { return }
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

    // MARK: - GeoTIFF Export

    public func exportCurrentRegionAsGeoTIFF() async throws -> URL {
        guard let grid = await terrainProvider.activeGrid(covering: visibleRegion) else {
            throw GeoTIFFWriterError.emptyGrid
        }
        let bounds = grid.region.mercatorBounds
        guard (bounds.maxX - bounds.minX) > 0, (bounds.maxY - bounds.minY) > 0 else {
            throw GeoTIFFWriterError.degenerateBounds
        }
        let center = grid.region.center
        let z = max(1, Int(round(log2(360.0 / max(visibleRegion.span.longitudeDelta, 0.00001)))))
        let filename = String(
            format: "LidarExplorer_%.4f_%.4f_z%d.tif",
            center.latitude,
            center.longitude,
            z
        )
        let directory = FileManager.default.temporaryDirectory
        let fileURL = directory.appendingPathComponent(filename)
        try GeoTIFFWriter.shared.export(grid: grid, to: fileURL)
        self.exportURL = fileURL
        return fileURL
    }

    public func exportCurrentGeoTIFF() async throws -> URL {
        try await exportCurrentRegionAsGeoTIFF()
    }
}
