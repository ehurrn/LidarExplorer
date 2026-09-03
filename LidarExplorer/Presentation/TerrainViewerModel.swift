//
//  TerrainViewerModel.swift
//  LidarExplorer
//
//  Main-actor state for the terrain viewer.
//

import CoreGraphics
import CoreLocation
import MapKit
import Observation
import SwiftUI
import os

/// Observable state for the viewer.
///
/// Built on `@Observable` rather than `ObservableObject`. Observation tracks
/// reads per property, so dragging the light azimuth invalidates only the
/// views that read it instead of the whole tree.
///
/// `@MainActor`, because every property here drives SwiftUI. The DEM fetch and
/// the GPU work happen on actors and only their results cross back.
@MainActor
@Observable
public final class TerrainViewerModel {

    // MARK: - Basemap

    public var basemap: TerrainBasemap = .shadedRelief
    public var basemapOpacity: Double = 1.0

    // MARK: - Terrain layer

    public var style: ReliefStyle = .multiDirectional {
        didSet { if style != oldValue { rerender() } }
    }
    /// Light compass bearing in degrees, clockwise from north.
    public var azimuth: Double = 315 {
        didSet { if azimuth != oldValue, style.usesIllumination { rerender() } }
    }
    /// Light elevation above the horizon, in degrees.
    public var altitude: Double = 35 {
        didSet { if altitude != oldValue, style.usesIllumination { rerender() } }
    }
    public var terrainOpacity: Double = 0.85

    /// The rendered terrain image and the extent it covers.
    public private(set) var reliefImage: CGImage?
    public private(set) var reliefRegion: GeoRegion?

    // MARK: - Status

    public private(set) var isLoading = false
    public private(set) var statusMessage: String?
    public private(set) var statistics: ElevationGrid.Statistics?
    /// Which path computed the last relief products.
    public private(set) var backend: RasterCompute.Backend?
    public private(set) var groundSampleDistance: Double?

    /// Elevation under the last inspected point, in metres.
    public private(set) var inspectedElevation: Float?
    public private(set) var inspectedCoordinate: CLLocationCoordinate2D?

    // MARK: - Map

    public var visibleRegion: MKCoordinateRegion
    public var pendingRecenter: CLLocationCoordinate2D?

    public private(set) var userCoordinate: CLLocationCoordinate2D?
    public private(set) var locationAuthorization: CLAuthorizationStatus = .notDetermined

    // MARK: - Dependencies

    private let elevation: any ElevationProviding
    private let raster: RasterCompute
    private let location: any LocationProviding

    /// Retained so the light direction can be changed without refetching.
    private var grid: ElevationGrid?
    private var products: ReliefProducts?
    private var loadTask: Task<Void, Never>?

    public init(
        elevation: (any ElevationProviding)? = nil,
        raster: RasterCompute? = nil,
        location: (any LocationProviding)? = nil,
        initialCenter: CLLocationCoordinate2D = CLLocationCoordinate2D(
            latitude: 38.6553, longitude: -90.0621  // Cahokia Mounds
        )
    ) {
        self.elevation = elevation ?? USGS3DEPService()
        self.raster = raster ?? RasterCompute()
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
    }

    // MARK: - Terrain

    /// Whether the visible area is small enough for a useful raster.
    public var canLoadVisibleRegion: Bool {
        let region = currentGeoRegion
        return region.widthMeters < 30_000 && region.heightMeters < 30_000
    }

    private var currentGeoRegion: GeoRegion {
        GeoRegion(
            center: visibleRegion.center,
            latitudeSpan: visibleRegion.span.latitudeDelta,
            longitudeSpan: visibleRegion.span.longitudeDelta
        )
    }

    /// Fetches the DEM for the visible region and computes its relief.
    public func loadVisibleRegion(targetSamples: Int = 512) {
        loadTask?.cancel()

        let region = currentGeoRegion
        guard canLoadVisibleRegion else {
            statusMessage = "Zoom in to load terrain"
            return
        }

        isLoading = true
        statusMessage = "Loading elevation…"

        loadTask = Task { [elevation, raster] in
            let evidence = await elevation.elevation(for: region, targetSamples: targetSamples)
            guard !Task.isCancelled else { return }

            guard let grid = evidence.value else {
                let reason = evidence.unavailableReason ?? .noCoverage(.usgs3DEP)
                self.finishLoad(failure: reason)
                return
            }

            let products = await raster.reliefProducts(for: grid)
            guard !Task.isCancelled else { return }
            self.finishLoad(grid: grid, products: products, provenance: evidence.provenance)
        }
    }

    public func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        statusMessage = nil
    }

    /// Drops the terrain layer, leaving the basemap.
    public func clearTerrain() {
        cancelLoad()
        grid = nil
        products = nil
        reliefImage = nil
        reliefRegion = nil
        statistics = nil
        backend = nil
        groundSampleDistance = nil
        inspectedElevation = nil
        inspectedCoordinate = nil
        statusMessage = nil
    }

    private func finishLoad(failure: UnavailableReason) {
        isLoading = false
        statusMessage = failure.displayText
        Log.ui.notice("Terrain load failed: \(failure.displayText, privacy: .public)")
    }

    private func finishLoad(
        grid: ElevationGrid,
        products: ReliefProducts,
        provenance: Provenance?
    ) {
        self.grid = grid
        self.products = products
        self.statistics = grid.statistics()
        self.backend = products.backend
        self.groundSampleDistance = grid.groundSampleDistance
        self.isLoading = false

        rerender()

        let stats = grid.statistics()
        let cached = provenance?.isCached == true ? " · cached" : ""
        statusMessage = String(
            format: "%.0f m relief · %.1f m/px · %@%@",
            stats.range, grid.groundSampleDistance,
            products.backend.rawValue.uppercased(), cached
        )
        Log.ui.info("Terrain ready: \(self.statusMessage ?? "", privacy: .public)")
    }

    /// Rebuilds the displayed image from the cached rasters.
    ///
    /// No network and no GPU work: hillshade from cached slope and aspect is
    /// one pass of cheap arithmetic, which is what keeps the light controls
    /// responsive while dragging.
    private func rerender() {
        guard let products, let grid else { return }

        let values: [Float]
        let range: ClosedRange<Float>?

        switch style {
        case .hillshade:
            values = TerrainAnalysis.hillshade(
                products.derivatives,
                azimuthDegrees: azimuth,
                altitudeDegrees: altitude
            )
            range = 0...1
        case .multiDirectional:
            values = products.multiDirectionalRelief
            range = ReliefRenderer.robustRange(of: values)
        case .slope:
            values = products.slopeDegrees
            range = ReliefRenderer.robustRange(of: values)
        case .elevation:
            values = grid.samples
            range = ReliefRenderer.robustRange(of: values)
        }

        reliefImage = ReliefRenderer.image(
            from: values,
            width: products.width,
            height: products.height,
            style: style,
            range: range
        )
        reliefRegion = grid.region
    }

    // MARK: - Inspection

    /// Reads the elevation under a coordinate, if terrain is loaded there.
    public func inspect(_ coordinate: CLLocationCoordinate2D) {
        inspectedCoordinate = coordinate
        guard let grid, let index = grid.index(for: coordinate) else {
            inspectedElevation = nil
            return
        }
        inspectedElevation = grid.sample(x: index.x, y: index.y)
    }

    // MARK: - Location

    /// Centres on the user, awaiting the first fix if none has arrived.
    ///
    /// Reading a cached location synchronously returns `nil` on the first
    /// launch after permission is granted, because authorisation precedes the
    /// first fix — which is why the equivalent button previously appeared to
    /// need two taps.
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
