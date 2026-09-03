#!/bin/bash
# End-to-end check against the live USGS 3DEP service.
#
# Drives TerrainViewerModel exactly as the "Load terrain here" button does:
# fetch -> tiled TIFF decode -> derivatives -> render -> inspect -> clear.
# Requires network. For the offline suite use Tools/run-harness.sh.
#
# Usage: Tools/run-live-check.sh
set -uo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

xcrun swiftc -O \
  -swift-version 6 -strict-concurrency=complete -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -o "$OUT/livecheck" \
  LidarExplorer/Core/Diagnostics/Log.swift \
  LidarExplorer/Core/Geometry/GeoRegion.swift \
  LidarExplorer/Core/Geometry/ElevationGrid.swift \
  LidarExplorer/Core/Raster/TerrainDerivatives.swift \
  LidarExplorer/Core/Raster/RasterCompute.swift \
  LidarExplorer/Core/Raster/ReliefRenderer.swift \
  LidarExplorer/Domain/Evidence.swift \
  LidarExplorer/Services/Decoding/FloatTIFFDecoder.swift \
  LidarExplorer/Services/Transport/HTTPTransport.swift \
  LidarExplorer/Services/Elevation/ElevationService.swift \
  LidarExplorer/Services/Elevation/TerrariumTileService.swift \
  LidarExplorer/MapLayer/HillshadeTileOverlay.swift \
  LidarExplorer/MapLayer/TerrainTileOverlay.swift \
  Tools/LiveCheck/main.swift || exit 1

"$OUT/livecheck"
