#!/bin/bash
# Regression harness for the terrain viewer.
#
# The Core, Domain and Services layers carry no UIKit dependency, so they
# compile and run for the host. That makes this suite usable from a plain
# shell in a couple of seconds, with no test target and no pbxproj change.
#
# Usage: Tools/run-harness.sh [output-dir-for-rendered-PNGs]
set -uo pipefail
if [ -z "${DEVELOPER_DIR:-}" ]; then
  if [ -d "/Applications/Xcode-beta.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
  elif [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  else
    export DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || echo '')"
  fi
fi
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
RENDER_DIR="${1:-$OUT}"
mkdir -p "$RENDER_DIR"

# Compile Metal shaders so RasterCompute can test the GPU path.
xcrun metal -c LidarExplorer/Core/Raster/Shaders/TerrainKernels.metal -o "$OUT/TerrainKernels.air" || exit 1
xcrun metallib "$OUT/TerrainKernels.air" -o "$OUT/default.metallib" || exit 1

xcrun swiftc -O \
  -swift-version 6 -strict-concurrency=complete -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -o "$OUT/harness" \
  LidarExplorer/Core/Diagnostics/Log.swift \
  LidarExplorer/Core/Geometry/GeoRegion.swift \
  LidarExplorer/Core/Geometry/ElevationGrid.swift \
  LidarExplorer/Core/Geometry/UTMProjection.swift \
  LidarExplorer/Core/Raster/TerrainDerivatives.swift \
  LidarExplorer/Core/Raster/RasterCompute.swift \
  LidarExplorer/Core/Raster/ReliefRenderer.swift \
  LidarExplorer/Core/Raster/ReliefStyleGuide.swift \
  LidarExplorer/Core/Raster/GeoTIFFWriter.swift \
  LidarExplorer/Core/Raster/MicroTopographyReference.swift \
  LidarExplorer/Core/Raster/MetalTerrainPipelineActor.swift \
  LidarExplorer/Domain/Evidence.swift \
  LidarExplorer/Domain/ElevationUnit.swift \
  LidarExplorer/Domain/ElevationProfile.swift \
  LidarExplorer/Domain/ElevationTransect.swift \
  LidarExplorer/Domain/TransectExporter.swift \
  LidarExplorer/Domain/FieldMarkup.swift \
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
  LidarExplorer/Presentation/TileActivityLog.swift \
  LidarExplorer/Presentation/LocationProviding.swift \
  LidarExplorer/Presentation/LocationService.swift \
  LidarExplorer/MapLayer/AnalysisRasterBuilder.swift \
  LidarExplorer/MapLayer/MercatorMosaicBuilder.swift \
  LidarExplorer/MapLayer/StrokeGeoreferencer.swift \
  LidarExplorer/MapLayer/ThalwegBuilder.swift \
  LidarExplorer/MapLayer/HistoricalMap.swift \
  LidarExplorer/MapLayer/HistoricalMapOverlay.swift \
  LidarExplorer/MapLayer/SoilHatchOverlay.swift \
  LidarExplorer/MapLayer/HillshadeTileOverlay.swift \
  LidarExplorer/MapLayer/TerrainHarvestSource.swift \
  LidarExplorer/MapLayer/TerrainTileOverlay.swift \
  LidarExplorer/Presentation/ElevationRangePolicy.swift \
  LidarExplorer/Presentation/TerrainViewerModel.swift \
  Tools/ViewerHarness/MicroTopographyChecks.swift \
  Tools/ViewerHarness/CoordinatorChecks.swift \
  Tools/ViewerHarness/TransectChecks.swift \
  Tools/ViewerHarness/InteractiveAnalysisChecks.swift \
  Tools/ViewerHarness/ProviderMicroChecks.swift \
  Tools/ViewerHarness/HistoricalAndSoilChecks.swift \
  Tools/ViewerHarness/BasemapChecks.swift \
  Tools/ViewerHarness/ExportChecks.swift \
  Tools/ViewerHarness/HarvesterChecks.swift \
  Tools/ViewerHarness/LayerBlendChecks.swift \
  Tools/ViewerHarness/LocalGeoTIFFChecks.swift \
  Tools/ViewerHarness/MarkupChecks.swift \
  Tools/ViewerHarness/main.swift || exit 1

"$OUT/harness" "$RENDER_DIR"
