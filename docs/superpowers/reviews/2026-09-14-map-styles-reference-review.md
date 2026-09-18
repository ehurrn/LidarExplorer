# Map Styles Reference — Adversarial Design Review

_2026-09-14 · devils-advocate skill (project copy in `.claude/skills/`) · target: `docs/superpowers/specs/2026-09-14-map-styles-reference-design.md` (as of `6b0b4e2`)_

### Summary

The design adds a searchable Map Styles reference that opens as a trailing
`.inspector` beside the map on iPad and as a sheet on compact widths, reusing
the harness-checked `ReliefStyleGuide` content. It touches only Presentation
state plus a Core search helper; no tile, Metal, Morton or GeoTIFF code
changes. The risk is concentrated where the panel meets the existing screen:
SwiftUI sheet presentation on compact widths, top-bar layout once the map
column narrows, and the tile work a style switch triggers.

### Verdict

**NOT APPROVED — 0 Blockers, 2 Majors, 3 Minors, 3 Nits.** Nothing here
corrupts data or leaks unboundedly, but the two Majors ship visibly broken UI
on common configurations; fix them in the spec before implementation.

#### Major

- **Finding**: "Replay Intro" (and any top-bar sheet) silently does nothing on compact width.
- **Evidence / Location**: `.inspector` presents as a sheet in compact
  horizontal size classes (iPhone, iPad Split View / Slide Over). The intro is
  `.sheet(isPresented: $showsPrimer)` on the same view in `TerrainViewerView.swift:161`,
  alongside four more root sheets (`:166`, `:176`, `:179`, `:182`). SwiftUI
  presents one sheet per presenter; a second presentation request while the
  inspector's sheet is up is dropped with a console warning.
- **Failure Scenario & Impact**: On an iPhone, open **?** → tap **Replay Intro**:
  nothing happens. If background interaction were enabled so the map stays
  usable under a medium-height sheet, the top bar's Settings, Landmarks and
  Export buttons fail the same way.
- **Actionable Counter-Proposal**: Present the intro from inside the reference
  view's own hierarchy (a `.sheet` attached within `MapStylesReferenceView`),
  which stacks correctly in both the inspector column and the compact sheet.
  Keep compact-width background interaction at the system default (disabled),
  so no root sheet can be requested while the panel's sheet is up.

- **Finding**: The top bar overflows on iPad Pro 11" in portrait with the panel open.
- **Evidence / Location**: `ViewerTopBarView.swift` lays out 7 × 36 pt buttons
  with 8 pt spacing (300 pt), 10 pt between groups, 32 pt of side padding, and
  the elevation capsule ("Tap map for elevation": ~200 pt), about 545 pt in all.
  An 11" iPad is 834 pt wide in portrait; a ~320 pt inspector column leaves
  ~514 pt. Nothing in the bar sets `lineLimit`, layout priority or `ViewThatFits`.
- **Failure Scenario & Impact**: Opening the panel in portrait squeezes the
  readout into wrapping or clips the trailing buttons (Settings). Longer
  readouts ("Observer placed (drag pin to move)") make it worse.
- **Actionable Counter-Proposal**: Pin the column width
  (`.inspectorColumnWidth(min: 300, ideal: 340, max: 420)`), give the action
  buttons higher layout priority, make the readout `lineLimit(1)` with tail
  truncation, and verify on the iPad Pro 11" Simulator in portrait with the
  longest readout.

#### Minor

- **Finding**: Toggling the panel can re-render every visible tile in the Elevation and REM styles.
- **Evidence / Location**: Resizing fires `regionDidChangeAnimated`
  (`TerrainMapView.swift:704`), which sets `visibleRegion` and, 400 ms later,
  calls `refreshElevationRange()`. A changed extent goes through
  `pushSettings()`, then `terrainVersion`, then `renderer.reloadData()`, which
  invalidates the tile store and re-shades the viewport.
  `ElevationRangePolicy` damps small extent changes, but a narrower visible
  area can legitimately change the extent.
- **Failure Scenario & Impact**: Each open/close costs a full viewport
  re-shade (GPU and CPU, no network).
- **Actionable Counter-Proposal**: Add a verification step. In Elevation
  style, one open/close cycle may cause at most one terrain reload
  (`TileActivityLog`). If it causes more, exclude the inspector-driven resize
  from the range refresh.

- **Finding**: A style switch strands in-flight renders (pre-existing; not amplified by this design).
- **Evidence / Location**: `TileImageStore.invalidate()` (`TerrainTileOverlay.swift:1601`)
  only bumps the generation and drops results. The provider tasks started in
  `TerrainTileOverlayRenderer.request` are unstructured and never cancelled,
  so superseded micro-pipeline stitches and GPU passes run to completion.
- **Failure Scenario & Impact**: Switching styles quickly queues discarded
  work ahead of the tiles now on screen. The panel needs at least two taps per
  switch against one on the dock chips, so it does not raise the rate.
- **Actionable Counter-Proposal**: Out of scope for this design. Follow up by
  keeping the request `Task` handles in the renderer and cancelling them in
  `reloadData()`; the provider already checks `Task.isCancelled`.

- **Finding**: UI behaviour has no automated coverage.
- **Evidence / Location**: The harness compiles Core/Domain/Services only; the
  panel, toggle and Use-This-Style flow live in Presentation.
- **Failure Scenario & Impact**: Regressions (the **?** button no longer
  toggling, "In Use" not updating) are caught only by manual runs.
- **Actionable Counter-Proposal**: Keep all decidable logic in Core with checks
  (search, section membership, whether a style is in use), and spell out a
  screenshot checklist in the plan.

#### Nit

- **Finding**: Searching the *Adjust with* text returns noise.
- **Evidence / Location**: Nearly every control string contains "Settings" or "slider".
- **Failure Scenario & Impact**: "settings" matches most styles.
- **Actionable Counter-Proposal**: Search the name, chip label, *shows*, *reading* and *best for* only.

- **Finding**: Panel navigation state is unspecified.
- **Evidence / Location**: The spec does not say what reopening shows.
- **Failure Scenario & Impact**: Implementations may diverge (stale detail pages versus lost place).
- **Actionable Counter-Proposal**: Reopening shows the list, scrolled to the style in use.

- **Finding**: Guide text is not localizable, and the in-use marker has no accessibility value.
- **Evidence / Location**: Plain `String` literals in `ReliefStyleGuide.swift`
  (the app is `en`-only today); the spec's marker is visual only.
- **Failure Scenario & Impact**: VoiceOver users cannot tell which style is
  active; localizing later needs a refactor.
- **Actionable Counter-Proposal**: Give the marker `accessibilityValue("In use")`.
  Leave localization out of scope.

### Stress-Test Matrix

1. **Network storms**: pass. Closing the panel exposes one strip of tiles.
   Requests go through the renderer's per-key in-flight claim and the
   provider's in-flight dedupe, and `HTTPTransport` retries at most three
   times with jitter.
2. **Morton / GeoTIFF parsing**: not applicable; untouched.
3. **Races**: pass. `TerrainViewerModel` is `@MainActor @Observable`, the guide
   content is `Sendable` static data, and no new actor or buffer code is added.
4. **Zombie resources**: pre-existing stranded renders on style switch (Minor above).
5. **Silent degradation**: compact-width sheet drop (Major above); search with
   no results needs an explicit empty state (already in the spec).

### Next Steps

1. Revise the spec for both Majors and the Nits (done in the same change as this report).
2. Build to the revised spec; verify on the iPad Pro 11" portrait, iPad Pro 13" and iPhone 17 Pro Simulators.
3. Track the stranded-render cancellation as its own task.
