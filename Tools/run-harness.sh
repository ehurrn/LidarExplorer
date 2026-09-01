#!/bin/bash
# Runs the detection/geometry regression harness natively on macOS.
#
# The Core, Domain and Analysis layers carry no UIKit dependency, so they
# compile and run for the host without a simulator. That makes this suite
# usable from a plain shell in about two seconds, with no test target and no
# pbxproj surgery.
#
# Usage: Tools/run-harness.sh
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

xcrun swiftc -O \
  -swift-version 6 -strict-concurrency=complete -default-isolation MainActor \
  -o "$OUT/harness" \
  LidarExplorer/Core/Diagnostics/Log.swift \
  LidarExplorer/Core/Geometry/GeoRegion.swift \
  LidarExplorer/Core/Geometry/ElevationGrid.swift \
  LidarExplorer/Core/Raster/TerrainDerivatives.swift \
  LidarExplorer/Domain/Observation.swift \
  LidarExplorer/Domain/Corroboration.swift \
  LidarExplorer/Domain/DetectedFeature.swift \
  LidarExplorer/Analysis/Detection/DetectionSupport.swift \
  LidarExplorer/Analysis/Detection/MoundDetector.swift \
  LidarExplorer/Services/Decoding/FloatTIFFDecoder.swift \
  Tools/DetectionHarness/main.swift

"$OUT/harness"
