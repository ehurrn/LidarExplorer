#!/bin/bash
# End-to-end check against the live USGS 3DEP service and the other services the viewer reads (the ImageServer,
# the COGs, Terrarium, Soil Data Access): fetch -> decode -> derivatives -> render -> inspect -> clear.
# Requires network. For the offline suite use Tools/run-harness.sh.
#
# Usage: Tools/run-live-check.sh
#   LIVE_CHECK_BUILD_ONLY=1   compiles the check and stops, for a build without the network.
#
# Builds with the harness's flags and app sources (Tools/harness-sources.sh), in build-review/live-check inside
# the repository, as every build and log of this project is.
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
cd "$(dirname "$0")/.." || exit 1
. Tools/harness-sources.sh

OUT=build-review/live-check
rm -rf "$OUT"
mkdir -p "$OUT" || exit 1

# Compile Metal shaders so RasterCompute can test the GPU path.
xcrun metal -c "$METAL_SOURCE" -o "$OUT/TerrainKernels.air" || exit 1
xcrun metallib "$OUT/TerrainKernels.air" -o "$OUT/default.metallib" || exit 1

xcrun swiftc "${SWIFT_FLAGS[@]}" \
  -o "$OUT/livecheck" \
  "${APP_SOURCES[@]}" \
  Tools/LiveCheck/main.swift || exit 1

if [ "${LIVE_CHECK_BUILD_ONLY:-0}" = 1 ]; then
  echo "live check: built $OUT/livecheck (LIVE_CHECK_BUILD_ONLY=1, not run)"
  exit 0
fi

# Its caches (URLCache, the tile cache) go to this run's own home, never the working directory.
RUN_HOME="$OUT/home"
mkdir -p "$RUN_HOME" || exit 1
CFFIXED_USER_HOME="$RUN_HOME" "$OUT/livecheck"
