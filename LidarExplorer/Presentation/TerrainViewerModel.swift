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

/// What a GeoTIFF export contains.
public nonisolated enum GeoTIFFContent: Equatable, Sendable {
    /// The raw elevation samples of the viewport.
    case elevation
    /// A micro-topography product computed over the viewport: the raw scalar values, not the colour map,
    /// named for the style that shows it.
    case analytical(ReliefStyle)
}

/// How an active transect can be exported.
public nonisolated enum TransectExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv = "CSV"
    case geoJSON = "GeoJSON"

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .geoJSON: "geojson"
        }
    }

    public var menuTitle: String {
        switch self {
        case .csv: "Export Profile Data (CSV)"
        case .geoJSON: "Export Earthwork Signatures (GeoJSON)"
        }
    }

    public var systemImage: String {
        switch self {
        case .csv: "tablecells"
        case .geoJSON: "map"
        }
    }
}

/// Why an export could not be made, in words a person can act on.
public nonisolated enum TerrainExportError: LocalizedError, Equatable, Sendable {
    case noTransect
    case transectInProgress
    case analyticalUnavailable(ReliefStyle)
    case noMarkup

    public var errorDescription: String? {
        switch self {
        case .noMarkup:
            "There is no markup to export. Draw a line or drop a waypoint first."
        case .noTransect:
            "There is no transect to export. Draw one first."
        case .transectInProgress:
            "The transect is still being drawn. Finish it, then export."
        case .analyticalUnavailable(.relativeElevation):
            "Relative Elevation needs a river thalweg, so it cannot be exported as a GeoTIFF yet."
        case .analyticalUnavailable(let style):
            "\(style.displayName) could not be computed for this view. It needs terrain that has already drawn."
        }
    }
}

/// What a touch on the drawing layer does.
public nonisolated enum MarkupTool: String, CaseIterable, Sendable {
    case pen
    case highlighter
    /// Touches pass through to the map, so it can be panned and zoomed without leaving markup.
    case hand

    public var systemImage: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .hand: "hand.draw"
        }
    }

    public var label: String {
        switch self {
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .hand: "Move the map"
        }
    }
}

/// File names for exports: what is in the file, then a sortable timestamp, so exports of the same view
/// side by side are told apart and never overwrite one another.
///
/// Main-actor isolated, like the model that names its files: `ReliefStyle.dockLabel` is.
public enum ExportFileName {
    /// `LidarExplorer_<Content>_<yyyyMMdd-HHmmss>.tif`, where the content is `Elevation` or the style's
    /// dock label (`LRM`, `SVF`, `RRIM`, ...).
    public static func geoTIFF(_ content: GeoTIFFContent, date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let label: String
        switch content {
        case .elevation: label = "Elevation"
        case .analytical(let style): label = style.dockLabel
        }
        return "LidarExplorer_\(label)_\(timestamp(date, timeZone)).tif"
    }

    /// `LidarExplorer_Transect_<yyyyMMdd-HHmmss>.<csv|geojson>`.
    public static func transect(_ format: TransectExportFormat, date: Date = Date(), timeZone: TimeZone = .current) -> String {
        "LidarExplorer_Transect_\(timestamp(date, timeZone)).\(format.fileExtension)"
    }

    /// `LidarExplorer_Markup_<yyyyMMdd-HHmmss>.geojson`.
    public static func markup(date: Date = Date(), timeZone: TimeZone = .current) -> String {
        "LidarExplorer_Markup_\(timestamp(date, timeZone)).geojson"
    }

    private static func timestamp(_ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
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
    /// The map's width in points, reported by the map view, for sizing an offline download to what is on screen.
    public var mapWidthPoints: Double = 1024
    public var pendingRecenter: CLLocationCoordinate2D?
    public var pendingRegion: MKCoordinateRegion?
    public var showsExportSheet = false
    public var exportURL: URL?
    public var exportFormat: ExportFormat = .geoTIFF
    /// Why the last export could not be made, for an alert; nil when none is pending.
    public var exportErrorMessage: String?
    /// True while an export is being made, so a second tap is not another export.
    public var isPreparingExport = false

    /// The style whose analytical product a GeoTIFF export can offer: a micro-topography style, except the
    /// relative elevation model, which needs a river thalweg the export cannot take.
    public var analyticalExportStyle: ReliefStyle? {
        style.microTopographyProduct != nil && style != .relativeElevation ? style : nil
    }

    /// Whether a finished transect can be exported now: not while it is still being drawn (its analysis
    /// lags the drag) and not while another export is being made.
    public var canExportTransect: Bool {
        activeTransectAnalysis != nil && activeTransectFrame != nil && !isTransectDragging && !isPreparingExport
    }

    public private(set) var userCoordinate: CLLocationCoordinate2D?
    public private(set) var locationAuthorization: CLAuthorizationStatus = .notDetermined

    // MARK: - Dependencies

    /// Shared with the tile overlay, which reads shading settings from it.
    public let terrainProvider: TerrainTileProvider
    /// Recent tile activity, for the in-app debug panel.
    public let tileLog: TileActivityLog
    private let location: any LocationProviding
    /// Where the field notebook is kept between launches; nil for a model that keeps nothing (the harness's).
    private let markupStore: FieldNotebookStore?
    private var settingsTask: Task<Void, Never>?

    public init(
        terrainProvider: TerrainTileProvider? = nil,
        location: (any LocationProviding)? = nil,
        fieldNotebookStore: FieldNotebookStore? = nil,
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
        self.markupStore = fieldNotebookStore
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
        Task { await restoreFieldMarkup() }

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
    /// The shading controls as the provider receives them.
    private func currentSettings() -> TerrainStyleSettings {
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
        return settings
    }

    private func pushSettings() {
        settingsTask?.cancel()
        let settings = currentSettings()

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
    public var activeTransectAnalysis: TransectAnalysis? {
        didSet {
            if activeTransectAnalysis == nil { activeTransectFrame = nil }
        }
    }
    /// The frame `activeTransectAnalysis` was measured in. Its samples' positions mean nothing without it, and
    /// it cannot be rebuilt from `profileStart` and `profileEnd` at export time: they move while a transect is
    /// dragged and the analysis lags them. Only the origin is kept (`TileMosaicField.coordinate(for:)` needs
    /// nothing else), so the tiles the analysis read are not held alive against memory pressure.
    var activeTransectFrame: (any GeoreferencedElevationField)?
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
            self.activeTransectFrame = TileMosaicField(origin: field.origin, layers: [])
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
            self.activeTransectFrame = TileMosaicField(origin: field.origin, layers: [])
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

    // MARK: - Offline download

    /// The offline-download screen's controller. The model keeps it, so a download goes on when Settings closes;
    /// `TerrainViewerModel+OfflineHarvest.swift` makes it on first use.
    @ObservationIgnored var offlineHarvestController: OfflineHarvestController?

    // MARK: - Local elevation

    /// A GeoTIFF the user brought in, mounted over the online elevation.
    public struct LocalElevationFile: Identifiable, Sendable {
        public let id: UUID
        public let name: String
        public let width: Int
        public let height: Int
        public let footprint: GeoRegion
    }

    /// The most GeoTIFFs held at once: each is up to 64 MB in memory.
    public static let maxLocalElevationFiles = 4
    /// Newest first.
    public private(set) var localElevationFiles: [LocalElevationFile] = []
    public private(set) var isImportingLocalElevation = false
    /// Why the last import was refused, for the settings sheet; nil when none is pending.
    public var localElevationMessage: String?

    /// The providers behind ``localElevationFiles``, so one can be unmounted.
    private var localProviders: [UUID: LocalGeoTIFFProvider] = [:]

    /// Reads a GeoTIFF off the main actor, mounts it over the online elevation, has the map redraw and flies to it.
    ///
    /// A file with the name of one already imported replaces it. A file that cannot be used, or one too many, is
    /// refused with the reason in ``localElevationMessage`` and nothing else changes. Only one import runs at a
    /// time; another asked for while one is reading is ignored.
    public func importLocalElevation(from url: URL) async {
        guard !isImportingLocalElevation else { return }
        isImportingLocalElevation = true
        defer { isImportingLocalElevation = false }
        localElevationMessage = nil

        let name = url.lastPathComponent
        if !localElevationFiles.contains(where: { $0.name == name }),
           localElevationFiles.count >= Self.maxLocalElevationFiles {
            localElevationMessage = "\(name) was not imported: at most \(Self.maxLocalElevationFiles) elevation files are kept at "
                + "once. Remove one first."
            return
        }
        // A file from the document picker is readable only while this is held, so across the whole read.
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let provider: LocalGeoTIFFProvider
        do {
            provider = try await LocalGeoTIFFProvider.load(from: url)
        } catch let error as LocalGeoTIFFProvider.ImportError {
            localElevationMessage = error.explanation(forFile: name)
            return
        } catch {
            localElevationMessage = "\(name) could not be opened: \(error.localizedDescription)."
            return
        }

        if let index = localElevationFiles.firstIndex(where: { $0.name == provider.name }) {
            let replaced = localElevationFiles.remove(at: index)
            if let old = localProviders.removeValue(forKey: replaced.id) { await terrainProvider.unmountLocalElevation(old) }
        }
        await terrainProvider.mountLocalElevation(provider)
        let file = LocalElevationFile(
            id: UUID(), name: provider.name, width: provider.width, height: provider.height, footprint: provider.footprint)
        localProviders[file.id] = provider
        localElevationFiles.insert(file, at: 0)
        terrainVersion &+= 1
        flyTo(footprint: provider.footprint)
    }

    /// Unmounts one imported file and has the map redraw.
    public func removeLocalElevation(id: UUID) async {
        guard let index = localElevationFiles.firstIndex(where: { $0.id == id }) else { return }
        localElevationFiles.remove(at: index)
        if let provider = localProviders.removeValue(forKey: id) { await terrainProvider.unmountLocalElevation(provider) }
        terrainVersion &+= 1
    }

    /// Unmounts every imported file and has the map redraw.
    public func removeAllLocalElevation() async {
        guard !localElevationFiles.isEmpty else { return }
        localElevationFiles.removeAll()
        localProviders.removeAll()
        await terrainProvider.unmountLocalElevation()
        terrainVersion &+= 1
    }

    /// Sends the map to `footprint` with a little room round it, staying inside what MapKit can show: a region with a
    /// longitude beyond 180 (a raster on the 0...360 convention) or a span past the world raises an exception there.
    private func flyTo(footprint: GeoRegion) {
        var longitude = footprint.centerLongitude
        if longitude > 180 { longitude -= 360 } else if longitude < -180 { longitude += 360 }
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: min(max(footprint.centerLatitude, -85), 85), longitude: longitude),
            span: MKCoordinateSpan(
                latitudeDelta: min(max(footprint.latitudeSpan * 1.15, 0.0005), 170),
                longitudeDelta: min(max(footprint.longitudeSpan * 1.15, 0.0005), 350)))
        visibleRegion = region
        pendingRegion = region
    }

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
    public var visibleGeoRegion: GeoRegion {
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

    /// The viewport as a GeoTIFF: its raw elevation, or the active micro-topography product's values.
    ///
    /// The analytical export uses the options the map is showing (the dock's sun for the low-sun products),
    /// so the file is the product as displayed, minus the colour map.
    public func exportCurrentRegionAsGeoTIFF(_ content: GeoTIFFContent = .elevation) async throws -> URL {
        let grid: ElevationGrid
        switch content {
        case .elevation:
            guard let elevation = await terrainProvider.activeGrid(covering: visibleRegion) else {
                throw GeoTIFFWriterError.emptyGrid
            }
            grid = elevation
        case .analytical(let analyticalStyle):
            guard let product = analyticalStyle.microTopographyProduct, analyticalStyle != .relativeElevation else {
                throw TerrainExportError.analyticalUnavailable(analyticalStyle)
            }
            let region = GeoRegion(
                center: visibleRegion.center,
                latitudeSpan: visibleRegion.span.latitudeDelta,
                longitudeSpan: visibleRegion.span.longitudeDelta
            )
            let options = currentSettings().analysisOptions(for: product)
            guard let analytical = await terrainProvider.analyticalRaster(for: region, product: product, options: options) else {
                throw TerrainExportError.analyticalUnavailable(analyticalStyle)
            }
            grid = analytical
        }
        let bounds = grid.region.mercatorBounds
        guard (bounds.maxX - bounds.minX) > 0, (bounds.maxY - bounds.minY) > 0 else {
            throw GeoTIFFWriterError.degenerateBounds
        }
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(ExportFileName.geoTIFF(content))
        // The write is megabytes of float samples: off the main actor, so the map stays responsive.
        try await Task.detached(priority: .userInitiated) {
            try GeoTIFFWriter.shared.export(grid: grid, to: fileURL)
        }.value
        self.exportURL = fileURL
        return fileURL
    }

    public func exportCurrentGeoTIFF(_ content: GeoTIFFContent = .elevation) async throws -> URL {
        try await exportCurrentRegionAsGeoTIFF(content)
    }

    /// The finished transect as a file: a CSV of its profile or a GeoJSON of its track and earthwork signatures.
    ///
    /// Georeferenced through the frame the analysis was measured in, which was kept with it.
    ///
    /// Formatted and written off the main actor: a 20,000-sample transect takes tens of milliseconds to
    /// format, which on the main actor would freeze profile scrubbing for several frames.
    public func exportActiveTransect(as format: TransectExportFormat) async throws -> URL {
        guard !isTransectDragging else { throw TerrainExportError.transectInProgress }
        guard let analysis = activeTransectAnalysis, let frame = activeTransectFrame else {
            throw TerrainExportError.noTransect
        }
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(ExportFileName.transect(format))
        try await Task.detached(priority: .userInitiated) {
            switch format {
            case .csv:
                try Data(TransectExporter.exportCSV(from: analysis, in: frame).utf8).write(to: fileURL, options: .atomic)
            case .geoJSON:
                try TransectExporter.exportGeoJSON(from: analysis, in: frame).write(to: fileURL, options: .atomic)
            }
        }.value
        return fileURL
    }

    // MARK: - 3D view

    /// The scene the 3D view shows; setting it presents the view.
    public var terrain3DScene: Terrain3DScene?
    public private(set) var isPreparingTerrain3D = false
    /// Why the 3D view could not be made, for an alert; nil when none is pending.
    public var inspectorMessage: String?

    /// Builds the viewport's terrain into a mesh draped with the shaded map, and presents it, or records why not.
    ///
    /// The mesh is made off the main actor. It is built at 1x: the view stretches it for the exaggeration slider
    /// rather than rebuilding it on every tick.
    public func openTerrain3D() async {
        guard !isPreparingTerrain3D else { return }
        isPreparingTerrain3D = true
        inspectorMessage = nil
        defer { isPreparingTerrain3D = false }

        guard let grid = await terrainProvider.activeGrid(covering: visibleRegion) else {
            inspectorMessage = "No terrain has drawn for this view yet. Pan or zoom until it has, then try again."
            return
        }
        let texture = await terrainProvider.shadedComposite(over: grid.region, maxPixels: 2048)
        let mesh = await Task.detached(priority: .userInitiated) {
            TerrainMeshBuilder.build(grid: grid, maxDimension: 192, zExaggeration: 1)
        }.value
        guard !mesh.positions.isEmpty else {
            inspectorMessage = "The terrain in this view has no valid elevation to show in 3D."
            return
        }
        terrain3DScene = Terrain3DScene(mesh: mesh, texture: texture)
    }

    // MARK: - Field markup

    /// Lines drawn over the map, held as ground coordinates so they stay put as it moves.
    public private(set) var fieldTraces: [FieldAnnotationTrace] = []
    public private(set) var fieldWaypoints: [FieldWaypoint] = []
    /// Bumped on every change to the markup, so the map redraws it exactly once per change.
    public private(set) var markupVersion = 0
    /// Whether the drawing layer is over the map.
    public var isMarkingUp = false
    public var markupTool: MarkupTool = .pen
    /// The ink colour as `#RRGGBB`.
    public var markupColorHex = FieldMarkup.defaultInkHex
    /// The width a stroke is drawn and saved at, in points: a broad marker, a fine pen.
    public var markupInkWidth: Double { markupTool == .highlighter ? 18 : 4 }
    /// The colour a new trace is saved with: the highlighter's ink is translucent.
    public var markupInkHex: String { markupTool == .highlighter ? markupColorHex + "80" : markupColorHex }
    /// Set by the map view: turns a point in window coordinates into the coordinate under it.
    public var markupCoordinateConverter: ((CGPoint) -> CLLocationCoordinate2D?)?
    /// Reads the ground height under a new waypoint. Nil uses the terrain already drawn; set by the harness, to hold
    /// a lookup open while something else happens.
    public var markupElevationLookup: ((CLLocationCoordinate2D) async -> Float?)?

    private enum MarkupItem {
        case trace(UUID)
        case waypoint(UUID)
    }
    /// What was added, oldest first, so undo can take back the newest whichever kind it is.
    private var markupHistory: [MarkupItem] = []

    public var hasFieldMarkup: Bool { !fieldTraces.isEmpty || !fieldWaypoints.isEmpty }

    // MARK: Keeping the notebook

    /// Whether the notebook saved on disk has been read into the model. Until it has, nothing is written.
    public private(set) var hasRestoredFieldMarkup = false
    /// Something to tell the user about the saved notebook, for an alert; nil when none is pending.
    public var markupNotice: String?
    /// Bumped by a Clear, so a waypoint whose terrain lookup was already running can tell it is no longer wanted.
    private var markupClearCount = 0
    /// Saves to the store, each after the one before it, so the store sees notebooks in the order they were made:
    /// unstructured tasks make no such promise, and a stale notebook arriving last would replace a newer one.
    private var markupSaveChain: Task<Void, Never>?

    /// Reads the saved notebook into the model, saved items first, then anything drawn while it was being read.
    ///
    /// Nothing is written to disk until this has read the file, so a stroke drawn in the first moments cannot
    /// replace a notebook it has not met. A file that cannot be read for now leaves the model unrestored and the
    /// file untouched; this is tried again when the app next becomes active.
    public func restoreFieldMarkup() async {
        guard let store = markupStore, !hasRestoredFieldMarkup else { return }
        let result = await store.load()
        guard !hasRestoredFieldMarkup else { return }       // a second restore finished while this one waited
        let drawnBeforeRead = hasFieldMarkup
        switch result {
        case .empty:
            break
        case .loaded(let notebook, let dropped):
            adoptSavedFieldMarkup(notebook)
            if dropped > 0 {
                markupNotice = dropped == 1
                    ? "1 saved item in your field notes could not be read and was left out."
                    : "\(dropped) saved items in your field notes could not be read and were left out."
            }
        case .quarantined(let reason, let keptAt):
            markupNotice = "Your saved field notes could not be read (\(reason)). The file was kept as "
                + "\(keptAt.lastPathComponent) in the app's Documents folder, so nothing was deleted, and a new notebook was started."
        case .unreadable(let reason):
            Log.storage.warning("Field notes not restored yet: \(reason, privacy: .public)")
            return
        }
        hasRestoredFieldMarkup = true
        // Only what was drawn before the file was read needs writing; a notebook read and left alone is already on disk.
        if drawnBeforeRead { persistFieldMarkup() }
    }

    /// Writes the notebook to disk now, for the app going to the background. Returns when it is there or has failed.
    public func flushFieldMarkup() async {
        guard let store = markupStore else { return }
        await markupSaveChain?.value
        await store.flush()
    }

    /// Every trace and waypoint, in the order it was made.
    private func currentFieldMarkupItems() -> [FieldNotebook.Item] {
        let traces = Dictionary(fieldTraces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let waypoints = Dictionary(fieldWaypoints.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return markupHistory.compactMap { entry in
            switch entry {
            case .trace(let id): traces[id].map { .trace($0) }
            case .waypoint(let id): waypoints[id].map { .waypoint($0) }
            }
        }
    }

    private func adoptSavedFieldMarkup(_ saved: FieldNotebook) {
        let savedIDs = Set(saved.items.map(\.id))
        let items = saved.items + currentFieldMarkupItems().filter { !savedIDs.contains($0.id) }
        let notebook = FieldNotebook(items: items)
        fieldTraces = notebook.traces
        fieldWaypoints = notebook.waypoints
        markupHistory = items.map { item in
            switch item {
            case .trace(let trace): .trace(trace.id)
            case .waypoint(let waypoint): .waypoint(waypoint.id)
            }
        }
        markupVersion += 1
    }

    /// Hands the notebook to the store, which writes it shortly. Not before the saved notebook has been read.
    private func persistFieldMarkup() {
        guard let store = markupStore, hasRestoredFieldMarkup else { return }
        let notebook = FieldNotebook(items: currentFieldMarkupItems())
        let previous = markupSaveChain
        markupSaveChain = Task {
            await previous?.value
            await store.save(notebook)
        }
    }

    /// Enters or leaves markup. Entering leaves any analysis mode, whose gestures would fight the drawing.
    public func toggleFieldMarkup() {
        isMarkingUp.toggle()
        if isMarkingUp, interactionMode != .explore { interactionMode = .explore }
    }

    /// Georeferences a stroke through the map and keeps it. False when the map has not offered a way to place
    /// points, or the stroke is not a line.
    @discardableResult
    public func addFieldTrace(screenPoints: [CGPoint], colorHex: String, strokeWidth: Double) -> Bool {
        guard let convert = markupCoordinateConverter,
              let trace = StrokeGeoreferencer.trace(
                screenPoints: screenPoints, colorHex: colorHex, strokeWidth: strokeWidth, convert: convert)
        else { return false }
        fieldTraces.append(trace)
        markupHistory.append(.trace(trace.id))
        markupVersion += 1
        persistFieldMarkup()
        return true
    }

    /// Marks a point, taking its height from the terrain already drawn there if there is any.
    public func addFieldWaypoint(at coordinate: CLLocationCoordinate2D, title: String, notes: String = "") async {
        let clearsBefore = markupClearCount
        let elevation: Float?
        if let lookup = markupElevationLookup {
            elevation = await lookup(coordinate)
        } else {
            elevation = await terrainProvider.elevation(at: coordinate)
        }
        guard markupClearCount == clearsBefore else { return }      // Clear was tapped while the terrain was read
        let waypoint = FieldWaypoint(
            coordinate: coordinate, elevationMeters: elevation.flatMap { $0.isFinite ? $0 : nil },
            title: title, notes: notes)
        fieldWaypoints.append(waypoint)
        markupHistory.append(.waypoint(waypoint.id))
        markupVersion += 1
        persistFieldMarkup()
    }

    /// Takes back the newest trace or waypoint.
    public func undoFieldMarkup() {
        guard let last = markupHistory.popLast() else { return }
        switch last {
        case .trace(let id): fieldTraces.removeAll { $0.id == id }
        case .waypoint(let id): fieldWaypoints.removeAll { $0.id == id }
        }
        markupVersion += 1
        persistFieldMarkup()
    }

    public func clearFieldMarkup() {
        guard hasFieldMarkup else { return }
        fieldTraces.removeAll()
        fieldWaypoints.removeAll()
        markupHistory.removeAll()
        markupClearCount += 1
        markupVersion += 1
        persistFieldMarkup()
    }

    /// Writes the notebook as GeoJSON to a temporary `.geojson` file, off the main actor.
    public func exportFieldMarkup() async throws -> URL {
        guard hasFieldMarkup else { throw TerrainExportError.noMarkup }
        let waypoints = fieldWaypoints, traces = fieldTraces
        let name = ExportFileName.markup()
        return try await Task.detached(priority: .userInitiated) {
            let data = try FieldMarkup.exportGeoJSON(waypoints: waypoints, traces: traces)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            return url
        }.value
    }

    /// Exports the notebook and presents the share sheet, or records why it could not.
    public func shareFieldMarkup() async {
        await share { try await self.exportFieldMarkup() }
    }

    /// Exports the viewport as a GeoTIFF and presents the share sheet, or records why it could not.
    public func shareGeoTIFF(_ content: GeoTIFFContent) async {
        await share { try await self.exportCurrentGeoTIFF(content) }
    }

    /// Exports the finished transect and presents the share sheet, or records why it could not.
    public func shareTransect(as format: TransectExportFormat) async {
        await share { try await self.exportActiveTransect(as: format) }
    }

    private func share(_ export: () async throws -> URL) async {
        guard !isPreparingExport else { return }
        isPreparingExport = true
        exportErrorMessage = nil
        defer { isPreparingExport = false }
        do {
            exportURL = try await export()
            showsExportSheet = true
        } catch {
            exportErrorMessage = Self.exportMessage(for: error)
        }
    }

    private static func exportMessage(for error: Error) -> String {
        switch error {
        case GeoTIFFWriterError.emptyGrid:
            "No terrain has drawn for this view yet. Pan or zoom until it has, then try again."
        case GeoTIFFWriterError.degenerateBounds:
            "This view is too small to export."
        default:
            error.localizedDescription
        }
    }
}
