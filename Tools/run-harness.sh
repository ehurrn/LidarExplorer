#!/bin/bash
# Regression harness for the terrain viewer.
#
# The Core, Domain and Services layers carry no UIKit dependency, so they
# compile and run for the host. That makes this suite usable from a plain
# shell in a couple of seconds, with no test target and no pbxproj change.
#
# Usage: Tools/run-harness.sh [output-dir-for-rendered-PNGs]
#
# The build is kept between runs in .harness-build/ (gitignored) and is
# incremental: only the sources that changed, and those that depend on what
# changed, are recompiled, so a run with nothing changed goes almost straight
# to the checks. It is still an optimized (-O) build, since the render and GPU
# budget checks assume one; it is compiled file by file rather than as one
# whole module, which is what lets it be incremental.
#
#   HARNESS_CLEAN=1        discard the kept build and compile from scratch
#   HARNESS_BUILD_DIR=dir  keep the build in dir instead of .harness-build/
#
# The kept build is discarded on its own when the compiler, the flags or the
# list of sources below change. Runs that share a build directory take turns
# building in it, and each then runs from its own copy of what was built.
#
# Runs can go side by side, in two worktrees or two in one: each gets a
# directory of its own under .harness-build/runs.noindex/, removed when it
# ends, and runs inside it with its own home (CFFIXED_USER_HOME: Caches,
# Application Support, Documents), temporary files (HARNESS_TMPDIR), working
# directory, and UserDefaults domain (the binary's name, unique per run). A
# relative render directory is taken from the repository root, as before.
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
ROOT=$(pwd -P)

SWIFT_FLAGS=(
  -O
  -swift-version 6 -strict-concurrency=complete -default-isolation MainActor
  -enable-upcoming-feature MemberImportVisibility
)
# Compiled to a metallib beside the binary, so RasterCompute can test the GPU path.
METAL_SOURCE=LidarExplorer/Core/Raster/Shaders/TerrainKernels.metal
SOURCES=(
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
  LidarExplorer/Presentation/TileActivityLog.swift \
  LidarExplorer/Presentation/OfflineHarvestController.swift \
  LidarExplorer/Presentation/Terrain3DScene.swift \
  LidarExplorer/Presentation/HapticDetents.swift \
  LidarExplorer/Presentation/PencilRollAzimuth.swift \
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
  Tools/ViewerHarness/HarnessRun.swift \
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
  Tools/ViewerHarness/TileBlendChecks.swift \
  Tools/ViewerHarness/LocalGeoTIFFChecks.swift \
  Tools/ViewerHarness/MarkupChecks.swift \
  Tools/ViewerHarness/PersistenceChecks.swift \
  Tools/ViewerHarness/HarvestControllerChecks.swift \
  Tools/ViewerHarness/OfflineStoreChecks.swift \
  Tools/ViewerHarness/HarvestFailureChecks.swift \
  Tools/ViewerHarness/TerrainMeshChecks.swift \
  Tools/ViewerHarness/Terrain3DChecks.swift \
  Tools/ViewerHarness/HapticChecks.swift \
  Tools/ViewerHarness/PencilRollChecks.swift \
  Tools/ViewerHarness/main.swift \
)

BUILD_DIR="${HARNESS_BUILD_DIR:-.harness-build}"
mkdir -p "$BUILD_DIR" && BUILD_DIR=$(cd "$BUILD_DIR" && pwd -P) || exit 1

# The products, and what they are built from. Spotlight skips a directory named *.noindex, as it does
# Xcode's Intermediates.noindex, so it does not index every object the build rewrites.
PRODUCTS="$BUILD_DIR/products.noindex"
# One directory per run, named for the pid of the script that owns it.
RUNS="$BUILD_DIR/runs.noindex"
mkdir -p "$RUNS" || exit 1

# A run's binary is named for its directory, and a tool with no bundle keeps its UserDefaults under its
# executable's name: this is the run's defaults domain, which lives with cfprefsd, not in the directory.
run_name() { printf 'LidarExplorerHarness.%s' "${1##*/}"; }
forget_run() {
  local name
  name=$(run_name "$1")
  rm -rf "$1"
  defaults delete "$name" >/dev/null 2>&1
  [ -n "${HOME:-}" ] && rm -f "$HOME/Library/Preferences/$name.plist"
}
# What runs that died without cleaning up (kill -9, a power cut) left behind.
for stale in "$RUNS"/*; do
  [ -d "$stale" ] || continue
  owner=${stale##*/}
  kill -0 "${owner%%.*}" 2>/dev/null || forget_run "$stale"
done

RUN_DIR=$(mktemp -d "$RUNS/$$.XXXXXX") || exit 1
RUN_NAME=$(run_name "$RUN_DIR")
trap 'forget_run "$RUN_DIR"' EXIT
mkdir -p "$RUN_DIR/home" "$RUN_DIR/tmp" || exit 1
RENDER_DIR="${1:-$RUN_DIR/render}"
mkdir -p "$RENDER_DIR" && RENDER_DIR=$(cd "$RENDER_DIR" && pwd -P) || exit 1

# Brings $PRODUCTS/bin/harness and $PRODUCTS/metal/default.metallib up to date.
build() {
  local swift_dir="$PRODUCTS/swift" metal_dir="$PRODUCTS/metal" bin_dir="$PRODUCTS/bin"
  local started=$SECONDS mode=incremental key src sources=()
  # Absolute, so that #filePath (how checks find Tools/Fixtures) holds wherever the harness runs.
  for src in "${SOURCES[@]}"; do sources+=("$ROOT/$src"); done
  # What the kept products were built with. Any change means starting over, rather than trusting the
  # compiler to notice that a flag, a source's removal or a toolchain update invalidates them.
  key=$({ xcrun --find swiftc; xcrun swiftc --version; xcrun --find metal
          printf '%s\n' "${SWIFT_FLAGS[@]}" -- "${sources[@]}"; } 2>&1 | shasum -a 256)
  if [ "${HARNESS_CLEAN:-0}" = 1 ] || [ "$key" != "$(cat "$BUILD_DIR/build-key" 2>/dev/null)" ]; then
    mode="from clean"
    rm -rf "$swift_dir" "$metal_dir" "$bin_dir"
    printf '%s\n' "$key" > "$BUILD_DIR/build-key"
  fi
  mkdir -p "$swift_dir" "$metal_dir" "$bin_dir" || return 1

  local metal_sum
  metal_sum=$(shasum -a 256 < "$METAL_SOURCE") || return 1
  if [ ! -f "$metal_dir/default.metallib" ] || [ "$metal_sum" != "$(cat "$metal_dir/source.sha256" 2>/dev/null)" ]; then
    xcrun metal -c "$METAL_SOURCE" -o "$metal_dir/TerrainKernels.air" || return 1
    xcrun metallib "$metal_dir/TerrainKernels.air" -o "$metal_dir/next.metallib" || return 1
    mv "$metal_dir/next.metallib" "$metal_dir/default.metallib" || return 1
    printf '%s\n' "$metal_sum" > "$metal_dir/source.sha256"
  fi

  # Where each source's object and dependency record go: what lets the driver compile only what changed.
  local map="$swift_dir/output-file-map.json" stem
  {
    printf '{\n  "": {"swift-dependencies": "%s/harness.swiftdeps"}' "$swift_dir"
    for src in "${SOURCES[@]}"; do
      stem="$swift_dir/$(printf '%s' "${src%.swift}" | tr / _)"
      printf ',\n  "%s": {"object": "%s.o", "swift-dependencies": "%s.swiftdeps"}' "$ROOT/$src" "$stem" "$stem"
    done
    printf '\n}\n'
  } > "$map.next" || return 1
  if cmp -s "$map.next" "$map"; then rm -f "$map.next"; else mv "$map.next" "$map" || return 1; fi

  xcrun swiftc "${SWIFT_FLAGS[@]}" \
    -incremental -enable-batch-mode -enable-incremental-file-hashing -j "$(sysctl -n hw.activecpu)" \
    -output-file-map "$map" \
    -o "$bin_dir/harness" \
    "${sources[@]}" || return 1
  echo "harness: build $mode, $((SECONDS - started)) s (HARNESS_CLEAN=1 rebuilds from scratch)"
}

# One build at a time in a build directory: a second run waits here, then finds the products current.
# The lock is the kernel's, so a run that dies releases it.
exec 9>>"$BUILD_DIR/build.lock"
if ! lockf -s -t 0 9; then
  echo "harness: waiting for another run's build in $BUILD_DIR"
  lockf -s 9 || exit 1
fi
build || exit 1
# This run's own copies, so a later build cannot change the binary while it runs.
install_product() { cp -c "$PRODUCTS/$1" "$2" 2>/dev/null || cp "$PRODUCTS/$1" "$2"; }
install_product bin/harness "$RUN_DIR/$RUN_NAME" || exit 1
install_product metal/default.metallib "$RUN_DIR/default.metallib" || exit 1
exec 9>&-

cd "$RUN_DIR" || exit 1
CFFIXED_USER_HOME="$RUN_DIR/home" HARNESS_TMPDIR="$RUN_DIR/tmp" TMPDIR="$RUN_DIR/tmp/" \
  "./$RUN_NAME" "$RENDER_DIR"
