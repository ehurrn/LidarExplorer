# Elevation Range-Churn Suppression Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the `.elevation` shared colour range from changing on every small pan, so the rendered-PNG disk cache stops fragmenting and the full-screen re-render hitch disappears.

**Architecture:** Extract the "should the shared range change?" decision into a pure, `nonisolated` `ElevationRangePolicy` (hysteresis deadband + span-relative quantization), unit-tested in the existing harness. `TerrainViewerModel.refreshElevationRange` delegates to it. A before/after harness scenario proves the churn reduction against the current 10 m-snap baseline.

**Tech Stack:** Swift 6 (strict concurrency), the shell-compiled regression harness (`Tools/run-harness.sh` → `Tools/ViewerHarness/main.swift`, using a `check(name, ok, detail)` assertion helper), Xcode simulator build.

---

## Background the engineer needs

- The harness is **not** XCTest. It is one `main.swift` compiled with the Core/Domain/Services/Presentation sources into a binary that prints `PASS`/`FAIL` lines via a global `check(_ name: String, _ ok: Bool, _ detail: String = "")`. "Run the test" always means run the whole harness: `./Tools/run-harness.sh`. A referenced-but-undefined symbol is a **compile error**, which aborts the whole harness — so a red test here means either a failing `check` line or a deliberate wrong stub, never a missing symbol.
- The harness compiles an **explicit file list** inside `Tools/run-harness.sh`. A new source file must be added there. The Xcode app target uses synchronized folder groups, so it needs **no** `pbxproj` edit.
- `refreshElevationRange` lives in `LidarExplorer/Presentation/TerrainViewerModel.swift` (currently around lines 493–512). It holds the shared range in `private var elevationExtent: ClosedRange<Float>?` and pushes a re-render with `pushSettings()`.
- Current baseline logic (what we are replacing), for reference in the measurement task:
  ```swift
  let lo = (raw.lowerBound / 10).rounded(.down) * 10
  let hi = (raw.upperBound / 10).rounded(.up) * 10
  let quantised = lo ... Swift.max(hi, lo + 10)
  if quantised != self.elevationExtent { self.elevationExtent = quantised; self.pushSettings() }
  ```

---

## File Structure

- **Create** `LidarExplorer/Presentation/ElevationRangePolicy.swift` — the pure decision unit. One responsibility: given a fresh raw extent and the current adopted range, decide the next range (or keep the current one).
- **Modify** `Tools/run-harness.sh` — add the new file to the compile list.
- **Modify** `Tools/ViewerHarness/main.swift` — unit checks (Task 1) and the before/after pan measurement (Task 3).
- **Modify** `LidarExplorer/Presentation/TerrainViewerModel.swift` — delegate `refreshElevationRange` to the policy (Task 2).

---

## Task 1: `ElevationRangePolicy` pure decision unit

**Files:**
- Create: `LidarExplorer/Presentation/ElevationRangePolicy.swift`
- Modify: `Tools/run-harness.sh` (compile list)
- Test: `Tools/ViewerHarness/main.swift` (append a new section)

- [ ] **Step 1: Create the file with deliberately-wrong stub bodies**

Create `LidarExplorer/Presentation/ElevationRangePolicy.swift` with the real API but stub bodies that make the behavioural checks fail (no deadband, identity quantize, floor-only step):

```swift
//
//  ElevationRangePolicy.swift
//  LidarExplorer
//
//  Decides when the shared .elevation colour range should change.
//

import Foundation

/// Chooses the shared hypsometric range for the `.elevation` style, resisting
/// small changes so the rendered-tile cache is not fragmented and the screen is
/// not re-tinted on every pan.
///
/// The range is a view-adaptive aesthetic, not a measurement: it fits the tint
/// to the visible extent, and a little terrain clamping at the palette ends is
/// acceptable. Adopting a new range clears every tile's cached render
/// (`TerrainTileProvider.update`), so adopting *less often* both raises the
/// disk-cache hit rate — the key embeds the range — and removes the full-screen
/// re-render hitch a bare `!=` produced on 10 m pan wobble.
public nonisolated enum ElevationRangePolicy {

    /// Deadband half-width as a fraction of the current span. 9% keeps the tint
    /// tracking the terrain while sitting out ordinary pan wobble.
    public static let hysteresisFraction: Float = 0.09

    /// Absolute floor (metres) for both the quantization step and the deadband,
    /// so flat terrain still behaves like the previous fixed 10 m snapping.
    public static let minStep: Float = 10

    /// Adopted ranges snap to roughly span / this.
    public static let stepDivisor: Float = 12

    // STUB — replaced in Step 3.
    public static func next(
        raw: ClosedRange<Float>, current: ClosedRange<Float>?
    ) -> ClosedRange<Float>? {
        quantize(raw)
    }

    // STUB — replaced in Step 3.
    public static func quantize(_ r: ClosedRange<Float>) -> ClosedRange<Float> {
        r
    }

    // STUB — replaced in Step 3.
    public static func niceStep(forSpan span: Float) -> Float {
        minStep
    }
}
```

Add the file to the harness compile list in `Tools/run-harness.sh`, on the line immediately **before** `LidarExplorer/Presentation/TerrainViewerModel.swift`:

```sh
  LidarExplorer/Presentation/ElevationRangePolicy.swift \
```

- [ ] **Step 2: Append the unit checks to the harness**

Append this section to the **end** of `Tools/ViewerHarness/main.swift`, immediately before the final `print("\n" + String(repeating: "=", count: 52))` summary block:

```swift
// ============================================================
print("\n=== ElevationRangePolicy ===")

// niceStep: span-relative, 1/2/5 grid, floored at minStep.
check("niceStep floors at 10 for flat terrain",
      ElevationRangePolicy.niceStep(forSpan: 10) == 10,
      "\(ElevationRangePolicy.niceStep(forSpan: 10))")
check("niceStep ~50 for 1000 m span",
      ElevationRangePolicy.niceStep(forSpan: 1000) == 50,
      "\(ElevationRangePolicy.niceStep(forSpan: 1000))")
check("niceStep ~20 for 300 m span",
      ElevationRangePolicy.niceStep(forSpan: 300) == 20,
      "\(ElevationRangePolicy.niceStep(forSpan: 300))")

// quantize covers the raw extent (floor low / ceil high => never clips).
let qRaw: ClosedRange<Float> = 203 ... 758
let q = ElevationRangePolicy.quantize(qRaw)
check("quantize covers raw low", q.lowerBound <= qRaw.lowerBound, "\(q.lowerBound)")
check("quantize covers raw high", q.upperBound >= qRaw.upperBound, "\(q.upperBound)")
check("quantize actually snaps (not identity)",
      q.lowerBound != qRaw.lowerBound || q.upperBound != qRaw.upperBound,
      "\(q)")

// First fit: nil current adopts the quantized range.
check("first fit adopts quantized range",
      ElevationRangePolicy.next(raw: qRaw, current: nil) == q, "\(String(describing: ElevationRangePolicy.next(raw: qRaw, current: nil)))")

// Settling: re-evaluating the SAME raw after adopting keeps it (no churn).
check("no immediate re-adoption after settling",
      ElevationRangePolicy.next(raw: qRaw, current: q) == nil,
      "\(String(describing: ElevationRangePolicy.next(raw: qRaw, current: q)))")

// Deadband: a sub-tolerance wobble keeps the current range.
let base: ClosedRange<Float> = 200 ... 1200          // span 1000 => tol = 90
check("deadband keeps current on small wobble",
      ElevationRangePolicy.next(raw: 210 ... 1190, current: base) == nil,
      "adopted despite <tol wobble")

// Beyond the deadband: a large drift adopts a new (covering) range.
let far = ElevationRangePolicy.next(raw: 600 ... 1700, current: base)
check("large drift adopts a new range", far != nil && far != base, "\(String(describing: far))")
check("adopted range covers the new raw",
      (far?.lowerBound ?? 999) <= 600 && (far?.upperBound ?? 0) >= 1700, "\(String(describing: far))")

// Flat terrain still moves on a ~10 m change, like the old behaviour.
let flat: ClosedRange<Float> = 100 ... 110            // span 10 => tol = 10
check("flat terrain adopts on a >10 m shift",
      ElevationRangePolicy.next(raw: 130 ... 145, current: flat) != nil,
      "stuck on flat terrain")
```

- [ ] **Step 3: Run the harness to verify the new checks FAIL**

Run: `./Tools/run-harness.sh`
Expected: the `ElevationRangePolicy` section prints `FAIL` for the snapping, settling, deadband, and drift checks (identity `quantize` doesn't snap or cover-round; stub `next` always adopts, so settling/deadband fail). The final summary prints `N CHECK(S) FAILED`.

- [ ] **Step 4: Replace the stub bodies with the real implementation**

In `LidarExplorer/Presentation/ElevationRangePolicy.swift`, replace the three stub methods with:

```swift
    /// The range to adopt, or `nil` to keep `current` (no re-render).
    public static func next(
        raw: ClosedRange<Float>, current: ClosedRange<Float>?
    ) -> ClosedRange<Float>? {
        guard let current else { return quantize(raw) }
        let span = max(current.upperBound - current.lowerBound, minStep)
        let tol = max(minStep, hysteresisFraction * span)
        if abs(raw.lowerBound - current.lowerBound) <= tol,
           abs(raw.upperBound - current.upperBound) <= tol {
            return nil
        }
        let candidate = quantize(raw)
        return candidate == current ? nil : candidate
    }

    /// Snaps a raw extent onto a span-relative grid. Uses floor/ceil, so the
    /// result always covers `raw` and the tint never clips the visible extent.
    public static func quantize(_ r: ClosedRange<Float>) -> ClosedRange<Float> {
        let span = max(r.upperBound - r.lowerBound, minStep)
        let step = niceStep(forSpan: span)
        let lo = (r.lowerBound / step).rounded(.down) * step
        let hi = (r.upperBound / step).rounded(.up) * step
        return lo ... max(hi, lo + step)
    }

    /// A 1/2/5·10ᵏ "nice" step near `span / stepDivisor`, floored at `minStep`.
    /// Computed in `Double` so `pow`/`log10` resolve without a Float overload.
    public static func niceStep(forSpan span: Float) -> Float {
        let target = max(Double(span) / Double(stepDivisor), Double(minStep))
        let magnitude = pow(10.0, floor(log10(target)))
        for c in [5.0, 2.0, 1.0] where c * magnitude <= target {
            return max(Float(c * magnitude), minStep)
        }
        return max(Float(magnitude), minStep)
    }
```

- [ ] **Step 5: Run the harness to verify all checks PASS**

Run: `./Tools/run-harness.sh`
Expected: the `ElevationRangePolicy` section prints all `PASS`; the final summary prints `ALL CHECKS PASSED`.

- [ ] **Step 6: Commit**

```bash
git add LidarExplorer/Presentation/ElevationRangePolicy.swift Tools/run-harness.sh Tools/ViewerHarness/main.swift
git commit -m "feat(elevation): pure range-churn policy (hysteresis + relative quantization)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Delegate `refreshElevationRange` to the policy

**Files:**
- Modify: `LidarExplorer/Presentation/TerrainViewerModel.swift` (the `refreshElevationRange` method, ~lines 493–512)

- [ ] **Step 1: Replace the method body**

Replace the whole `refreshElevationRange` method with:

```swift
    /// Refits the .elevation colour range to the visible area's loaded tiles.
    ///
    /// Only does work in .elevation mode. `ElevationRangePolicy` decides whether
    /// the newly-measured extent is different enough to adopt: a bare `!=` on a
    /// fixed 10 m snap re-tinted the whole screen on every pan wobble and
    /// fragmented the rendered-tile disk cache (its key embeds the range). When
    /// the policy does adopt, `pushSettings` drives a single seam-free re-render
    /// of every on-screen tile against the new shared range.
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

- [ ] **Step 2: Run the harness to verify it still compiles and passes**

Run: `./Tools/run-harness.sh`
Expected: `ALL CHECKS PASSED` (the model compiles against the new delegation; no behavioural check regressed).

- [ ] **Step 3: Commit**

```bash
git add LidarExplorer/Presentation/TerrainViewerModel.swift
git commit -m "feat(elevation): drive the shared range through ElevationRangePolicy

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Before/after churn measurement in the harness

The task requires measuring, not assuming. This scenario replays a synthetic pan through both the old 10 m-snap baseline and the new policy, and asserts the policy adopts fewer ranges (fewer full-screen re-renders), produces fewer distinct disk keys, and hits the disk cache more on a re-visit. The re-visit uses a few-metre jitter to model the genuine sensitivity of the robust visible extent when re-panning the same ground — the mechanism behind the measured ~47% elevation hit rate.

**Files:**
- Modify: `Tools/ViewerHarness/main.swift` (append another section after the Task 1 section)

- [ ] **Step 1: Append the measurement section**

Append to the **end** of `Tools/ViewerHarness/main.swift`, immediately before the final summary `print` block:

```swift
// ============================================================
print("\n=== ElevationRangePolicy: churn before/after ===")

// A ~14-step pan up a valley: both bounds wander by tens of metres.
let panExtents: [(Float, Float)] = [
    (203, 758), (212, 769), (231, 802), (258, 845), (296, 905),
    (341, 982), (388, 1043), (421, 1088), (447, 1121), (462, 1140),
    (455, 1129), (430, 1094), (398, 1051), (362, 1002),
]
// Per-step jitter (<=6 m) modelling the re-visit's slightly different extent.
let jitter: [Float] = [3, -4, 5, -3, 4, -5, 2, -6, 5, -2, 3, -4, 6, -3]

// The pre-existing baseline: fixed 10 m snap, adopt on any change.
func baselineNext(raw: ClosedRange<Float>, current: ClosedRange<Float>?) -> ClosedRange<Float>? {
    let lo = (raw.lowerBound / 10).rounded(.down) * 10
    let hi = (raw.upperBound / 10).rounded(.up) * 10
    let q = lo ... Swift.max(hi, lo + 10)
    return q != current ? q : nil
}

// Replays a pan (optionally jittered), returning the adopted ranges in order.
func replay(
    _ next: (ClosedRange<Float>, ClosedRange<Float>?) -> ClosedRange<Float>?,
    jittered: Bool
) -> [ClosedRange<Float>] {
    var current: ClosedRange<Float>? = nil
    var adopted: [ClosedRange<Float>] = []
    for (i, e) in panExtents.enumerated() {
        let j = jittered ? jitter[i] : 0
        let raw = (e.0 + j) ... (e.1 + j)
        if let n = next(raw, current) { current = n; adopted.append(n) }
    }
    return adopted
}

func keyString(_ r: ClosedRange<Float>) -> String { "\(Int(r.lowerBound))_\(Int(r.upperBound))" }

for (label, next) in [
    ("baseline(10m,!=)", baselineNext),
    ("policy", ElevationRangePolicy.next),
] as [(String, (ClosedRange<Float>, ClosedRange<Float>?) -> ClosedRange<Float>?)] {
    let pass1 = replay(next, jittered: false)
    let pass2 = replay(next, jittered: true)
    let keys1 = Set(pass1.map(keyString))
    let pass2Keys = pass2.map(keyString)
    let hits = pass2Keys.filter { keys1.contains($0) }.count
    let hitRate = pass2Keys.isEmpty ? 1.0 : Double(hits) / Double(pass2Keys.count)
    let pct = Int((hitRate * 100).rounded())
    print("    \(label)  adoptions(pass1)=\(pass1.count)  distinctKeys=\(keys1.count)  reVisitHitRate=\(pct)%")
}

// Assert the improvement (relative, so it is robust to the synthetic values).
let baseAdopt = replay(baselineNext, jittered: false).count
let policyAdopt = replay(ElevationRangePolicy.next, jittered: false).count
check("policy adopts fewer ranges than baseline",
      policyAdopt < baseAdopt, "policy=\(policyAdopt) baseline=\(baseAdopt)")

let baseKeys = Set(replay(baselineNext, jittered: false).map(keyString)).count
let policyKeys = Set(replay(ElevationRangePolicy.next, jittered: false).map(keyString)).count
check("policy produces fewer distinct disk keys",
      policyKeys < baseKeys, "policy=\(policyKeys) baseline=\(baseKeys)")

func hitRate(_ next: (ClosedRange<Float>, ClosedRange<Float>?) -> ClosedRange<Float>?) -> Double {
    let keys1 = Set(replay(next, jittered: false).map(keyString))
    let k2 = replay(next, jittered: true).map(keyString)
    return k2.isEmpty ? 1.0 : Double(k2.filter { keys1.contains($0) }.count) / Double(k2.count)
}
check("policy re-visits the disk cache more than baseline",
      hitRate(ElevationRangePolicy.next) > hitRate(baselineNext),
      "policy=\(hitRate(ElevationRangePolicy.next)) baseline=\(hitRate(baselineNext))")
```

- [ ] **Step 2: Run the harness and read the numbers**

Run: `./Tools/run-harness.sh`
Expected: the `churn before/after` section prints two lines (baseline vs policy) where **policy** shows fewer adoptions, fewer distinct keys, and a higher re-visit hit rate; all three `check` lines print `PASS`; the summary prints `ALL CHECKS PASSED`. Record the printed numbers in the completion notes.

- [ ] **Step 3: Commit**

```bash
git add Tools/ViewerHarness/main.swift
git commit -m "test(elevation): before/after churn measurement for the range policy

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Full verification (harness + simulator build)

**Files:** none (verification gate).

- [ ] **Step 1: Run the full harness**

Run: `./Tools/run-harness.sh`
Expected: `ALL CHECKS PASSED`.

- [ ] **Step 2: Build for the simulator**

Run:
```bash
xcodebuild -scheme LidarExplorer \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`. If the named simulator is unavailable, list devices with `xcrun simctl list devices available` and use an available iPad Pro destination, noting the substitution.

- [ ] **Step 3: Confirm the tree is clean and the branch is ready**

Run: `git status --short`
Expected: empty (everything committed). The feature branch `feat/elevation-range-churn` now holds the spec, the policy, the delegation, and the measurement.

---

## Self-Review

**Spec coverage:**
- `ElevationRangePolicy` (next / quantize / niceStep, all constants) → Task 1. ✓
- Invariants (covers raw, settling/no-immediate-re-adoption, deadband, flat-terrain) → Task 1 Step 2 checks. ✓
- `refreshElevationRange` delegation, unchanged shape → Task 2. ✓
- Before/after measurement (adoptions, distinct keys, re-visit hit rate) → Task 3. ✓
- Build wiring (compile list; no pbxproj edit) → Task 1 Step 1; Xcode auto-sync noted. ✓
- Verification (harness + iPad Pro 13-inch M5 build) → Task 4. ✓
- Non-goals (no key format change, no new cache tier, no ReliefProducts cache, no render decomposition) → nothing in the plan touches them. ✓

**Placeholder scan:** No TBD/TODO; every code and command step shows full content. ✓

**Type consistency:** `next(raw:current:)`, `quantize(_:)`, `niceStep(forSpan:)`, `hysteresisFraction`, `minStep`, `stepDivisor`, `elevationExtent`, `pushSettings()`, `terrainProvider.elevationRange(in:)`, `check(_:_:_:)` used identically across tasks. ✓
