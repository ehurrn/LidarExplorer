#!/bin/bash
# End-to-end check against the live USGS 3DEP service.
#
# Drives TerrainViewerModel exactly as the "Load terrain here" button does:
# fetch -> tiled TIFF decode -> derivatives -> render -> inspect -> clear.
# Requires network. For the offline suite use Tools/run-harness.sh.
#
# Usage: Tools/run-live-check.sh
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

# Compile Metal shaders so RasterCompute can test the GPU path.
xcrun metal -c LidarExplorer/Core/Raster/Shaders/TerrainKernels.metal -o "$OUT/TerrainKernels.air" || exit 1
xcrun metallib "$OUT/TerrainKernels.air" -o "$OUT/default.metallib" || exit 1

xcrun swiftc -O \
  -swift-version 6 -strict-concurrency=complete -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -o "$OUT/livecheck" \
  LidarExplorer/Core/Diagnostics/Log.swift \
  LidarExplorer/Core/Geometry/GeoRegion.swift \
  LidarExplorer/Core/Geometry/ElevationGrid.swift \
  LidarExplorer/Core/Geometry/UTMProjection.swift \
  LidarExplorer/Core/Raster/TerrainDerivatives.swift \
  LidarExplorer/Core/Raster/RasterCompute.swift \
  LidarExplorer/Core/Raster/ReliefRenderer.swift \
  LidarExplorer/Domain/Evidence.swift \
  LidarExplorer/Domain/ElevationUnit.swift \
  LidarExplorer/Domain/ElevationProfile.swift \
  LidarExplorer/Domain/SpotInspection.swift \
  LidarExplorer/Services/Decoding/FloatTIFFDecoder.swift \
  LidarExplorer/Services/Decoding/TIFFLZWDecoder.swift \
  LidarExplorer/Services/Transport/HTTPTransport.swift \
  LidarExplorer/Services/Elevation/ElevationService.swift \
  LidarExplorer/Services/Elevation/COGByteReader.swift \
  LidarExplorer/Services/Elevation/TerrariumTileService.swift \
  LidarExplorer/Services/Storage/TileDiskCache.swift \
  LidarExplorer/Services/Storage/ElevationGridCoder.swift \
  LidarExplorer/Presentation/TileActivityLog.swift \
  LidarExplorer/MapLayer/HillshadeTileOverlay.swift \
  LidarExplorer/MapLayer/TerrainTileOverlay.swift \
  Tools/LiveCheck/main.swift || exit 1

"$OUT/livecheck"
