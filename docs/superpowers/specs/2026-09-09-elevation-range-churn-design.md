# Elevation range-churn suppression

**Date:** 2026-09-09
**Status:** Approved (design), pending implementation
**Area:** `TerrainViewerModel`, `ReliefRenderer` (elevation style), disk PNG cache

## Problem

In the `.elevation` style the hypsometric tint is fitted to the visible area's
elevation extent — a *shared* range so every on-screen tile tints continuously
with no seams. `TerrainViewerModel.refreshElevationRange` recomputes that range
from the visible tiles as the user pans, snapping each bound to a fixed **10 m**
grid (`floor` the low, `ceil` the high) and adopting the result whenever it
differs from the current range at all (`!=`).

Two costs compound as the user pans over varied terrain:

1. **Fragmented disk cache.** The rendered-PNG disk key embeds the range as
   `..._elevation_<lo>_<hi>`. Each distinct 10 m range is a distinct key, so the
   same tile is written under a stream of keys. Measured over a 14-step pan of
   12 tiles, elevation mode produced 51 distinct keys for 30 tiles and a second
   pass hit only ~47% of them, where hillshade (a stable key) hit 100%.

2. **Live re-render bursts.** Any change to the shared range calls
   `pushSettings()` → `TerrainTileProvider.update(_:)`, which clears
   `renderedPNG` on **every** in-memory tile and re-renders them all against the
   new range. A 10 m wobble in the visible extent therefore triggers a
   full-screen re-render. Measured at the committed reference tile size
   (264² = 256 + 2×4 margin), one elevation PNG render is ~1.6 ms, so a ~30-tile
   screen is a ~47 ms hitch, live, serialized on the provider actor.

The network fetch these figures sit on top of (10–18 s for a novel 3DEP tile) is
already eliminated by the existing grid cache; the re-render churn is what
remains, and it is specific to `.elevation`.

### Why not the obvious fixes

- **Coarsen the disk key** while still rendering at the true range → serves a
  cached image under a key that claims a different range: stale pixels. Rejected
  (this was the original task's own caution).
- **Cache `ReliefProducts`** so a grid hit skips the GPU recompute → measured
  ~0.4 ms/tile saved for **3×** the grid cache's disk footprint (816 KB vs
  272 KB per tile). The recompute is a minority of a re-render (~1.6 ms) that is
  itself ~10,000× cheaper than the fetch the grid cache already avoids. Rejected
  as YAGNI; recorded here so it is not re-investigated.

### The realization

The shared range is a **view-adaptive aesthetic**, not a correctness
requirement — it exists to fit the tint to what is on screen, and clamping a
little terrain at the palette extremes is acceptable. So making the range
change *less often* is a legitimate lever, and it attacks **both** costs at
once. Crucially, unlike coarsening the key, the rendered range and the key range
stay identical — we only choose stabler ranges.

## Approach A: range-churn suppression (chosen, "balanced")

Adopt a new shared range only when it has drifted **materially** from the
current one (hysteresis), and snap adopted ranges to a step **proportional to
span** (relative quantization) so nearby views reuse the same key.

## Components

### 1. `ElevationRangePolicy` — new pure, isolated unit

New file `LidarExplorer/Presentation/ElevationRangePolicy.swift`, a
`nonisolated enum`. No I/O, no actor state, one decision function — so it is
tested directly in the harness.

```swift
enum ElevationRangePolicy {
    static let hysteresisFraction: Float = 0.09   // deadband = 9% of current span
    static let minStep: Float = 10                // absolute floor (metres)
    static let stepDivisor: Float = 12            // target quantization ≈ span / 12

    /// The range to adopt, or `nil` to keep `current` (→ no re-render).
    static func next(raw: ClosedRange<Float>,
                     current: ClosedRange<Float>?) -> ClosedRange<Float>?

    /// Snap a raw extent onto a relative "nice" grid; always covers `raw`.
    static func quantize(_ r: ClosedRange<Float>) -> ClosedRange<Float>

    /// A 1/2/5·10ᵏ "nice" step near span/stepDivisor, floored at minStep.
    static func niceStep(forSpan span: Float) -> Float
}
```

`next` logic:

- `current == nil` → `quantize(raw)` (first fit; matches today's "adopt").
- `tol = max(minStep, hysteresisFraction · currentSpan)`. If **both**
  `|raw.lower − current.lower| ≤ tol` **and** `|raw.upper − current.upper| ≤ tol`
  → return `nil` (inside the deadband; keep `current` and its cached renders).
- Otherwise `let next = quantize(raw)`; return `nil` if `next == current`, else
  `next`.

`quantize(r)`:
- `span = max(r.upper − r.lower, minStep)`
- `step = niceStep(forSpan: span)`
- `lo = floor(r.lower / step) · step`, `hi = ceil(r.upper / step) · step`
- return `lo ... max(hi, lo + step)`

`niceStep(forSpan:)`: target `= span / stepDivisor`; take
`pow(10, floor(log10(target)))` as the magnitude, choose the largest of
`{1,2,5}·magnitude` that is `≤ target` (fall back to `1·magnitude`); return
`max(result, minStep)`.

### Invariants (asserted in the harness)

- **Adopted ranges cover `raw`:** `lo ≤ raw.lower` and `hi ≥ raw.upper`, so an
  adopted tint never clips the visible extent.
- **Deadband bound:** when `next` returns `nil`, `current` may under-cover `raw`
  by at most `tol` (≈9% of span) at each end — those fringe samples clamp at the
  palette extremes. This is the accepted "balanced" tradeoff.
- **Idempotent quantize:** `quantize(quantize(x)) == quantize(x)`.
- **Flat terrain unchanged in spirit:** for small spans `niceStep == minStep`
  (10 m) and `tol == minStep`, so behaviour matches the current 10 m snapping.
- **Monotonic stability:** repeated calls with raw extents inside the deadband
  of a fixed `current` all return `nil` (no adoption, no re-render).

### 2. `refreshElevationRange` delegates

Same shape — `.elevation`-only, async, one seam-free `pushSettings()` on adopt:

```swift
public func refreshElevationRange() {
    guard style == .elevation else { return }
    let region = visibleGeoRegion
    Task { [terrainProvider] in
        guard let raw = await terrainProvider.elevationRange(in: region) else { return }
        guard let next = ElevationRangePolicy.next(raw: raw, current: self.elevationExtent)
        else { return }
        self.elevationExtent = next
        self.pushSettings()
    }
}
```

The read-modify-write across the `await` is unchanged from today (no new race
introduced).

### 3. Before/after measurement (harness)

Add an elevation-pan scenario to `Tools/ViewerHarness/main.swift`:

- A sequence of ~14 raw extents mimicking a pan over varied terrain (bounds that
  wander by tens of metres, as in the commit's measured pan).
- Run **baseline** (fixed 10 m snap, adopt on `!=`) and `ElevationRangePolicy`
  over the same sequence.
- Report and assert:
  - **# ranges adopted** (= full-screen re-render bursts) — new < baseline.
  - **# distinct disk keys** for a fixed tile over the pan — new < baseline.
  - **simulated second-pass hit rate** — new > baseline.
- Plus unit checks for every invariant listed above.

### 4. Build wiring & verification

- Add `LidarExplorer/Presentation/ElevationRangePolicy.swift` to the compile
  list in `Tools/run-harness.sh`, immediately before `TerrainViewerModel.swift`.
  The Xcode project uses synchronized folder groups, so the app target picks the
  file up with no `pbxproj` edit.
- Verify: `./Tools/run-harness.sh` (all checks pass, and the before/after
  numbers show the improvement) and an `xcodebuild` build for
  `-scheme LidarExplorer -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'`.

## Non-goals

- No change to the disk PNG key format or the grid cache.
- No new cache tier; no `ReliefProducts` disk cache (measured not worth it).
- No render decomposition and no GPU port of the elevation render.
- No change to hillshade / multiDirectional / slope styles (their keys are
  already stable).

## Risks

- **Tint pops on adoption.** When drift crosses the deadband the whole screen
  re-tints once. Balanced tuning (9% / span-relative step) makes this rare;
  constants are centralized for retuning against the measurement.
- **Under-coverage at fringes.** Up to `tol` of elevation clamps at palette ends
  while inside the deadband — intended and bounded.
