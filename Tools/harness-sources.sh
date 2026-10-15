#!/bin/bash
# The app sources the host-compiled tools build, and the flags they build with: sourced by Tools/run-harness.sh
# and Tools/run-live-check.sh, so the two cannot drift apart (the live check once named a list of its own, which
# stopped compiling as files were added). Keep UIKit out of any file here, or behind #if canImport(UIKit).
#
# Sets SWIFT_FLAGS, METAL_SOURCE and APP_SOURCES; a script appends its own main and check files to APP_SOURCES.
# Paths are relative to the repository root, which the sourcing script has made its working directory.

SWIFT_FLAGS=(
  -O
  -swift-version 6 -strict-concurrency=complete -default-isolation MainActor
  -enable-upcoming-feature MemberImportVisibility
  # The two the app target's SWIFT_APPROACHABLE_CONCURRENCY = YES turns on, so the harness has the app's concurrency
  # features. Not its Debug build's DEBUG condition or -Onone: #if DEBUG code is type-checked only by xcodebuild.
  -enable-upcoming-feature InferIsolatedConformances
  -enable-upcoming-feature NonisolatedNonsendingByDefault
)
# Compiled to a metallib beside the binary, so RasterCompute can test the GPU path.
METAL_SOURCE=LidarExplorer/Core/Raster/Shaders/TerrainKernels.metal
APP_SOURCES=(
  LidarExplorer/Core/Diagnostics/Log.swift \
  LidarExplorer/Core/Geometry/GeoRegion.swift \
  LidarExplorer/Core/Geometry/ElevationGrid.swift \
  LidarExplorer/Core/Geometry/UTMProjection.swift \
  LidarExplorer/Core/Geometry/TerrainMeshBuilder.swift \
  LidarExplorer/Core/Raster/TerrainDerivatives.swift \
  LidarExplorer/Core/Raster/RasterCompute.swift \
  LidarExplorer/Core/Raster/ReliefRenderer.swift \
  LidarExplorer/Core/Raster/ReliefStyleGuide.swift \
  LidarExplorer/Core/Raster/GeoTIFFWriter.swift \
  LidarExplorer/Core/Raster/MicroTopographyReference.swift \
  LidarExplorer/Core/Raster/LayerBlend.swift \
  LidarExplorer/Core/Raster/MetalTerrainPipelineActor.swift \
  LidarExplorer/Domain/Evidence.swift \
  LidarExplorer/Domain/ElevationUnit.swift \
  LidarExplorer/Domain/ElevationProfile.swift \
  LidarExplorer/Domain/ElevationTransect.swift \
  LidarExplorer/Domain/TransectExporter.swift \
  LidarExplorer/Domain/FieldMarkup.swift \
  LidarExplorer/Domain/FieldNotebook.swift \
  LidarExplorer/Domain/ProfileDecimation.swift \
  LidarExplorer/Domain/SoilSurvey.swift \
  LidarExplorer/Domain/Landmark.swift \
  LidarExplorer/Domain/SpotInspection.swift \
  LidarExplorer/Services/Decoding/FloatTIFFDecoder.swift \
  LidarExplorer/Services/Decoding/TIFFLZWDecoder.swift \
  LidarExplorer/Services/Transport/HTTPTransport.swift \
  LidarExplorer/Services/Elevation/ElevationService.swift \
  LidarExplorer/Services/Elevation/COGByteReader.swift \
  LidarExplorer/Services/Elevation/ElevationTileCoordinator.swift \
  LidarExplorer/Services/Elevation/TerrariumTileService.swift \
  LidarExplorer/Services/Elevation/OfflineHarvestCoordinator.swift \
  LidarExplorer/Services/Elevation/LocalGeoTIFFProvider.swift \
  LidarExplorer/Services/Soils/SoilDataAccessClient.swift \
  LidarExplorer/Services/Storage/TileDiskCache.swift \
  LidarExplorer/Services/Storage/ElevationGridCoder.swift \
  LidarExplorer/Services/Storage/OfflineStorageBudget.swift \
  LidarExplorer/Services/Storage/FieldNotebookStore.swift \
  LidarExplorer/Services/Export/GeoreferencedExportMetadata.swift \
  LidarExplorer/Presentation/TileActivityLog.swift \
  LidarExplorer/Presentation/OfflineHarvestController.swift \
  LidarExplorer/Presentation/Terrain3DScene.swift \
  LidarExplorer/Presentation/HapticDetents.swift \
  LidarExplorer/Presentation/HapticRouting.swift \
  LidarExplorer/Presentation/MapTouchPolicy.swift \
  LidarExplorer/Presentation/PencilRollAzimuth.swift \
  LidarExplorer/Presentation/DialGeometry.swift \
  LidarExplorer/Presentation/TopBarLayout.swift \
  LidarExplorer/Presentation/LocationProviding.swift \
  LidarExplorer/Presentation/LocationService.swift \
  LidarExplorer/MapLayer/AnalysisRasterBuilder.swift \
  LidarExplorer/MapLayer/MercatorMosaicBuilder.swift \
  LidarExplorer/MapLayer/StrokeGeoreferencer.swift \
  LidarExplorer/MapLayer/TileComposite.swift \
  LidarExplorer/MapLayer/ThalwegBuilder.swift \
  LidarExplorer/MapLayer/HistoricalMap.swift \
  LidarExplorer/MapLayer/HistoricalMapOverlay.swift \
  LidarExplorer/MapLayer/SoilHatchOverlay.swift \
  LidarExplorer/MapLayer/HillshadeTileOverlay.swift \
  LidarExplorer/MapLayer/TerrainHarvestSource.swift \
  LidarExplorer/MapLayer/TerrainTileOverlay.swift \
  LidarExplorer/Presentation/ElevationRangePolicy.swift \
  LidarExplorer/Presentation/TerrainViewerModel.swift \
)
