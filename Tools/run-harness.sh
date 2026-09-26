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

# Brings $PRODUCTS/bin/harness and $PRODUCTS/metal/default.metallib up to date.
build() {
  local swift_dir="$PRODUCTS/swift" metal_dir="$PRODUCTS/metal" bin_dir="$PRODUCTS/bin"
  local started=$SECONDS mode=incremental key
  # What the kept products were built with. Any change means starting over, rather than trusting the
  # compiler to notice that a flag, a source's removal or a toolchain update invalidates them.
  key=$({ xcrun --find swiftc; xcrun swiftc --version; xcrun --find metal
          printf '%s\n' "${SWIFT_FLAGS[@]}" -- "${SOURCES[@]}"; } 2>&1 | shasum -a 256)
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
  local map="$swift_dir/output-file-map.json" src stem
  {
    printf '{\n  "": {"swift-dependencies": "%s/harness.swiftdeps"}' "$swift_dir"
    for src in "${SOURCES[@]}"; do
      stem="$swift_dir/$(printf '%s' "${src%.swift}" | tr / _)"
      printf ',\n  "%s": {"object": "%s.o", "swift-dependencies": "%s.swiftdeps"}' "$src" "$stem" "$stem"
    done
    printf '\n}\n'
  } > "$map.next" || return 1
  if cmp -s "$map.next" "$map"; then rm -f "$map.next"; else mv "$map.next" "$map" || return 1; fi

  xcrun swiftc "${SWIFT_FLAGS[@]}" \
    -incremental -enable-batch-mode -enable-incremental-file-hashing -j "$(sysctl -n hw.activecpu)" \
    -output-file-map "$map" \
    -o "$bin_dir/harness" \
    "${SOURCES[@]}" || return 1
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
for product in bin/harness metal/default.metallib; do
  cp -c "$PRODUCTS/$product" "$OUT/" 2>/dev/null || cp "$PRODUCTS/$product" "$OUT/" || exit 1
done
exec 9>&-

"$OUT/harness" "$RENDER_DIR"
