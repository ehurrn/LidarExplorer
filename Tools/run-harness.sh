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
  LidarExplorer/Core/Raster/TerrainDerivatives.swift \
  LidarExplorer/Core/Raster/RasterCompute.swift \
  LidarExplorer/Core/Raster/ReliefRenderer.swift \
  LidarExplorer/Domain/Evidence.swift \
  LidarExplorer/Domain/ElevationUnit.swift \
  LidarExplorer/Domain/ElevationProfile.swift \
  LidarExplorer/Domain/Landmark.swift \
  LidarExplorer/Services/Decoding/FloatTIFFDecoder.swift \
  LidarExplorer/Services/Transport/HTTPTransport.swift \
  LidarExplorer/Services/Elevation/ElevationService.swift \
  LidarExplorer/Services/Elevation/TerrariumTileService.swift \
  LidarExplorer/Presentation/TileActivityLog.swift \
  LidarExplorer/Presentation/LocationProviding.swift \
  LidarExplorer/Presentation/LocationService.swift \
  LidarExplorer/MapLayer/HillshadeTileOverlay.swift \
  LidarExplorer/MapLayer/TerrainTileOverlay.swift \
  LidarExplorer/Presentation/TerrainViewerModel.swift \
  Tools/ViewerHarness/main.swift || exit 1

"$OUT/harness" "$RENDER_DIR"
