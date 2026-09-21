//
//  TerrainViewerModel+OfflineHarvest.swift
//  LidarExplorer
//
//  Makes the offline-download controller from the app's own parts: the terrain provider's store, the basemap
//  the map is showing (if USGS's, which can be kept) and its store, the folder for job manifests and the device's
//  idle timer. Apart from the model because it reaches UIKit, which the harness cannot compile.
//

#if canImport(UIKit)
import Foundation
import MapKit
import UIKit

extension TerrainViewerModel {

    /// The controller for the download screen, made on first use and kept.
    public var offlineHarvest: OfflineHarvestController {
        if let controller = offlineHarvestController { return controller }
        let controller = OfflineHarvestController(region: visibleGeoRegion, environment: harvestEnvironment())
        controller.choose(region: visibleGeoRegion, viewportWidthPoints: mapWidthPoints)
        offlineHarvestController = controller
        return controller
    }

    /// The parts a download uses as things stand now; the basemap is whichever the map is showing.
    public func harvestEnvironment() -> OfflineHarvestController.Environment {
        let provider = terrainProvider
        let locations = offlineLocations
        try? FileManager.default.createDirectory(at: locations.manifestDirectory, withIntermediateDirectories: true)

        var basemapSource: BasemapHarvestSource?
        var basemapName: String?
        if case .usgs(let usgs) = basemap {
            basemapSource = BasemapHarvestSource(basemap: usgs, cache: locations.basemapCache)
            basemapName = usgs.displayName
        }
        return OfflineHarvestController.Environment(
            elevation: provider.elevationHarvestSource, basemaps: basemapSource, basemapName: basemapName,
            observedPixels: { await provider.observedTilePixels },
            manifestDirectory: locations.manifestDirectory,
            elevationAvailableBytes: { await provider.offlineElevationAvailableBytes() },
            basemapAvailableBytes: {
                await locations.basemapCache.protectedAvailable(
                    budget: OfflineStorageBudget.basemapBudgetBytes, reserve: OfflineStorageBudget.freeSpaceReserveBytes)
            },
            keepAwake: { UIApplication.shared.isIdleTimerDisabled = $0 })
    }
}
#endif
