# Navigate by Default Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Carry out the owner's new interaction model after the first iPad Pro 13" (M5) + Apple Pencil Pro test of build e324172. With no tool lit, a tap does nothing, and every drag pans the map, whether a finger or the Pencil makes it. Spot Inspection becomes its own toggle. The profile (ruler) takes taps for A and B and a Pencil stroke for the whole line, and a finger always pans. The barrel roll and the sun dial always work. On the way, the plan fixes the Pencil pan lock by construction, makes the sun dial re-light the map during a drag, and makes View in 3D and the GeoTIFF export work over a view the map has fully drawn.

**Architecture:** Which touch does what (tool × touch kind → tap action, drag action, which recognizer receives the touch, two-finger rotate and pitch) moves into a pure, host-compiled `MapTouchPolicy`, harness-checked like `HapticRouting`. The MapKit coordinator asks the policy and does nothing else. It never switches `isScrollEnabled`, never changes the tool from a gesture, and keeps MapKit's pan off a Pencil stroke through a gesture failure requirement. The model (host-compiled) gains a `.spotInspection` mode, a `mapTool` view of its state, and the readout's words. The dial's commit becomes a pure leading+trailing throttle. The provider reads back the on-screen tiles its cache has evicted before building a 3D mesh or an export. Views stay iOS-only and are checked by `xcodebuild` and the Simulator.

**Tech Stack:** Swift 6 (`-strict-concurrency=complete`, `-default-isolation MainActor`), SwiftUI, UIKit gesture recognizers, MapKit, the existing `HapticFeedbackManager` / `HapticRouting` stack. No new dependencies.

---

## Context an engineer needs (read first)

- **Start state:** `main` at e324172 (pushed). Harness 1393 PASS / 0 FAIL. Untracked and to be left alone: `HUMAN_DO_THIS.md`, `docs/new-data-layers-prompt.md`, `docs/new-data-layers-proposal.md`. This plan was written untracked. Commit it with Task 14's docs commit, as earlier plans are, unless the orchestrator says otherwise.
- **Verification command:** `./Tools/run-harness.sh` from `/Users/herren/dev/LidarExplorer`. Run it after EVERY edit. A full run must end `ALL CHECKS PASSED`. For partial runs while iterating, use `HARNESS_ONLY=<3+ letters of a check file or section, or a subsection code> ./Tools/run-harness.sh`. A partial run never prints `ALL CHECKS PASSED`, and that is expected. The subsection codes this plan adds are R1–R4 (new `MapTouchPolicyChecks`), 2e–2h (`InteractiveAnalysisChecks`), X1 (`DialGeometryChecks`) and U3–U5 (`Terrain3DChecks`). W1/W2 and V1–V6 are taken, so do not reuse them.
- **UI build check.** The harness does not compile SwiftUI views or `TerrainMapView.swift`:
  ```
  xcodebuild -project LidarExplorer.xcodeproj -scheme LidarExplorer \
    -destination 'platform=iOS Simulator,id=1E25EA1A-124E-48BF-BDFB-EC688EB84934' \
    -derivedDataPath build-review/DerivedData build 2>&1 | tail -3
  ```
  Expected: `** BUILD SUCCEEDED **` with 0 Swift warnings. For a device build: `-destination 'generic/platform=iOS'`. Nobody installs on the physical iPad. Device checks go to the owner through `HUMAN_DO_THIS.md` (Task 14).
- **Simulator** (iPad Pro 13-inch (M5), UDID `1E25EA1A-124E-48BF-BDFB-EC688EB84934`). Use it only if the orchestrator told you that you may. Install the build above with `xcrun simctl install 1E25EA1A-124E-48BF-BDFB-EC688EB84934 build-review/DerivedData/Build/Products/Debug-iphonesimulator/LidarExplorer.app`. Launch with `SIMCTL_CHILD_TEST_INITIAL_STYLE=Hillshade xcrun simctl launch --terminate-running-process 1E25EA1A-124E-48BF-BDFB-EC688EB84934 com.detsom.LidarExplorer`. Drive taps, swipes and paths with the control tool: load it with ToolSearch `select:mcp__Claude_Code_iOS_Simulator__control`, then use `tap`, `swipe`, `touch_path` and `screenshot`. Screenshots and logs go in `build-review/navigate-by-default/`. The Simulator has no Pencil, plays no haptics and cannot inject a double-tap fast enough for MapKit's zoom. What only the iPad can show is listed per task and ends up in `HUMAN_DO_THIS.md`.
- **Temporary hooks.** This repo's practice is DEBUG-only code that is used to drive or log a Simulator run and is **never committed**. Check `git diff` for `TEST_TOUCHES_AS_PENCIL`, `NBD-LOG` and similar before every commit. Task 5 defines the touch hook.
- **Commit style:** `agent-checkpoint: <lowercase description>`, one commit per task (Task 5 may use two), ending with a blank line and `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Isolation.** Default isolation is MainActor. A pure type the harness calls from anywhere is `nonisolated` (see `HapticRouting.swift`, `DialGeometry.swift`). New pure files that the harness must compile go into `SOURCES` in `Tools/run-harness.sh`. The app target picks them up without a project edit, because its groups are filesystem-synchronized.
- **Scope guard (CLAUDE.md).** Each task is one subsystem. Write the checks first and see them fail before the fix. If the harness fails, fix it before touching another file. Commit per task.
- **Line numbers** below are at e324172 unless a task says otherwise. They drift as tasks land, so re-find them by the quoted code.

---

## What the owner reported (device, e324172) and decided

Reported on the iPad Pro 13" (M5) with an Apple Pencil Pro:

1. **Pencil behaviour.** "I keep accidentally hitting the screen and doing a Spot Inspection or dragging the pencil and doing a Micro-Topography Profile when I intended to use the pencil to move the UI."
2. **Pan lock.** After using the Pencil (spot inspection or profile), neither a finger nor the Pencil moves the map. A pinch still zooms. 08c84a7's fix did not cure it on the device.
3. **Haptics.** Felt: the tick when the Pencil made a Spot Inspection, and the dial's ticks with the Pencil on the dial. Not felt: anything while inspecting a profile ("dragging across slope line, etc").
4. **Dial.** A Pencil drag round the dial re-lights the map only on lift. The barrel roll re-lights it continuously.
5. **3D.** Over a clearly drawn Hillshade view near Paris/Whitlock, Tennessee (about 36.40 N 88.34 W, several km across), View in 3D said "No terrain has drawn for this view yet…". A spot inspection there read 170.7 m.
6. **Confirmed working.** The Pencil ring by the hovering Pencil, the barrel roll re-lighting without flashes, the dock turning into a pill, and the profile's cut/fill shading over Monks Mound (a 464 m transect: Climb 32.4 m, Descent 35.0 m, Max Slope 33.5°; no earthwork chips or bands in the screenshot).

The owner also said that in the checklist's step 3 the dock turns into the pill as described, but the top bar "only change[s] to be slightly transparent". The owner also asked what "the readout" is. It is the box at the top bar's left, the one that says "Tap map for elevation" (or "Drag or tap Point A" with the ruler lit). Task 14 names it that way everywhere.

**Decided by the owner:**
- By default (no tool lit), a tap does nothing, and every drag, finger or Pencil, pans the map like a finger.
- The barrel roll and the sun dial always work.
- Spot Inspection is its own toggle in the top bar's mode cluster and stays on until turned off. While it is on, a tap (finger or Pencil) inspects, and drags still pan.
- Profile (ruler): a tap (finger or Pencil) places A, then B. A Pencil drag draws the A-to-B line in one stroke. A one-finger drag pans the map.
- Viewshed and Field Markup keep their behaviour.
- The top bar keeps its current fade while the map moves.

---

## Root causes this plan relies on (checked by the planner against e324172)

"Read" means the planner confirmed it by reading the cited code. "Probe" means an investigation's host probe or Simulator run showed it (outputs under `build-review/feedback-investigation/`). The planner re-read those outputs but did not re-run them. "Inferred" means neither reading nor a run shows it.

| # | Cause | Evidence | Status |
|---|---|---|---|
| 1 | Every Pencil touch goes to the transect pan in every mode except the wipe's recognizer, and it turns MapKit scrolling off as it lands. So the Pencil can never pan the map in any mode. | `TerrainMapView.swift:699-703` | Confirmed (read) |
| 2 | When that pan begins, it switches the mode to `.transect`, from explore, spot, viewshed, the split wipe or markup's hand tool. This is the accidental profile. | `TerrainMapView.swift:753` | Confirmed (read) |
| 3 | In `.transect` (and `.thalweg`), one-finger scrolling is off. Every finger touch also goes to the transect pan, so a finger drag redraws A–B instead of panning. Zoom is never disabled, which is why pinch works. This is the owner's lock. | `TerrainMapView.swift:215, 705, 714, 741, 745, 761`; no `isZoomEnabled` anywhere (grep) | Mechanism confirmed (read). That it is what the owner hit is **inferred** (no device log) |
| 4 | The profile panel's X calls only `clearProfile()`, which never changes the mode. The panel goes, but the ruler mode and the lock stay. | `ElevationProfileView.swift:133-134`; `TerrainViewerModel.swift:1064-1074`; probe P3 | Confirmed (read + probe) |
| 5 | A Pencil squeeze or double-tap enters profile mode from every mode but markup. Doing it again does not leave (it toggles signatures or cycles the metric). The Pencil's system preferences are never read. | `TerrainViewerModel.swift:1041-1062`; `TerrainMapView.swift:963-979`; grep: only `prefersPencilOnlyDrawing` is read (`PencilMarkupOverlay.swift:64`); probe P2 | Confirmed (read + probe). Whether the owner squeezed is inferred |
| 6 | Going from profile or thalweg to viewshed changes none of `TerrainMapView`'s inputs. `viewshedVersion` is bumped only when the new mode is not viewshed. | `TerrainViewerModel.swift:796-798, 1229-1234`; pan-lock probe Part A | Input facts confirmed (read + probe). That SwiftUI then skips `updateUIView` (scroll left off in viewshed) is **inferred** |
| 7 | After 08c84a7, scrolling that a Pencil landing turned off comes back only through the pan's `reset()`. | `TerrainMapView.swift:702, 713-715, 989-996` | Code confirmed. UIKit's timing of `reset()` for a real stylus is **inferred** (low rank) |
| 8 | Any tap in explore inspects. The tap recognizer has no delegate and no touch-type filter. | `TerrainMapView.swift:130-134, 767-771`; `TerrainViewerModel.swift:1156-1157, 714-717`; probe P1 | Confirmed (read + probe) |
| 9 | The dial restarts a 60 ms debounce on every drag sample, so `model.azimuth` is written only after a 60 ms pause or on lift. The roll writes whole degrees directly. `pushSettings` is itself a 16 ms restart-debounce. | `ShadingDockView.swift:324-338`; `TerrainViewerModel.swift:189-191, 645-658`; `PencilRollAzimuth` via `TerrainViewerModel.swift:954-971`; virtual-clock probe `haptics-dial/out/dial-run.log` (0 writes before lift at every rate) | Confirmed (read + probe). That a Pencil held still keeps sending samples is **inferred** (UIKit docs) |
| 10 | View in 3D and the elevation export build only from the provider's in-memory cache, and return nil when no cached tile touches the view. The cache is LRU, capped at 160 tiles / 256 MB, and promotes a tile only on a `tileImage` hit. The renderer draws from its own image store and never asks again for a tile it holds. So tiles on screen age out while they stay drawn. | `TerrainTileOverlay.swift:1701-1717` (activeGrid), `167-168`, `489-492`, `1934-1941`, `1967-1974`, `2077`, `2442-2444`; `TerrainViewerModel.swift:1708-1716, 1581, 1983-1986`; Simulator reproduction and screenshots in `3d-refusal/` | Code confirmed (read). The Simulator refusal over a drawn view is a probe. Which cap emptied the owner's cache (count or bytes) is **inferred** |
| 11 | There is no span limit: the mosaic coarsens instead of failing. | `MercatorMosaicBuilder.swift:84-94` | Confirmed (read) |
| 12 | "Only 98%" on complete tall views: `activeGrid` sizes the grid from 111,132 m/° ground metres around the latitude mean. The builder places it in sphere Mercator, 111,319.5 m/°, so it falls 8–18 m short of the view's north and south edges. | `TerrainTileOverlay.swift:1719`; `GeoRegion.swift:66, 78-80, 180-200`; `MercatorMosaicBuilder.swift:90-93`; harness-copy U10 | Code confirmed (read). The metres are from a probe |
| 13 | The profile's thump fires only when the chart scrub crosses a *detected* earthwork's break, with signatures shown. Nothing fires on the map, or for the Slope tab's 20° line. On 45 Monks-Mound lines like the owner's, the detector found no signature (flat tops 44–48 m, over its 10–40 m cap). | `ElevationProfileView.swift:79-84, 511-543`; `HapticFeedbackManager.swift:36, 180-195`; `ElevationTransect.swift:210-242`; `haptics-dial/out/real-run.log` | Code confirmed (read). The Monks result is a probe. The owner's exact line is unknown |
| 14 | The sun dial disappears while a profile is shown, because the panel replaces the dock. | `TerrainViewerView.swift:177-183` | Confirmed (read) |
| 15 | A fourth mode segment makes the button row 350 pt, against 304 today, which overflows iPhones in portrait narrower than 400 pt. | `ViewerTopBarView.swift:49-55, 99, 216, 236, 300-314, 383` (arithmetic) | Arithmetic confirmed (read). Not rendered |
| 16 | Tools are not fully exclusive. A cluster tool leaves the split wipe up. Remove All with the wipe on strands the wipe's mode. Settings' Draw River Thalweg leaves markup on. | `TerrainViewerModel.swift:1313`; `ViewerSettingsSheetView.swift:283-286, 354-365`; probes P4, P6 | Confirmed (read + probe) |

Out of reach of any check before the device: UIKit making MapKit's private pan wait on our recognizer's failure, MapKit's pan taking real Pencil touches, the Pencil playing each haptic, and iPadOS palm rejection during a Pencil stroke.

---

## Decisions this plan takes where the owner has not spoken (defaults; each is one place to change)

- **D1 Pencil squeeze and double-tap.** They never light a tool. In profile mode they keep their actions: the squeeze cycles the metric and the double-tap toggles the earthwork signatures. Everywhere else they do nothing and post nothing. When the iPad's Settings > Apple Pencil sets that gesture to Off (`preferredTapAction` / `preferredSqueezeAction` `== .ignore`), they do nothing anywhere. This follows the owner's "when we want to measure things, we choose to". (Alternative the owner may prefer: a squeeze toggles the ruler.)
- **D2 The profile panel's X** closes the result and leaves the ruler lit, like Spot Inspection's "on until turned off" and the spot callout's own X. The lock cannot come back, because a finger pans in profile mode.
- **D3 Two-finger rotate and pitch** are on with no tool, in Spot Inspection, in profile and with markup's hand tool. They are off in viewshed (unchanged), thalweg and the split wipe (whose two-finger drag moves the wipe).
- **D4 The readout** with no tool lit says "Pick a tool to measure". With the pen or highlighter up it says "Draw on the map", and with the hand tool, "Move the map" (this closes pre-device audit finding 17). With the ruler lit it says "Tap Point A on map", then "Tap Point B on map", and "Drawing transect…" while the Pencil draws.
- **D5 Profile taps wait for a double-tap zoom to fail** (about 0.25 s per tap, profile mode only), so that a double-tap zoom cannot place A and B at one point. Spot and viewshed taps do not wait: a double-tap zoom there re-reads or re-places at the same spot, which is harmless.
- **D6 The sun dial while a profile is shown** is a compact dial in the profile panel's header, shown when the style takes the sun. (Alternative: stack the dock above the panel.)
- **D7 Picking a tool, or markup, ends the split wipe.** A tool may no longer leave the wipe's line on screen with its two-finger drag dead.
- **D8 Thalweg is unchanged.** A finger or the Pencil traces the channel, and the map does not pan while it is lit.
- **D9 A trackpad or mouse pointer** pans like a finger in profile mode and taps like one everywhere.
- **D10 No new haptic** for the profile unless the owner asks (Task 13 is gated). Task 14 tells the owner what plays when.

**The owner's answers (2026-09-28, before execution; they overrode the text above):** D1 confirmed, including that the squeeze and double-tap do nothing when the iPad sets them Off. D2–D10 stand as defaults the owner may overrule after testing. Task 12 is in. Task 13 is in (the owner said yes), so D10 is superseded: the Slope tab's scrub ticks where the slope crosses its 20° line.

**As executed (Task 14 record):** D5's wait measured 0.35–0.37 s per profile tap in the Simulator, not about 0.25 s, and with a line shown a profile tap also waits for MapKit's one-finger zoom, about 0.51 s (acfda68). D8 holds for one-touch drags only: in the thalweg two fingers landing together pan and pinch the map (Task 5's review). Markup's hand tool now does nothing on a tap, where e324172 inspected (Task 1's table, a default the owner did not name; `case .markupHand: .inspect` in `MapTouchPolicy.tap` brings it back, with R1's hand-tool check changed to match; the reading it brings back then outlives markup, which nothing checks). The rest held as written.

---

## Task order

Pure policy first (Task 1). Then the model, in three small passes (Tasks 2–4). Then the map bridge that uses both, which is where the pan lock is fixed (Task 5). Then the readout and the top bar that make Spot Inspection reachable (Tasks 6–7). Then the dial (Tasks 8–9). Then the provider for 3D and export (Tasks 10–12). Then the optional haptic (Task 13) and the record (Task 14). Between Task 2 and Task 7 the app builds and passes, but Spot Inspection has no button, so do not hand the owner a build from that range.

---

### Task 0: Baseline

- [x] **Step 1:** Read `.agent/HANDOFF.json`, then `git log -n 1 --stat`. Expected: e324172, docs only.
- [x] **Step 2:** Run `./Tools/run-harness.sh`. Expected: `ALL CHECKS PASSED`, 1393. If it is not, stop and record the failure. Do not start Task 1.
- [x] **Step 3:** Run the UI build check. Expected: `** BUILD SUCCEEDED **`.

**Execution note:** the orchestrator ran the baseline (1393 PASS at e324172) and told each task's agent to skip CLAUDE.md's session-startup and handoff steps. Every task ran its Simulator build with the destination name `iPad Pro 11-inch (M5)` and installed and drove the product on the 13-inch by UDID; the device check was `generic/platform=iOS` with `CODE_SIGNING_ALLOWED=NO`. The tasks' build logs carry one `warning:` line, the App Intents metadata processor's "Metadata extraction skipped", which predates this plan; none has a Swift warning. Evidence is under `build-review/navigate-by-default/` (`taskN-*` logs, `taskN/` screenshots) and `build-review/tN-fix-r1-*` for Task 10 onward only: `build-review` was emptied between Task 9 and Task 10 (its oldest entry is from 03:06 on 2026-10-01), so the evidence of Tasks 1-9 and their review rounds, the Task 5 gate's screenshots among it, is gone, and for those tasks the commit messages and `STATUS.md` are the record. One departure from "nobody installs on the physical iPad" is on disk: at 03:20 on 2026-10-01 a script in `build-review/device-smoke/` installed and launched the app on the owner's iPad, most likely a 9d55175 snapshot, and the iPad's lock refused the later launches, so nothing was verified there (`STATUS.md`, TODOs > "Navigate by default"). Each task had a review-and-fix round (one fix commit after its own, two for Task 5), and a holistic review of e324172..961cc0e ended in acfda68. The commits, task by task, are in `STATUS.md` (TODOs > "Navigate by default (2026-09-28)").

---

### Task 1: `MapTouchPolicy` — which touch does what, as a pure type (TDD)

This is the owner's model as a table the harness checks. Nothing calls it yet, so the app does not change. The table has no output that switches scrolling or changes the tool, which is what makes the lock impossible by construction. The sketch in `build-review/feedback-investigation/pan-lock/MapTouchPolicySketch.swift` compiled under the harness flags, and its invariants held (probe Part C).

**Files:**
- Create: `Tools/ViewerHarness/MapTouchPolicyChecks.swift`
- Create: `LidarExplorer/Presentation/MapTouchPolicy.swift` (a stub in Step 2, the real type in Step 3)
- Modify: `Tools/run-harness.sh`. Add `LidarExplorer/Presentation/MapTouchPolicy.swift \` after `HapticRouting.swift` in `SOURCES`, and `Tools/ViewerHarness/MapTouchPolicyChecks.swift \` after `DialGeometryChecks.swift`.
- Modify: `Tools/ViewerHarness/main.swift`. Add `await harnessSection("MapTouchPolicyChecks") { runMapTouchPolicyChecks() }` after the `DialGeometryChecks` line (about line 2440).

- [x] **Step 1: Write the checks — create `Tools/ViewerHarness/MapTouchPolicyChecks.swift`**

```swift
//
//  MapTouchPolicyChecks.swift
//  ViewerHarness
//
//  Which touch on the map does what, for each tool (MapTouchPolicy): the owner's navigate-by-default rules of
//  2026-09-28, checked without a device or a Pencil. R4, added with the map bridge (Task 5), reads the bridge's own
//  source for the two things that made the pan lock.
//

import Foundation

@MainActor
func runMapTouchPolicyChecks() {
    print("\n=== Map touch policy ===")
    checkTapsAndDrags()
    checkWhatEachRecognizerReceives()
    checkTwoFingerGestures()
}

@MainActor
private func checkTapsAndDrags() {
    print("\n--- R1. what a tap and a drag do ---")
    let kinds = MapTouchKind.allCases
    func tap(_ tool: MapTool, _ kind: MapTouchKind) -> MapTapAction? { MapTouchPolicy.tap(in: tool, by: kind) }
    func drag(_ tool: MapTool, _ kind: MapTouchKind) -> MapDragAction { MapTouchPolicy.drag(in: tool, by: kind) }

    check("with no tool lit a tap does nothing, finger, Pencil or pointer",
          kinds.allSatisfy { tap(.navigate, $0) == nil })
    check("with no tool lit every one-touch drag pans the map, the Pencil's too",
          kinds.allSatisfy { drag(.navigate, $0) == .panMap })
    check("Spot Inspection: a tap reads the ground, finger or Pencil, and drags still pan",
          kinds.allSatisfy { tap(.spot, $0) == .inspect && drag(.spot, $0) == .panMap })
    check("profile: a tap places a point, finger or Pencil",
          kinds.allSatisfy { tap(.profile, $0) == .placeProfilePoint })
    check("profile: a Pencil drag draws the line; a finger or pointer drag pans",
          drag(.profile, .pencil) == .drawProfile && drag(.profile, .finger) == .panMap && drag(.profile, .pointer) == .panMap)
    check("viewshed: a tap places the observer, and every drag pans (a Pencil drag no longer starts a profile)",
          kinds.allSatisfy { tap(.viewshed, $0) == .placeObserver && drag(.viewshed, $0) == .panMap })
    check("thalweg: every drag traces the channel, and a tap does nothing",
          kinds.allSatisfy { drag(.thalweg, $0) == .drawThalweg && tap(.thalweg, $0) == nil })
    check("split wipe: a tap does nothing and a one-touch drag pans",
          kinds.allSatisfy { tap(.splitWipe, $0) == nil && drag(.splitWipe, $0) == .panMap })
    check("markup's pen and highlighter: the canvas over the map takes every touch",
          kinds.allSatisfy { drag(.markupInk, $0) == .canvas && tap(.markupInk, $0) == nil })
    check("markup's hand tool: every drag pans, the Pencil's too, and a tap does nothing",
          kinds.allSatisfy { drag(.markupHand, $0) == .panMap && tap(.markupHand, $0) == nil })
    // The pan lock, ruled out by construction: no tool but the thalweg's (and the canvas over the map) takes a finger.
    check("one finger pans the map in every tool but the thalweg and markup's canvas",
          MapTool.allCases.allSatisfy { [.thalweg, .markupInk].contains($0) || drag($0, .finger) == .panMap })
    check("a Pencil drag draws only in profile and thalweg",
          MapTool.allCases.filter { [.drawProfile, .drawThalweg].contains(drag($0, .pencil)) } == [.profile, .thalweg])
}

@MainActor
private func checkWhatEachRecognizerReceives() {
    print("\n--- R2. which recognizer receives a touch ---")
    let pairs = MapTool.allCases.flatMap { tool in MapTouchKind.allCases.map { (tool, $0) } }
    check("the draw recognizer receives exactly the touches that draw",
          pairs.allSatisfy { tool, kind in
              MapTouchPolicy.drawRecognizerReceives(in: tool, by: kind)
                  == [.drawProfile, .drawThalweg].contains(MapTouchPolicy.drag(in: tool, by: kind)) })
    check("the tap recognizer receives a touch only where a tap acts",
          pairs.allSatisfy { tool, kind in
              MapTouchPolicy.tapRecognizerReceives(in: tool, by: kind) == (MapTouchPolicy.tap(in: tool, by: kind) != nil) })
    check("the two-finger wipe recognizer receives touches only in the split wipe",
          MapTool.allCases.filter(MapTouchPolicy.wipeRecognizerReceives(in:)) == [.splitWipe])
    check("only a profile tap waits for a double-tap zoom to fail (A and B are never placed at one point by a zoom)",
          MapTool.allCases.filter(MapTouchPolicy.tapWaitsForDoubleTap(in:)) == [.profile])
}

@MainActor
private func checkTwoFingerGestures() {
    print("\n--- R3. two-finger rotate and pitch ---")
    check("rotate and pitch with no tool, Spot Inspection, profile and markup's hand tool",
          [MapTool.navigate, .spot, .profile, .markupHand].allSatisfy(MapTouchPolicy.rotatesAndPitches(in:)))
    check("no rotate or pitch in viewshed, thalweg, the split wipe or under markup's canvas",
          ![MapTool.viewshed, .thalweg, .splitWipe, .markupInk].contains(where: MapTouchPolicy.rotatesAndPitches(in:)))
}
```

- [x] **Step 2: See the checks fail against e324172's rules.** Create `LidarExplorer/Presentation/MapTouchPolicy.swift` with the real enums (copy them from Step 3), but make `MapTouchPolicy` encode today's routing:

```swift
public nonisolated enum MapTouchPolicy {   // STUB: e324172's rules, replaced in Step 3
    public static func tap(in tool: MapTool, by kind: MapTouchKind) -> MapTapAction? {
        switch tool {
        case .navigate, .markupHand: .inspect
        case .profile: .placeProfilePoint
        case .viewshed: .placeObserver
        case .spot, .thalweg, .splitWipe, .markupInk: nil
        }
    }
    public static func drag(in tool: MapTool, by kind: MapTouchKind) -> MapDragAction {
        switch tool {
        case .markupInk: .canvas
        case .thalweg: .drawThalweg
        case .profile: .drawProfile
        default: kind == .pencil ? .drawProfile : .panMap
        }
    }
    public static func drawRecognizerReceives(in tool: MapTool, by kind: MapTouchKind) -> Bool {
        [.drawProfile, .drawThalweg].contains(drag(in: tool, by: kind))
    }
    public static func tapRecognizerReceives(in tool: MapTool, by kind: MapTouchKind) -> Bool { true }
    public static func wipeRecognizerReceives(in tool: MapTool) -> Bool { tool == .splitWipe }
    public static func tapWaitsForDoubleTap(in tool: MapTool) -> Bool { false }
    public static func rotatesAndPitches(in tool: MapTool) -> Bool { tool == .navigate || tool == .markupHand }
}
```

Run `HARNESS_ONLY=MapTouch ./Tools/run-harness.sh`. Expected FAILs, at least: "with no tool lit a tap does nothing", "…every one-touch drag pans the map, the Pencil's too", "Spot Inspection: …", "profile: a Pencil drag draws the line; a finger or pointer drag pans", "viewshed: …", "markup's hand tool: …", "one finger pans the map in every tool but …", "a Pencil drag draws only in profile and thalweg", "the tap recognizer receives a touch only where a tap acts", "only a profile tap waits …", "rotate and pitch with no tool, Spot Inspection, profile …". Save the output as `build-review/navigate-by-default/task1-red.txt`.

- [x] **Step 3: Write the real type — replace `LidarExplorer/Presentation/MapTouchPolicy.swift`**

```swift
//
//  MapTouchPolicy.swift
//  LidarExplorer
//
//  Which touch on the map does what, for each tool, decided apart from the recognizers that carry it out, so the
//  harness checks the rules no Simulator can reach with a real Pencil (the pattern of HapticRouting.swift).
//
//  The owner's rules (2026-09-28, after the first iPad Pro and Pencil Pro test): with no tool lit, navigating, a tap
//  does nothing and every one-touch drag, finger or Pencil, pans the map. Spot Inspection's tap reads the ground and
//  its drags pan. The profile's tap places A, then B; a Pencil drag draws the line in one stroke; a finger drag pans.
//  Viewshed's tap places the observer. The thalweg's drag, finger or Pencil, traces the channel. The split wipe's
//  two-finger drag moves the wipe. Markup's pen and highlighter canvas covers the map and takes every touch.
//
//  What is absent is the point: nothing here switches MapKit's scrolling, and no touch changes the tool. A Pencil
//  stroke took the map into profile mode, where one-finger scrolling was off, and left it there (the pan lock).
//

import Foundation

/// The tool lit in the top bar (or none), with the two that Settings starts and markup's two kinds of touch.
public nonisolated enum MapTool: String, Sendable, CaseIterable {
    /// No tool lit: the map is for moving around.
    case navigate
    case spot
    case profile
    case viewshed
    case thalweg
    case splitWipe
    /// Markup's pen or highlighter: its drawing canvas lies over the map.
    case markupInk
    /// Markup's hand tool, "Move the map": the canvas is removed.
    case markupHand
}

/// What touched the glass. The map bridge maps `UITouch.TouchType`: `.direct` is a finger, `.pencil` the Pencil,
/// `.indirect` and `.indirectPointer` a pointer (a trackpad or a mouse), which acts as a finger does.
public nonisolated enum MapTouchKind: String, Sendable, CaseIterable {
    case finger, pencil, pointer
}

/// What a tap on the map does.
public nonisolated enum MapTapAction: String, Sendable, CaseIterable {
    case inspect, placeProfilePoint, placeObserver
}

/// What a one-touch drag on the map does. No case changes the tool.
public nonisolated enum MapDragAction: String, Sendable, CaseIterable {
    /// MapKit's own pan takes it.
    case panMap
    /// The app's draw recognizer takes it, and MapKit's pan waits for that recognizer and fails once it draws.
    case drawProfile
    case drawThalweg
    /// Markup's canvas is over the map; the map never sees the touch.
    case canvas
}

public nonisolated enum MapTouchPolicy {

    /// What a tap does, or nil for nothing (the tap recognizer then never receives the touch).
    public static func tap(in tool: MapTool, by kind: MapTouchKind) -> MapTapAction? {
        switch tool {
        case .spot: .inspect
        case .profile: .placeProfilePoint
        case .viewshed: .placeObserver
        case .navigate, .thalweg, .splitWipe, .markupInk, .markupHand: nil
        }
    }

    /// What a one-touch drag does.
    public static func drag(in tool: MapTool, by kind: MapTouchKind) -> MapDragAction {
        switch tool {
        case .markupInk: .canvas
        case .profile: kind == .pencil ? .drawProfile : .panMap
        case .thalweg: .drawThalweg
        case .navigate, .spot, .viewshed, .splitWipe, .markupHand: .panMap
        }
    }

    /// Whether the draw recognizer receives this touch: exactly the touches whose drag draws.
    public static func drawRecognizerReceives(in tool: MapTool, by kind: MapTouchKind) -> Bool {
        switch drag(in: tool, by: kind) {
        case .drawProfile, .drawThalweg: true
        case .panMap, .canvas: false
        }
    }

    /// Whether the tap recognizer receives this touch: only where a tap acts, so with no tool lit a tap is not even seen.
    public static func tapRecognizerReceives(in tool: MapTool, by kind: MapTouchKind) -> Bool {
        tap(in: tool, by: kind) != nil
    }

    /// Whether the two-finger wipe recognizer receives touches.
    public static func wipeRecognizerReceives(in tool: MapTool) -> Bool { tool == .splitWipe }

    /// Whether a tap waits for MapKit's double-tap zoom to fail (about a quarter second). Only in profile mode, where
    /// the two taps of a zoom would otherwise place A and B at one point; elsewhere a zoom re-reads or re-places at
    /// the same spot, which is harmless, and every tap answers at once.
    public static func tapWaitsForDoubleTap(in tool: MapTool) -> Bool { tool == .profile }

    /// Whether two fingers rotate and pitch the map: wherever one finger pans and no tool uses two fingers.
    public static func rotatesAndPitches(in tool: MapTool) -> Bool {
        switch tool {
        case .navigate, .spot, .profile, .markupHand: true
        case .viewshed, .thalweg, .splitWipe, .markupInk: false
        }
    }
}
```

- [x] **Step 4: Run to green.** `HARNESS_ONLY=MapTouch ./Tools/run-harness.sh`: every R1–R3 check passes. Then run the full `./Tools/run-harness.sh` (`ALL CHECKS PASSED`, 1393 + the new count; record it) and the UI build check.
- [x] **Step 5: Mutants.** Make each edit, run `HARNESS_ONLY=MapTouch`, confirm that the named check fails, then revert:
  - (a) `.navigate` in `drag` returns `.drawProfile` for `.pencil`. Expect FAIL on "…every one-touch drag pans the map, the Pencil's too".
  - (b) `.profile` returns `.drawProfile` for every kind. Expect FAIL on "profile: a Pencil drag draws the line; a finger …" and "one finger pans the map in every tool …".
  - (c) `.spot` in `tap` returns nil. Expect FAIL on "Spot Inspection: …".
  - (d) `rotatesAndPitches(.viewshed)` returns true. Expect FAIL on "no rotate or pitch in viewshed …".
  - Record the four in the commit message.
- [x] **Step 6: Commit** `agent-checkpoint: which touch on the map does what, as a pure host-checked table (maptouchpolicy): the owner's navigate-by-default rules; nothing calls it yet; r1-r3 red against e324172's routing, 4 mutants caught`

**Verified by:** the harness (R1–R3, red first) and `xcodebuild`. There is nothing to drive in the Simulator. Nothing here is device-only.

**Execution note (da96513, review fixes 956d180; harness 1411):** code and checks as written. The red run failed 12 of 18, one more than the plan's minimum: the split wipe's check, because the stub's default branch drew a profile for a Pencil drag in the wipe, as e324172 did (root cause 1). The review round changed comments only: the tap doc and R1's hand-tool check record that markup's hand tool now does nothing on a tap, where e324172 inspected (a default, not the owner's rule); the rotate-and-pitch doc names viewshed as its exception; the drag doc and the header no longer assume mechanism A.

---

### Task 2: Model — Spot Inspection as a tool; a tap with no tool does nothing; `mapTool`

**Files:**
- Modify: `LidarExplorer/Presentation/TerrainViewerModel.swift` (`InteractionMode` 780-786, its `didSet` 788-803, `handleMapTap` 1137-1163, new `isSpotInspectionActive`, `toggleSpotInspection()`, `mapTool`)
- Modify: `Tools/ViewerHarness/InteractiveAnalysisChecks.swift` (new subsection 2e, called after `checkCutFillStretches()`)
- Modify: `LidarExplorer/Presentation/ViewerTopBarView.swift`. Only the switch arms needed to compile: in `readoutText` (164-206), `case .explore, .spotInspection:` for today's explore block; in `slidingMode` (255-261), add `.spotInspection` to the nil/markup arm. Task 7 replaces both.

- [x] **Step 1: Write the checks** (new function in `InteractiveAnalysisChecks.swift`, called from `runInteractiveAnalysisChecks()` after `checkCutFillStretches()`):

```swift
/// Navigating is the default: with no tool lit a tap reads nothing (it inspected, so a Pencil grazing the glass opened a
/// reading). Spot Inspection is a tool of its own, on until turned off, whose taps read the ground; the other tools
/// and markup leave it, and it leaves them.
@MainActor
private func checkNavigateByDefault() {
    print("\n--- 2e. navigate by default and Spot Inspection ---")
    let c = CLLocationCoordinate2D(latitude: 38.6605, longitude: -90.0621)
    let c2 = CLLocationCoordinate2D(latitude: 38.6612, longitude: -90.0610)
    func reading(_ m: TerrainViewerModel) -> CLLocationCoordinate2D? {
        if case .loading(let at) = m.inspectionState { return at }
        return nil
    }

    let fresh = TerrainViewerModel()
    check("a new viewer has no tool lit: it navigates", fresh.interactionMode == .explore && fresh.mapTool == .navigate)
    fresh.handleMapTap(c)
    check("with no tool lit a tap reads nothing", fresh.inspectionState == .idle && fresh.activeSpot == nil,
          "\(fresh.inspectionState)")

    let spot = TerrainViewerModel()
    spot.toggleSpotInspection()
    check("the Spot Inspection toggle lights it", spot.isSpotInspectionActive && spot.mapTool == .spot)
    spot.handleMapTap(c)
    check("a tap in Spot Inspection reads the ground under it, and the tool stays lit",
          reading(spot)?.latitude == c.latitude && spot.isSpotInspectionActive)
    spot.clearInspection()
    check("closing the reading (the callout's X) keeps Spot Inspection lit",
          spot.isSpotInspectionActive && spot.inspectionState == .idle)
    spot.handleMapTap(c)
    spot.toggleSpotInspection()
    check("turning Spot Inspection off drops its reading and lights nothing",
          spot.mapTool == .navigate && spot.inspectionState == .idle && spot.activeSpot == nil)

    let swap = TerrainViewerModel()
    swap.toggleFieldMarkup()
    swap.toggleSpotInspection()
    check("entering Spot Inspection leaves field markup", swap.isSpotInspectionActive && !swap.isMarkingUp)
    swap.handleMapTap(c)
    swap.toggleProfileMode()
    check("entering profile leaves Spot Inspection and drops its reading",
          swap.interactionMode == .transect && swap.inspectionState == .idle)
    swap.toggleSpotInspection()
    check("entering Spot Inspection leaves profile", swap.isSpotInspectionActive && !swap.isProfileModeActive)
    swap.handleMapTap(c)
    swap.toggleFieldMarkup()
    check("entering field markup leaves Spot Inspection and drops its reading",
          swap.isMarkingUp && swap.interactionMode == .explore && swap.inspectionState == .idle)
    swap.isMarkingUp = false
    swap.toggleSpotInspection()
    swap.toggleViewshedMode()
    check("entering viewshed leaves Spot Inspection", swap.interactionMode == .viewshed)

    // The tool each state shows the map's touches (MapTouchPolicy): the canvas is over the map for the pen and the
    // highlighter whatever else is lit.
    let tools = TerrainViewerModel()
    var seen: [MapTool] = [tools.mapTool]
    tools.toggleFieldMarkup(); seen.append(tools.mapTool)                  // pen
    tools.markupTool = .hand; seen.append(tools.mapTool)                    // hand
    tools.toggleFieldMarkup(); tools.markupTool = .pen
    tools.toggleSpotInspection(); seen.append(tools.mapTool)
    tools.toggleProfileMode(); seen.append(tools.mapTool)
    tools.toggleViewshedMode(); seen.append(tools.mapTool)
    tools.interactionMode = .thalweg; seen.append(tools.mapTool)
    tools.interactionMode = .historicalWipe; seen.append(tools.mapTool)
    check("each state's map tool: navigate, markup ink, markup hand, spot, profile, viewshed, thalweg, split wipe",
          seen == [.navigate, .markupInk, .markupHand, .spot, .profile, .viewshed, .thalweg, .splitWipe], "\(seen)")

    // The profile panel's X closes the result and keeps the ruler lit (D2): a finger pans there now, so it is no trap.
    let ruler = TerrainViewerModel()
    ruler.toggleProfileMode()
    ruler.handleMapTap(c)
    ruler.handleMapTap(c2)
    ruler.clearProfile()
    check("closing the profile keeps the ruler lit, ready for a new A", ruler.isProfileModeActive && ruler.profileStart == nil)
}
```

- [x] **Step 2: Stub and see red.** Add `case spotInspection` after `explore` in `InteractionMode`. Add `public var isSpotInspectionActive: Bool { interactionMode == .spotInspection }`, and `public func toggleSpotInspection() { interactionMode = .spotInspection }` (the stub never turns it off and never ends markup). Add `mapTool` (Step 3's body), the `handleMapTap` arm `case .spotInspection: break`, and the top-bar arms listed under Files. Leave `.explore: inspect(coordinate)` and the `didSet`'s `!= .explore` rule as they are. Run `HARNESS_ONLY=2e`. Expected FAILs: "with no tool lit a tap reads nothing", "a tap in Spot Inspection reads the ground …", "turning Spot Inspection off …", "entering Spot Inspection leaves field markup", "entering profile leaves Spot Inspection and drops its reading" (the reading never started), "entering field markup leaves Spot Inspection and drops its reading".

- [x] **Step 3: Implement** in `TerrainViewerModel.swift`:

```swift
    public enum InteractionMode: String, Sendable, CaseIterable {
        /// No tool lit: the map is for moving around; a tap does nothing.
        case explore
        /// Spot Inspection, on until turned off: a tap reads the ground, drags still move the map.
        case spotInspection
        case transect
        case viewshed
        case thalweg
        case historicalWipe
    }

    public var interactionMode: InteractionMode = .explore {
        didSet {
            if interactionMode != .transect { clearProfile() }
            // Only Spot Inspection keeps a reading: turning it off, or picking another tool, drops the callout and pin.
            if interactionMode != .spotInspection { clearInspection() }
            if interactionMode != .viewshed { clearViewshed() }
            if interactionMode != .thalweg { thalwegDraft = [] }
        }
    }

    public var isSpotInspectionActive: Bool { interactionMode == .spotInspection }

    /// Spot Inspection is a tool the user chooses, as the owner asked after taps meant to move the map kept opening
    /// readings. It stays on until turned off. Entering it leaves field markup, as the other tools do.
    public func toggleSpotInspection() {
        if interactionMode == .spotInspection {
            interactionMode = .explore
        } else {
            isMarkingUp = false
            interactionMode = .spotInspection
        }
    }

    /// The tool as the map's touches see it (``MapTouchPolicy``). Markup's pen and highlighter win over everything,
    /// since their canvas covers the map; the hand tool counts only when no other tool is lit.
    public var mapTool: MapTool {
        if isMarkingUp && markupTool != .hand { return .markupInk }
        switch interactionMode {
        case .spotInspection: return .spot
        case .transect: return .profile
        case .viewshed: return .viewshed
        case .thalweg: return .thalweg
        case .historicalWipe: return .splitWipe
        case .explore: return isMarkingUp ? .markupHand : .navigate
        }
    }
```

In `handleMapTap`, replace `case .explore: inspect(coordinate)` with `case .spotInspection: inspect(coordinate)`, and make `case .explore, .thalweg, .historicalWipe: break` (navigating does nothing). Fix the doc comments that say explore inspects.

- [x] **Step 4: Green.** Run `HARNESS_ONLY=Interactive`: 2e passes, and 1–1d and 2–2d still pass. Line 11's "default mode is explore" stays true. Then run the full harness and the UI build check.
- [x] **Step 5: Mutants** (confirm the named check fails, then revert):
  - (a) `.explore: inspect(coordinate)` restored. Expect FAIL on "with no tool lit a tap reads nothing".
  - (b) The `didSet` clears when `!= .explore`. Expect FAIL on "entering field markup leaves Spot Inspection and drops its reading".
  - (c) `toggleSpotInspection` drops `isMarkingUp = false`. Expect FAIL on "entering Spot Inspection leaves field markup".
- [x] **Step 6: Commit** `agent-checkpoint: spot inspection becomes its own tool, on until turned off, and a tap with no tool lit reads nothing (model; the top bar's segment follows in the top bar task); mapTool names the tool for the map's touches; 2e red first, 3 mutants caught`

**Verified by:** the harness (2e) and `xcodebuild`. Not in the Simulator: the tool has no button until Task 7, and a tap still inspects nothing only because `handleMapTap` does nothing. There is nothing device-only here.

**Execution note (efb6532, review fixes ded2b80; harness 1426):** the red run failed 4 of 13, not 6: the two "drops its reading" checks passed on the stub because its Spot Inspection tap started no reading, and an extra mutant (the `didSet` never clearing) showed they bite against the real code. A doc comment was added on `handleMapTap`. The review round made one tap table: `handleMapTap` does what `MapTouchPolicy.tap(in: mapTool, …)` says (the A/B logic moved verbatim into `placeProfilePoint`), so the policy's one-liner for markup's hand tool works, and a tap under markup's pen places nothing; 2e's "drops its reading" checks first confirm a reading landed, and a new check ties the model's tap to the policy in ten states. A short Simulator check (not asked for) showed a tap with no tool lit opening nothing.

---

### Task 3: Model — the Pencil's squeeze and double-tap act only in profile mode, and not at all when set to Off (D1)

**Files:**
- Modify: `LidarExplorer/Presentation/TerrainViewerModel.swift` (`handlePencilDoubleTap` 1041-1049, `handlePencilSqueeze` 1054-1062, the `toggleProfileMode` doc at 1024-1026)
- Modify: `Tools/ViewerHarness/InteractiveAnalysisChecks.swift` (1c's last block, 98-107; 1d, 109-153; new subsection 2f)

- [x] **Step 1: Rewrite the checks that pin the old entry.** In 1c, delete the `plain` block (lines 98-107: "…outside markup enters profile mode" ×2, "…in viewshed mode switches to profile mode"). In 1d, replace the `tap`, `squeeze` and `again` blocks. Keep `quiet` and `drawing`. Add a new function with the following, called after `checkNavigateByDefault()`:

```swift
/// A squeeze or double-tap never lights a tool: measuring is chosen from the top bar (the owner, 2026-09-28). In profile
/// mode they keep their actions; with the Pencil's own setting for the gesture Off they do nothing at all.
@MainActor
private func checkPencilShortcuts() {
    print("\n--- 2f. the Pencil's squeeze and double-tap ---")
    let idle = TerrainViewerModel()
    idle.handlePencilDoubleTap()
    check("a Pencil double-tap with no tool lit lights no tool and names nothing",
          idle.mapTool == .navigate && idle.toolNotice == nil)
    idle.handlePencilSqueeze()
    check("a Pencil squeeze with no tool lit lights no tool and names nothing",
          idle.mapTool == .navigate && idle.toolNotice == nil)

    for (name, light) in [("Spot Inspection", { (m: TerrainViewerModel) in m.toggleSpotInspection() }),
                          ("viewshed", { (m: TerrainViewerModel) in m.toggleViewshedMode() }),
                          ("the split wipe", { (m: TerrainViewerModel) in m.interactionMode = .historicalWipe })] {
        let m = TerrainViewerModel()
        light(m)
        let before = m.mapTool
        m.handlePencilDoubleTap()
        m.handlePencilSqueeze()
        check("in \(name) a Pencil double-tap or squeeze changes nothing and names nothing",
              m.mapTool == before && m.toolNotice == nil)
    }

    let profile = TerrainViewerModel()
    profile.toggleProfileMode()
    profile.handlePencilDoubleTap()
    check("in profile mode a double-tap still hides the earthwork signatures and names it",
          !profile.showsTransectSignatures && profile.toolNotice?.text == "Earthwork Signatures Off")
    profile.handlePencilDoubleTap()
    check("and a second shows them again and names it",
          profile.showsTransectSignatures && profile.toolNotice?.text == "Earthwork Signatures On")
    profile.handlePencilSqueeze()
    check("in profile mode a squeeze still cycles the metric and names it",
          profile.activeProfileMetric == .slope && profile.toolNotice?.text == "Metric: Slope")

    let off = TerrainViewerModel()
    off.toggleProfileMode()
    off.handlePencilDoubleTap(ignored: true)
    off.handlePencilSqueeze(ignored: true)
    check("with the Pencil's double-tap and squeeze set to Off, neither does anything in profile mode, and neither names anything",
          off.showsTransectSignatures && off.activeProfileMetric == .elevation && off.toolNotice == nil)

    // The same words twice are two notices: the pill keys its clock and its VoiceOver announcement on the notice.
    let again = TerrainViewerModel()
    again.postToolNotice("Metric: Slope")
    let first = again.toolNotice
    again.postToolNotice("Metric: Slope")
    let second = again.toolNotice
    check("a Pencil notice in the words of the last is a new notice, so the pill restarts its clock and speaks again",
          first?.text == second?.text && first != second)
    if let first { again.dismissToolNotice(first) }
    check("the pill's clock for an older notice running out leaves the newer one up", again.toolNotice == second)
    if let second { again.dismissToolNotice(second) }
    check("the pill's clock for the notice it shows running out takes it down", again.toolNotice == nil)
}
```

  Fix the comments at 61-62, 70-72 and 84-85 that say a Pencil stroke from markup's hand tool starts a transect. After Task 5 that route is gone. The model checks at 63-68 and 86-97 stay: they pin a state the model still allows.

- [x] **Step 2: Stub and see red.** Add the `ignored: Bool = false` parameters and ignore them. Run `HARNESS_ONLY=2f`. Expected FAILs: the two "with no tool lit …", the three "in … changes nothing …", and "with the Pencil's … set to Off …".
- [x] **Step 3: Implement**

```swift
    /// A Pencil double-tap: in profile mode it shows or hides the earthwork signatures and names what it did in
    /// `toolNotice`. Anywhere else it does nothing and names nothing: measuring is chosen from the top bar, and a
    /// double-tap made while gripping the Pencil for the barrel roll lit the ruler unseen. `ignored` is the Pencil's
    /// own setting for the gesture set to Off (`UIPencilInteraction.preferredTapAction == .ignore`), when it does
    /// nothing anywhere.
    public func handlePencilDoubleTap(ignored: Bool = false) {
        guard !ignored, isProfileModeActive else { return }
        toggleSignaturesOverlay()
        postToolNotice(showsTransectSignatures ? "Earthwork Signatures On" : "Earthwork Signatures Off")
    }

    /// A Pencil Pro squeeze: in profile mode it cycles the profile metric and names it; anywhere else, or with the
    /// Pencil's squeeze set to Off (`preferredSqueezeAction == .ignore`), nothing, as for a double-tap.
    public func handlePencilSqueeze(ignored: Bool = false) {
        guard !ignored, isProfileModeActive else { return }
        cycleProfileMetric()
        postToolNotice("Metric: \(activeProfileMetric.rawValue)")
    }
```

  Update `toggleProfileMode`'s doc, which still mentions a double-tap or squeeze entering profile mode. Leave `TerrainViewerView.swift:314` (a DEBUG hook's notice text) alone, or change it to `"Metric: Slope"`, since it is only a pill to look at.

- [x] **Step 4: Green.** Run `HARNESS_ONLY=Interactive`, then the full harness, then the UI build check. The build still compiles: `TerrainMapView` calls the methods with no argument until Task 5.
- [x] **Step 5: Mutants:**
  - (a) Restore `else if !isMarkingUp { toggleProfileMode(); postToolNotice("Cross-Section Profile") }` in the double-tap. Expect FAIL on "a Pencil double-tap with no tool lit …".
  - (b) Drop `!ignored` from the squeeze. Expect FAIL on "…set to Off…".
- [x] **Step 6: Commit** `agent-checkpoint: a pencil squeeze or double-tap no longer lights the ruler; in profile mode they keep their actions, and they do nothing when the pencil's own setting is off (model; the bridge passes the setting in the map bridge task); 2f red first, old entry checks rewritten, 2 mutants caught`

**Verified by:** the harness (2f) and `xcodebuild`. There is nothing to drive in the Simulator (no Pencil). Device-only: that the setting is read (Task 5 wires it) and how it feels (Task 14's steps).

**Execution note (6ecbd7b, review fixes 722a46e; harness 1430):** 1d's tap, squeeze and notice blocks were deleted rather than rewritten in place, since 2f carries them under the same names (1426 − 11 + 12 = 1427). The double-tap doc says a double-tap "could light the ruler by accident" rather than "unseen" (whether the owner squeezed is inferred). Comment-only edits in `ViewerTopBarView.slidingMode` and the bridge's Pencil comment, which the change had made false. Five mutants, three beyond the plan's two. The review round made 2f's "changes nothing" checks compare the tool, markup, the metric and the signatures, over every tool but profile, and the DEBUG pill hook posts "Metric: Slope".

---

### Task 4: Model — one tool at a time (D7): the split wipe, Remove All, and Settings' thalweg

The wipe's on-state is `historicalWipeFraction != nil` (`ViewerSettingsSheetView.swift:354-365`). With four cluster tools, picking a tool while the wipe is up (probe P4) leaves the wipe's line on screen with its two-finger drag dead. Remove All with the wipe on leaves the wipe's mode with no switch to end it (STATUS open follow-up, `TerrainViewerModel.swift:1313`). Draw River Thalweg leaves markup's canvas over the map (probe P6).

**Files:**
- Modify: `LidarExplorer/Presentation/TerrainViewerModel.swift` (`interactionMode.didSet`, `removeHistoricalMaps` 1313, new `beginThalwegDrawing()` and `setSplitWipe(_:)`, `toggleFieldMarkup` 1873-1876)
- Modify: `LidarExplorer/Presentation/ViewerSettingsSheetView.swift` (283-286: the button calls `model.beginThalwegDrawing()`; 354-365: the toggle's `set` calls `model.setSplitWipe(on)`)
- Modify: `Tools/ViewerHarness/InteractiveAnalysisChecks.swift` (new subsection 2g)

- [x] **Step 1: Checks** (new function, called after `checkPencilShortcuts()`):

```swift
@MainActor
private func checkOneToolAtATime() {
    print("\n--- 2g. one tool at a time ---")
    for (name, pick) in [("the ruler", { (m: TerrainViewerModel) in m.toggleProfileMode() }),
                         ("Spot Inspection", { (m: TerrainViewerModel) in m.toggleSpotInspection() }),
                         ("the eye", { (m: TerrainViewerModel) in m.toggleViewshedMode() }),
                         ("field markup", { (m: TerrainViewerModel) in m.toggleFieldMarkup() })] {
        let m = TerrainViewerModel()
        m.setSplitWipe(true)
        pick(m)
        check("picking \(name) while the split wipe is up ends the wipe", m.historicalWipeFraction == nil,
              "\(String(describing: m.historicalWipeFraction))")
    }
    let removed = TerrainViewerModel()
    removed.setSplitWipe(true)
    removed.removeHistoricalMaps()
    check("Remove All with the split wipe up returns to no tool", removed.mapTool == .navigate)
    let wipeOff = TerrainViewerModel()
    wipeOff.setSplitWipe(true)
    wipeOff.setSplitWipe(false)
    check("turning the Split Wipe switch off returns to no tool", wipeOff.mapTool == .navigate && wipeOff.historicalWipeFraction == nil)
    let wipeOverMarkup = TerrainViewerModel()
    wipeOverMarkup.toggleFieldMarkup()
    wipeOverMarkup.setSplitWipe(true)
    check("turning the split wipe on ends field markup", wipeOverMarkup.mapTool == .splitWipe && !wipeOverMarkup.isMarkingUp)
    let thalweg = TerrainViewerModel()
    thalweg.toggleFieldMarkup()
    thalweg.beginThalwegDrawing()
    check("Draw River Thalweg ends field markup, whose canvas would take the stroke",
          thalweg.mapTool == .thalweg && !thalweg.isMarkingUp)
}
```

- [x] **Step 2: Stub and see red.** Add `setSplitWipe(_ on: Bool) { historicalWipeFraction = on ? 0.5 : nil; if on { interactionMode = .historicalWipe } else if interactionMode == .historicalWipe { interactionMode = .explore } }` (today's Settings logic) and `beginThalwegDrawing() { interactionMode = .thalweg }`. Run `HARNESS_ONLY=2g`. Expected FAILs: the four "picking … ends the wipe", "Remove All …", "turning the split wipe on ends field markup", "Draw River Thalweg ends field markup …".
- [x] **Step 3: Implement**

```swift
    // In interactionMode's didSet, first:
            // The wipe is a tool like the others: leaving its mode takes its line and handle away, rather than leaving
            // them on screen with their two-finger drag dead.
            if oldValue == .historicalWipe, interactionMode != .historicalWipe { historicalWipeFraction = nil }

    /// Settings' Split Wipe switch. On, it is the tool lit, and markup's canvas goes; off, nothing is lit.
    public func setSplitWipe(_ on: Bool) {
        if on {
            isMarkingUp = false
            historicalWipeFraction = 0.5
            interactionMode = .historicalWipe
        } else {
            historicalWipeFraction = nil
            if interactionMode == .historicalWipe { interactionMode = .explore }
        }
    }

    /// Settings' Draw River Thalweg: the channel is traced on the map, so markup's canvas goes, as for every tool.
    public func beginThalwegDrawing() {
        isMarkingUp = false
        interactionMode = .thalweg
    }

    /// With the wipe up, Remove All leaves nothing to wipe and nothing to end the wipe's mode with: it ends that too.
    public func removeHistoricalMaps() {
        historicalMaps = []
        historicalWipeFraction = nil
        if interactionMode == .historicalWipe { interactionMode = .explore }
    }

    // toggleFieldMarkup: entering leaves every tool, the wipe included.
    public func toggleFieldMarkup() {
        isMarkingUp.toggle()
        if isMarkingUp, interactionMode != .explore { interactionMode = .explore }
    }
```

  `toggleFieldMarkup` needs no change: its `interactionMode = .explore` now also ends the wipe through the `didSet`. The existing "entering field markup leaves …" checks cover it. `historicalWipeFraction` (`TerrainViewerModel.swift:1292`) has no `didSet` at e324172, so the writes cannot fight. The planner checked this.

- [x] **Step 4: Green:** the full harness and the UI build check. The Settings view now calls the two methods.
- [x] **Step 5: Mutants:**
  - (a) Drop the `didSet` line. Expect FAIL on the four "picking …".
  - (b) Drop `isMarkingUp = false` from `beginThalwegDrawing`. Expect FAIL on "Draw River Thalweg …".
- [x] **Step 6: Commit** `agent-checkpoint: one tool at a time: picking a tool or markup ends the split wipe, remove all with the wipe up returns to no tool (the stranded-mode bug since 6d6ea20), and draw river thalweg and the split wipe switch end markup; settings calls the model; 2g red first, 2 mutants caught`

**Verified by:** the harness (2g) and `xcodebuild`. In the Simulator, optionally, this can be driven through the DEBUG import hook as in e324172's review, but it is not required. Device: the owner's wipe steps (Task 14).

**Execution note (7fb5936, review fixes 3ee23cd; harness 1444):** code as written. 2g's checks are stricter than the text: each "picking …" check first confirms the wipe was up and then that the picked tool is lit, and the switch-on check that the line is up (0.5); a mutant clearing the wipe on every mode change passed the plan's wording. The red run failed 7 of 8 (the switch-off check passes on today's logic). 2f and 2e light the thalweg and the wipe through the new methods. Six mutants. The Simulator run used a temporary, uncommitted import hook (no DEBUG import hook is committed). The review round routes the wipe's handle and its two-finger drag through the model's `moveSplitWipe(to:)`, which refuses once another tool is lit (`historicalWipeFraction` is now `private(set)`). Seen in the Simulator and left open: a two-finger drag with the wipe up pans the map rather than moving the wipe (older).

---

### Task 5: Map bridge — `TerrainMapView` asks `MapTouchPolicy`, never switches scrolling, never changes the tool (the pan-lock fix)

This task fixes causes 1–3 and 5–8 by construction. Nothing writes `isScrollEnabled`, so one-finger panning cannot be left off. No gesture changes the tool, so a stroke cannot take the map into a mode the user did not pick. The tool is an explicit input, so every tool change re-runs `updateUIView` (cause 6).

**The one unproven mechanism and its gate.** A Pencil stroke in profile mode must draw without MapKit also panning. **Mechanism A (primary):** the draw recognizer's delegate answers `gestureRecognizer(_:shouldBeRequiredToFailBy:)` with `true` for MapKit's pans. UIKit documents this delegate failure requirement as applying across the view hierarchy. MapKit's pan then waits for the draw pan and fails once it draws. The draw pan never receives a finger in profile mode, so a finger pan should not wait. That is **inferred** and is proven in Step 5's Simulator gate. **Mechanism B (fallback, only if the gate fails):** scrolling is off only while a Pencil stroke the draw pan received is down in profile mode, derived by one pure function at every write (spelled out in Step 7). The Pencil already draws that way on the device (the owner drew a 464 m transect).

**Files:**
- Modify: `LidarExplorer/MapLayer/TerrainMapView.swift`. Inputs (29-99), `makeUIView` recognizers (130-160), `updateUIView` (215-217), `Coordinator` (277-307), `gestureRecognizer(_:shouldReceive:)` (695-706), `transectPanDidReset` (708-715), `handleTransectPan` (728-765), `handleTap` (767-771), the Pencil interaction (961-979), `TransectPanGestureRecognizer` (983-996, deleted under A).
- Modify: `LidarExplorer/Presentation/TerrainViewerView.swift` (the `TerrainMapView(` call at 43-64 passes `mapTool: model.mapTool`)
- Modify: `Tools/ViewerHarness/MapTouchPolicyChecks.swift` (new R4, source checks)

- [x] **Step 1: Write R4 first** (add `checkMapBridgeSource()` to `runMapTouchPolicyChecks()`):

```swift
/// The map bridge (not compiled by the harness) read as text, for the two things that made the pan lock: a write to
/// MapKit's scrolling (a Pencil touch turned it off as it landed, and the profile mode kept it off) and a gesture that
/// changes the tool (a Pencil stroke lit the ruler).
@MainActor
private func checkMapBridgeSource() {
    print("\n--- R4. the map bridge never switches scrolling or the tool ---")
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("LidarExplorer/MapLayer/TerrainMapView.swift")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        check("the map bridge's source can be read", false, url.path)
        return
    }
    check("TerrainMapView never writes isScrollEnabled, so no touch can leave one-finger panning off",
          !text.contains("isScrollEnabled"))
    check("TerrainMapView assigns no interactionMode: no gesture changes the tool",
          text.range(of: #"interactionMode\s*=[^=]"#, options: .regularExpression) == nil)
    check("the bridge's recognizers take their touches from MapTouchPolicy",
          ["drawRecognizerReceives", "tapRecognizerReceives", "wipeRecognizerReceives", "rotatesAndPitches",
           "tapWaitsForDoubleTap"].allSatisfy { text.contains("MapTouchPolicy.\($0)") })
}
```

  Run `HARNESS_ONLY=R4`. Expected: all three FAIL at e324172. Under mechanism B, the first check becomes "`isScrollEnabled` is written in exactly one place, `applyScrolling()`" (`text.components(separatedBy: "isScrollEnabled").count - 1 == 1`, plus R3 gains the B checks in Step 7).

- [x] **Step 2: The tool as an input.** In `TerrainMapView`, add `let mapTool: MapTool` with a doc: "The tool lit, so that picking one re-runs `updateUIView` (a change to a model value read only inside `updateUIView` is not tracked; see the type's header)". Add `mapTool: MapTool = .navigate` to `init`. In `TerrainViewerView.swift:43-64`, pass `mapTool: model.mapTool`.

- [x] **Step 3: Rewrite the recognizers and the delegate (mechanism A).**

  In `makeUIView`:
```swift
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        // Its touches come from MapTouchPolicy: with no tool lit it never sees one (a tap used to inspect).
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
        context.coordinator.tapRecognizer = tap

        // The profile's Pencil stroke and the thalweg's trace. It receives only the touches that draw
        // (MapTouchPolicy.drawRecognizerReceives), and MapKit's pan waits for it (shouldBeRequiredToFailBy), so a stroke
        // never moves the map and nothing ever switches MapKit's scrolling.
        let drawPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTransectPan(_:)))
        drawPan.maximumNumberOfTouches = 1
        drawPan.delegate = context.coordinator
        map.addGestureRecognizer(drawPan)
        context.coordinator.drawPanRecognizer = drawPan
```
  Delete `TransectPanGestureRecognizer`, its `onReset`, and `transectPanDidReset()`.

  In `updateUIView`, replace 215-217 with:
```swift
        // Two fingers rotate and pitch where the tool leaves them free (MapTouchPolicy). One-finger scrolling is never
        // switched: it is MapKit's in every tool, and a stroke keeps it off the map by MapKit's pan waiting on it.
        let turns = MapTouchPolicy.rotatesAndPitches(in: mapTool)
        if map.isRotateEnabled != turns { map.isRotateEnabled = turns }
        if map.isPitchEnabled != turns { map.isPitchEnabled = turns }
```

  In `Coordinator`, beside `wipePanRecognizer`:
```swift
        weak var tapRecognizer: UITapGestureRecognizer?
        weak var drawPanRecognizer: UIPanGestureRecognizer?

        private func kind(of touch: UITouch) -> MapTouchKind {
            switch touch.type {
            case .direct: .finger
            case .pencil: .pencil
            default: .pointer     // .indirect, .indirectPointer: a trackpad or a mouse, which acts as a finger does
            }
        }

        /// Which recognizer sees a touch, from MapTouchPolicy and nothing else. It has no side effects: it used to turn
        /// MapKit's scrolling off for every Pencil touch as it landed.
        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            let tool = model.mapTool
            if gestureRecognizer === wipePanRecognizer { return MapTouchPolicy.wipeRecognizerReceives(in: tool) }
            if gestureRecognizer === drawPanRecognizer {
                return MapTouchPolicy.drawRecognizerReceives(in: tool, by: kind(of: touch))
            }
            if gestureRecognizer === tapRecognizer {
                // A tap on a pin is the pin's (its callout, the observer's drag), not a reading or a point beneath it.
                return MapTouchPolicy.tapRecognizerReceives(in: tool, by: kind(of: touch)) && !Self.isOnAnnotation(touch.view)
            }
            return true
        }

        /// MapKit's own pans wait for a stroke the draw pan has taken, and fail once it draws. A touch the draw pan never
        /// receives (every finger in profile mode) is not waited on.
        public func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer === drawPanRecognizer && other is UIPanGestureRecognizer
                && other !== drawPanRecognizer && other !== wipePanRecognizer
        }

        /// In profile mode a tap waits for MapKit's double-tap zoom to fail (D5), so a zoom never places A and B at one point.
        public func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer
        ) -> Bool {
            guard gestureRecognizer === tapRecognizer, let double = other as? UITapGestureRecognizer,
                  double.numberOfTapsRequired == 2 else { return false }
            return MapTouchPolicy.tapWaitsForDoubleTap(in: model.mapTool)
        }

        private static func isOnAnnotation(_ view: UIView?) -> Bool {
            var current = view
            while let v = current {
                if v is MKAnnotationView { return true }
                current = v.superview
            }
            return false
        }
```

  `handleTransectPan`: remove the `interactionMode =` line (753) and every `isScrollEnabled` write (741, 745, 761). Start the line where the tip landed:
```swift
        @objc func handleTransectPan(_ recognizer: UIPanGestureRecognizer) {
            guard let map = mapView else { return }
            let point = recognizer.location(in: map)
            let coord = map.convert(point, toCoordinateFrom: map)
            switch model.interactionMode {
            case .thalweg:
                switch recognizer.state {
                case .began, .changed:
                    model.extendThalwegDraft(coord); syncThalweg(on: map)
                case .ended:
                    model.extendThalwegDraft(coord); model.commitThalwegDraft(); syncThalweg(on: map)
                case .cancelled:
                    model.commitThalwegDraft(); syncThalweg(on: map)
                default: break
                }
            case .transect:
                switch recognizer.state {
                case .began:
                    // A pan begins some points along the stroke; the line starts where the tip landed.
                    let moved = recognizer.translation(in: map)
                    let landing = CGPoint(x: point.x - moved.x, y: point.y - moved.y)
                    model.beginTransectDrag(at: map.convert(landing, toCoordinateFrom: map))
                case .changed:
                    guard model.isTransectDragging else { return }
                    model.updateTransectDrag(to: coord); syncProfile(on: map)
                case .ended, .cancelled:
                    guard model.isTransectDragging else { return }
                    model.endTransectDrag(to: coord); syncProfile(on: map)
                default: break
                }
            default:
                // The tool changed under the stroke (the top bar tapped with another finger): the stroke does nothing,
                // and never lights a tool.
                break
            }
        }
```

  `handleTap`: unchanged. A discrete recognizer calls it once, when recognised, and it dispatches to `model.handleMapTap`. Task 2 made navigate a no-op there, so the model is safe even if a tap got through.

  The Pencil interaction (D1):
```swift
        public func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            // The Pencil's own setting for a double-tap, in the iPad's Settings > Apple Pencil: Off means nothing here.
            let ignored = UIPencilInteraction.preferredTapAction == .ignore
            Task { @MainActor in model.handlePencilDoubleTap(ignored: ignored) }
        }

        public func pencilInteraction(
            _ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
        ) {
            guard squeeze.phase == .ended else { return }
            let ignored = UIPencilInteraction.preferredSqueezeAction == .ignore
            Task { @MainActor in model.handlePencilSqueeze(ignored: ignored) }
        }
```
  Keep the `@available(iOS 17.5, *)` if the compiler asks for it. The deployment target is iOS 27. If the SDK marks `pencilInteractionDidTap(_:)` deprecated, implement `pencilInteraction(_:didReceiveTap:)` instead. Confirm against the SDK and keep 0 warnings. Whether `.runSystemShortcut` ever reaches the app is for the implementer to read in the SDK docs. If it does, treat it as ignored too.

  Rewrite the file's header comments, the `// MARK: - Gestures` notes and the comments near 695-715 to describe the new rule.

- [x] **Step 4: Green on the host and in the build.** Run `HARNESS_ONLY=MapTouch` (R1–R4 pass), then the full harness, the UI build check, and a device build (`generic/platform=iOS`, 0 warnings).

- [x] **Step 5: Simulator gate for mechanism A** (only with the orchestrator's go-ahead to use the Simulator). Add a temporary, **uncommitted** DEBUG hook in `kind(of:)`: `#if DEBUG if ProcessInfo.processInfo.environment["TEST_TOUCHES_AS_PENCIL"] == "1" { return .pencil } #endif`. Also add a temporary log line (`Log.ui.debug("NBD-LOG region …")` in `regionDidChangeAnimated`) so the map's motion shows in `xcrun simctl spawn 1E25EA1A-124E-48BF-BDFB-EC688EB84934 log stream --predicate 'eventMessage CONTAINS "NBD-LOG"'`. Build, install and launch (Hillshade). With the control tool:
  - (a) Hook off, no tool lit. Tap the map: no callout, and the readout is unchanged. `swipe` 200 pt: the map moves (log, and screenshots before and after).
  - (b) Hook off, ruler lit (tap the ruler segment; its position is at the top bar's cluster, found from a screenshot). `swipe`: the map pans at once, no line is drawn, and the ruler stays lit. `tap` twice at two points: A and B are placed, and the profile panel opens after ≈0.25 s per tap (D5). Tap the panel's X: the panel goes and the ruler stays lit. `swipe`: the map pans (**the lock is gone**).
  - (c) Hook on (`SIMCTL_CHILD_TEST_TOUCHES_AS_PENCIL=1`), ruler lit. `touch_path` from (400, 700) to (700, 700) over 1 s: a line is drawn that **starts at (400, 700)**, and the region log shows **no** move during the stroke. This is the gate: MapKit's pan waited and failed.
  - (d) Hook on, no tool lit. `swipe`: the map pans, because the draw pan did not receive the touch. Hook on, eye lit: `swipe` pans, and the eye stays lit (no silent switch to profile).
  - (e) Hook off: ruler on, then the eye, then `swipe`. The map pans (cause 6).
  - (f) Spot: without Task 7 there is no button. Add a temporary DEBUG launch hook `TEST_SPOT_ON=1` in `TerrainViewerView`'s DEBUG block that calls `model.toggleSpotInspection()`, or run this after Task 7. Taps read and drags pan. A tap on the spot pin does not re-read (the readout keeps the value).
  - **Pass:** (c) draws with no map move, and (b) pans with no visible delay compared with (a). **Fail:** the map moves under (c), or (b)'s finger pan starts only once the finger lifts. Then go to Step 7.
  - Save screenshots and the log under `build-review/navigate-by-default/task5/`. Remove both hooks and confirm with `git diff`.

- [x] **Step 6: Mutants** (the host can catch only the source rules):
  - (a) Re-add `mapView?.isScrollEnabled = false` in `shouldReceive`. Expect FAIL on R4 "never writes isScrollEnabled".
  - (b) Re-add `if model.interactionMode != .transect { model.interactionMode = .transect }` in `.began`. Expect FAIL on R4 "assigns no interactionMode".
  - Revert both.

- [ ] *Not needed: Step 5's gate passed, so mechanism A shipped and nothing below was built.* **Step 7: Fallback, mechanism B (only if Step 5's gate failed).** Keep everything above except `shouldBeRequiredToFailBy`, and add the following:
  - In `MapTouchPolicy`: `public static func scrolls(in tool: MapTool, pencilStroking: Bool) -> Bool { switch tool { case .thalweg: false; case .profile: !pencilStroking; default: true } }`.
  - R3 gains: "one finger scrolls in every tool but the thalweg; in profile only while no Pencil stroke is down".
  - R4's first check changes as Step 1 says.
  - In the coordinator: `private var pencilStroking = false`, and `func applyScrolling() { let on = MapTouchPolicy.scrolls(in: model.mapTool, pencilStroking: pencilStroking); if mapView?.isScrollEnabled != on { mapView?.isScrollEnabled = on } }`. When `shouldReceive` returns true for a `.pencil` touch in `.profile`, it sets `pencilStroking = true; applyScrolling()`. A `UIPanGestureRecognizer` subclass whose `reset()` sets `pencilStroking = false; applyScrolling()` (the old `TransectPanGestureRecognizer`) comes back. `updateUIView` calls `coordinator.applyScrolling()`.
  - Scrolling is then off only for the life of one Pencil touch in profile mode, and every write goes through one pure rule.
  - Re-run Step 5 (c) and (b).

- [x] **Step 8: Commit** `agent-checkpoint: the map's touches follow maptouchpolicy (the pan-lock fix): no touch switches mapkit's scrolling or changes the tool, a pencil drag with no tool lit pans the map, the ruler takes taps for a and b and a pencil stroke for the line (starting where the tip landed) while a finger pans, taps wait for a double-tap zoom only in profile mode, a tap on a pin is the pin's, the tool is an explicit input, and the pencil's own off setting is honoured; r4 red first; simulator: <what (a)-(f) showed>; mechanism <a|b>`

**Verified by:**
- Harness: R1–R4.
- `xcodebuild`: simulator and device builds.
- Simulator: (a)–(f) above, with the uncommitted Pencil hook. It proves that the failure requirement holds against MapKit's real pan, and that a finger pan is not delayed.
- **Device only** (Task 14): the Pencil panning the map with no tool lit (MapKit's pan with real Pencil touches), a real Pencil stroke in profile mode not moving the map, a palm resting during a stroke, a double-tap zoom in profile mode placing nothing (the Simulator cannot inject it fast enough), the Settings > Apple Pencil Off choices, and the owner's own sequence that locked the map.

**Execution note (720731d, review fixes 43be73c and 6fa73d6; harness 1466):** mechanism A passed the gate: a Pencil-hooked stroke in profile drew with no region change at all and A started at the landing point, and a finger panned in profile 0.08 s after touch-down. Departures: (1) `point − translation` did not recover the landing (the pan began at the stroke's second sample with a translation of 0, so A fell 15 pt short), so a small `DrawPanGestureRecognizer` records where its touch came down and `.began` starts the line there; it does nothing else. (2) The SDK deprecates `pencilInteractionDidTap(_:)`, so the double-tap is `pencilInteraction(_:didReceiveTap:)`; the squeeze needed no `@available`. (3) `.runSystemShortcut` is not read: a squeeze set to run a shortcut never reaches the app. (4) The profile tap's wait measured 0.35–0.37 s, not 0.25. The review rounds: only the reading's pin, the observer and a waypoint swallow a tap (A's and B's balloons and the location dot pass it through); a tap recognised while a stroke draws does nothing; every tap and stroke point goes through `ground(at:on:)`, which drops a point above a pitched map's horizon, found from `visibleMapRect` by the host-compiled `MapTouchPolicy.horizonRow` and `touchHasGround` (R5), because MapKit converts a sky point to a valid coordinate far beyond its ground; the thalweg's trace starts where the finger landed; MapKit's one-finger zoom (`_MKOneHandedZoomGestureRecognizer`, matched by name) waits for a stroke; R4 widened to any write of the tool's state. Found: in the thalweg two fingers pan and pinch the map (D8 holds for one-touch drags). The holistic review (acfda68) made a profile tap with a line shown also wait for the one-finger zoom, and kept the channel when a thalweg trace finds no ground. Device-only additions: a Pencil tip resting still in profile mode holds every finger pan until it lifts or draws; with no line or only A shown, a one-finger zoom's first tap still places A or B.

---

### Task 6: Model — the readout's words for every tool (D4), host-compiled

"The readout" is the capsule at the top bar's left. Its words move from `ViewerTopBarView.readoutText` (164-206) to the model, so the harness checks each tool's words. The view keeps the icon.

**Files:**
- Modify: `LidarExplorer/Presentation/TerrainViewerModel.swift` (new `Readout` and `readout`)
- Modify: `Tools/ViewerHarness/InteractiveAnalysisChecks.swift` (new subsection 2h)

- [x] **Step 1: Checks** (new function, called after `checkOneToolAtATime()`). Build a model for each state and assert `(readout.text, readout.isPlaceholder)`:
  - navigate: ("Pick a tool to measure", true)
  - markup pen: ("Draw on the map", true)
  - markup hand: ("Move the map", true)
  - spot idle: ("Tap map for elevation", true)
  - spot after a tap: ("Reading ground…", false)
  - profile idle: ("Tap Point A on map", false)
  - profile after one tap: ("Tap Point B on map", false)
  - profile mid-drag (`beginTransectDrag`): ("Drawing transect…", false)
  - viewshed idle: ("Tap map for observer", false)
  - thalweg: ("Drag along channel", false)
  - split wipe: ("Drag split wipe to compare", false)

  Add "none of the new words is longer than the 22 characters `readableReadoutWidth` was sized for" (`ViewerTopBarView.swift:21-25`), computed over the navigate, markup and profile texts. Some older texts are longer ("Drag split wipe to compare" is 26, the observer's 34) and are out of this check. The elevation value, "No coverage here" and "Elevation unavailable" need a landed lookup. The existing inspect path's states can be set only through `inspect`, so cover them by reading `readout` for a model whose `inspectionState` is reached through the harness's synthetic scene, if one is cheap. Otherwise state in the commit that those three are unchanged strings moved verbatim.
- [x] **Step 2: Stub and see red.** Add `public nonisolated struct Readout: Equatable, Sendable { public let text: String; public let isPlaceholder: Bool }` and `public var readout: Readout { Readout(text: "", isPlaceholder: false) }`. Run `HARNESS_ONLY=2h`: every check fails.
- [x] **Step 3: Implement**

```swift
    /// What the readout, the capsule at the top bar's left, says for the tool lit: its words, and whether they are a
    /// prompt (drawn secondary) rather than a reading. Host-compiled so the harness checks each tool's words.
    public nonisolated struct Readout: Equatable, Sendable {
        public let text: String
        public let isPlaceholder: Bool
    }

    public var readout: Readout {
        switch mapTool {
        case .navigate: return Readout(text: "Pick a tool to measure", isPlaceholder: true)
        case .markupInk: return Readout(text: "Draw on the map", isPlaceholder: true)
        case .markupHand: return Readout(text: "Move the map", isPlaceholder: true)
        case .spot:
            switch inspectionState {
            case .idle: return Readout(text: "Tap map for elevation", isPlaceholder: true)
            case .loading: return Readout(text: "Reading ground…", isPlaceholder: false)
            case .elevation(let e, _): return Readout(text: formattedElevation(e), isPlaceholder: false)
            case .noCoverage: return Readout(text: "No coverage here", isPlaceholder: false)
            case .failed: return Readout(text: "Elevation unavailable", isPlaceholder: false)
            }
        case .profile:
            let text = if isGeneratingProfile { "Calculating profile…" }
                else if isTransectDragging { "Drawing transect…" }
                else if profileStart == nil { "Tap Point A on map" }
                else if profileEnd == nil { "Tap Point B on map" }
                else { "Transect sampled" }
            return Readout(text: text, isPlaceholder: false)
        case .viewshed:
            let text = if isComputingViewshed { "Computing viewshed…" }
                else if viewshedObserverCoordinate == nil { "Tap map for observer" }
                else { "Observer placed (drag pin to move)" }
            return Readout(text: text, isPlaceholder: false)
        case .thalweg: return Readout(text: thalwegDraft.isEmpty ? "Drag along channel" : "Tracing thalweg…", isPlaceholder: false)
        case .splitWipe: return Readout(text: "Drag split wipe to compare", isPlaceholder: false)
        }
    }
```
- [x] **Step 4: Green:** the full harness and the UI build check (nothing reads `readout` yet).
- [x] **Step 5: Mutants:**
  - (a) navigate returns "Tap map for elevation". Expect FAIL on the navigate line.
  - (b) The profile's drag branch is removed. Expect FAIL on "mid-drag …".
- [x] **Step 6: Commit** `agent-checkpoint: the readout's words for every tool, host-compiled and checked: "pick a tool to measure" with none lit, markup's own words (audit finding 17), "tap point a on map" and "drawing transect…" for the ruler; 2h red first`

**Verified by:** the harness (2h) and `xcodebuild`. The words are seen on screen in Task 7.

**Execution note (10966d8, review fixes c5a3b50; harness 1490):** code as written. 2h went beyond the list: three more in-progress states ("Calculating profile…", "Computing viewshed…", "Tracing thalweg…") and, over the harness's synthetic scene, the landed states (a reading, "No coverage here", "Elevation unavailable", "Transect sampled", "Observer placed (drag pin to move)"), so no string is left "moved verbatim" and unchecked. The 22-character check reads the seven texts of the navigate, markup and profile states. The review round made a new A, or a Pencil stroke, supersede the profile still being worked out (`supersedeProfileWork()` cancels its task and clears `isGeneratingProfile`), so the readout says "Tap Point B on map" or "Drawing transect…" at once and the old line's profile never lands over them.

---

### Task 7: Top bar — the Spot Inspection segment, the readout from the model, and room on a phone

**Files:**
- Modify: `LidarExplorer/Presentation/ViewerTopBarView.swift` (header 5-6; body 44-69; `controls` 98-113; capsule 117-156; `isPlaceholder`/`readoutText` 158-206, deleted; `Mode`/`slidingMode`/`modeCluster` 244-287)

- [x] **Step 1: The segment.**
  - `private enum Mode { case spot, profile, viewshed, markup }`.
  - `slidingMode`: `case .spotInspection: .spot`.
  - First in `modeCluster`: `modeSegment("Spot Inspection", mode: .spot, icon: "scope", selectedIcon: "scope", selected: model.isSpotInspectionActive) { model.toggleSpotInspection() }`. There is no filled `scope` symbol (`build-review/feedback-investigation/interaction-model/symbol-probe.out`). The lit state is the white glyph on the accent capsule.
  - Update the comments that say "three" modes (lines 5-6, 263) and the `slidingMode` comment about a Pencil stroke making a transect under markup, a route Task 5 removed.
- [x] **Step 2: The readout.** `Text(model.readout.text)` with `.foregroundStyle(model.readout.isPlaceholder ? .secondary : .primary)`. Delete `isPlaceholder` and `readoutText`. The icon switches on `model.mapTool`:
  - `.spot`: a `ProgressView` while `.loading`, otherwise `scope` in `.teal` (the pin's and the callout's colour).
  - `.profile`: as now.
  - `.thalweg` and `.splitWipe`: as now.
  - `.markupInk` and `.markupHand`: `pencil.tip.crop.circle` in `.tint`.
  - `.navigate` and `.viewshed`: `mountain.2.fill` in `.tint`, as now.
- [x] **Step 3: Room on a phone** (cause 15). With four segments the controls are 350 pt at 10 pt spacing: 3 × 44 + 3 × 10 + (4 × 46 + 4). In the two-row layout the first row also carries `Spacer(minLength: 8)` and a 10 pt gap, 368 pt against 343 pt inside the margins of a 375 pt phone.
  - Under `@Environment(\.horizontalSizeClass) == .compact`, set the `controls` HStack spacing to 6 (338 pt).
  - When `!fitsOneRow`, drop the Spacer from the first row. Keep `controls` as the row's last child so its identity holds (the file's comment at 45-46), and give the row `.frame(maxWidth: .infinity, alignment: .trailing)`.
  - Keep `fitsOneRow`'s arithmetic consistent: its `28` is the spacer minimum plus two gaps, so rewrite it from the actual spacing.
- [x] **Step 4: Build and Simulator** (with the go-ahead):
  - Screenshots at the 13-inch, landscape and portrait, and portrait with the Map Styles Guide open.
  - Tap each of the four segments: one is lit at a time, the readout's words match 2h, and "Spot Inspection" then a map tap opens the callout and the teal icon.
  - Find the narrowest iPhone available (`xcrun simctl list devices available | grep iPhone`), then build and run on it in portrait: the row fits with nothing clipped, and the readout takes its own row.
  - Optionally, an iPad window at its narrowest.
  - Save the screenshots under `build-review/navigate-by-default/task7/`.
- [x] **Step 5: Commit** `agent-checkpoint: the top bar gains the spot inspection segment (scope, first in the cluster), the readout shows the model's words and a teal scope in spot inspection, and the row fits a 375 pt phone with four segments (6 pt spacing on compact width, no spacer when the readout has its own row); simulator screenshots at 13-inch and <iphone>`

**Verified by:**
- `xcodebuild`.
- Simulator screenshots and taps, as above.
- **Device only:** VoiceOver reading "Spot Inspection" as a switch button (checklist step 11 (a)), and the feel of the segment under the Pencil and a finger.

**Execution note (c04c64e, review fixes 8ff4ab4; harness 1509):** no landscape screenshot: the Simulator runs headless and the scene refused a programmatic rotation (UISceneErrorDomain 101). The narrowest iPhone available was the 17e (390 pt), so the 375 pt fit is arithmetic (338 against 343 pt). The review round moved the bar's arithmetic into host-compiled `TopBarLayout` (Y1/Y2, 19 checks): the buttons' gap follows the bar's room rather than the size class, and in the narrowest iPad windows the bar drops below iPadOS's window controls (measured in the Simulator), so My location is no longer under them. A bar under 338 pt (a 320 pt Slide Over) still overflows, as the plan's out-of-scope list says.

---

### Task 8: The sun dial re-lights the map during a drag (a leading+trailing throttle)

Cause 9. The fix follows the haptics-dial investigation's model (`build-review/feedback-investigation/haptics-dial/dial-probe/`). At 50 ms it gives about 30 re-shades per 1.5 s at every drag speed, gaps of 50 ms or less, and the first re-shade 16 ms after touch-down. The roll the owner approved produces more than that. 50 ms keeps each write well outside `pushSettings`' 16 ms restart window (`TerrainViewerModel.swift:645-658`).

**Files:**
- Modify: `LidarExplorer/Presentation/DialGeometry.swift` (new `SunDialCommit`; already in `SOURCES`)
- Modify: `Tools/ViewerHarness/DialGeometryChecks.swift` (new X1 subsection)
- Modify: `LidarExplorer/Presentation/ShadingDockView.swift` (16-21, 316-343)

- [x] **Step 1: Checks** (new function in `DialGeometryChecks.swift`, called at the end of `runDialGeometryChecks()`):

```swift
/// Runs (time, bearing) samples through a commit, firing each trailing write at its due time: the writes made.
private func sunWrites(_ samples: [(t: Double, deg: Double)], interval: Double = 0.05) -> [(t: Double, deg: Double)] {
    var commit = SunDialCommit(interval: interval)
    var writes: [(t: Double, deg: Double)] = []
    var due: Double?
    for s in samples {
        if let d = due, d <= s.t { due = nil; if let v = commit.fireTrailing(at: d) { writes.append((d, v)) } }
        switch commit.sample(s.deg, at: s.t) {
        case .write(let v): writes.append((s.t, v))
        case .scheduleTrailing(let d): due = d
        case .none: break
        }
    }
    if let d = due, let v = commit.fireTrailing(at: d) { writes.append((d, v)) }
    return writes
}

@MainActor
private func checkSunDialCommit() {
    print("\n--- X1. the dial's writes to the map's sun ---")
    func drag(hz: Double, degreesPerSecond: Double, seconds: Double = 1.5) -> [(t: Double, deg: Double)] {
        stride(from: 0.0, to: seconds, by: 1 / hz).map { ($0, (100 + degreesPerSecond * $0).truncatingRemainder(dividingBy: 360)) }
    }
    func maxGap(_ w: [(t: Double, deg: Double)]) -> Double { zip(w, w.dropFirst()).map { $1.t - $0.t }.max() ?? .infinity }
    for (hz, speed) in [(120.0, 90.0), (120.0, 360.0), (240.0, 90.0), (60.0, 20.0)] {
        let w = sunWrites(drag(hz: hz, degreesPerSecond: speed))
        check("a drag sampled at \(Int(hz)) Hz turning \(Int(speed))°/s writes the sun at least every 50 ms while it moves",
              w.count >= 25 && maxGap(w) <= 0.05 + 1 / hz + 1e-9, "\(w.count) writes, max gap \(maxGap(w))")
    }
    let first = sunWrites([(0, 200.0)])
    check("the first sample of a drag writes at once", first.count == 1 && first[0].t == 0)
    let wander = sunWrites([(0, 100.2), (0.06, 100.3), (0.12, 99.8), (0.18, 100.4)])
    check("samples wandering within the whole degree last written write nothing more", wander.count == 1, "\(wander)")
    var c = SunDialCommit(interval: 0.05)
    _ = c.sample(10, at: 0)
    let armed = c.sample(12, at: 0.01)
    _ = c.sample(14, at: 0.02)
    check("newer samples never move the trailing write later", armed == .scheduleTrailing(at: 0.05) && c.trailingDue == 0.05)
    check("the trailing write carries the newest bearing, not the one that armed it", c.fireTrailing(at: 0.05) == 14)
    check("a bearing that is not a number is ignored", c.sample(.nan, at: 1) == SunDialCommit.Step.none)
    c.reset()
    check("after a lift the next drag's first sample writes at once", c.sample(50, at: 1.001) == .write(50))
}
```

- [x] **Step 2: Stub (today's restart debounce) and see red.** Give `SunDialCommit` Step 3's API, with `sample` always setting `pending = degrees` and returning `.scheduleTrailing(at: now + interval)`, and `fireTrailing` returning `pending`. Run `HARNESS_ONLY=X1`. Expected FAILs: the four "a drag sampled …" (each gets 1 write, at the end), "the first sample of a drag writes at once", "newer samples never move …". "Samples wandering …" passes against this stub (it writes once at the end). Mutant (c) in Step 6 is what makes that check bite.
- [x] **Step 3: Implement** (in `DialGeometry.swift`, after `DialGeometry`):

```swift
/// When a drag on the sun dial writes the map's sun (`TerrainViewerModel.azimuth`, which re-shades every tile on screen).
///
/// A leading and trailing throttle. A new whole degree is written at once when the last write is at least `interval`
/// old. Otherwise the newest bearing waits for one trailing write, due `interval` after the last, which later samples
/// update but never postpone. The debounce this replaces restarted its 60 ms wait on every sample, and a drag samples
/// every 8 to 17 ms, so the map re-lit only when the drag paused or lifted (the owner's report of 2026-09-28; the
/// barrel roll, which writes whole degrees, re-lit throughout). The dial writes the exact bearing on lift, as before.
public nonisolated struct SunDialCommit: Sendable {
    public enum Step: Equatable, Sendable {
        /// Write this bearing now.
        case write(Double)
        /// Hold it: write what ``fireTrailing(at:)`` returns at this time.
        case scheduleTrailing(at: TimeInterval)
        /// Nothing to do: the whole degree last written, a bearing that is not a number, or one a trailing write covers.
        case none
    }

    public let interval: TimeInterval
    private var lastWrite: TimeInterval?
    private var lastWholeDegree: Int?
    private var pending: Double?
    public private(set) var trailingDue: TimeInterval?

    public init(interval: TimeInterval = 0.05) { self.interval = interval }

    public mutating func sample(_ degrees: Double, at now: TimeInterval) -> Step {
        guard degrees.isFinite else { return .none }
        let whole = DialGeometry.wholeDegrees(degrees)
        // Back on the degree the map already shows: nothing is owed, not even a trailing write of an older bearing.
        guard whole != lastWholeDegree else { pending = nil; return .none }
        if let last = lastWrite, now >= last, now - last < interval - 1e-9 {
            pending = degrees
            guard trailingDue == nil else { return .none }
            trailingDue = last + interval
            return .scheduleTrailing(at: last + interval)
        }
        lastWrite = now
        lastWholeDegree = whole
        pending = nil
        return .write(degrees)
    }

    /// The trailing write came due: the bearing to write, or nil when nothing is owed any more.
    public mutating func fireTrailing(at now: TimeInterval) -> Double? {
        trailingDue = nil
        guard let value = pending else { return nil }
        pending = nil
        lastWrite = now
        lastWholeDegree = DialGeometry.wholeDegrees(value)
        return value
    }

    /// The drag ended: the next one starts afresh.
    public mutating func reset() { self = SunDialCommit(interval: interval) }
}
```

- [x] **Step 4: Wire the dock.** In `ShadingDockView`:
  - Replace `debounceTask` with `@State private var sunCommit = SunDialCommit(interval: 0.05)` and `@State private var trailingTask: Task<Void, Never>?`.
  - Rewrite the doc at 16-18.
  - In `onChanged`, keep `localAzimuth = degrees` and the `azimuthSnap` haptic, then:
  ```swift
                switch sunCommit.sample(degrees, at: ProcessInfo.processInfo.systemUptime) {
                case .write(let value):
                    model.azimuth = value
                case .scheduleTrailing(let due):
                    trailingTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(max(0, due - ProcessInfo.processInfo.systemUptime)))
                        guard !Task.isCancelled, let value = sunCommit.fireTrailing(at: ProcessInfo.processInfo.systemUptime)
                        else { return }
                        model.azimuth = value
                    }
                case .none:
                    break
                }
  ```
  - In `onEnded`: `trailingTask?.cancel(); sunCommit.reset(); model.azimuth = localAzimuth` (the exact bearing), then the rest as now.
  - The `.onChange(of: model.azimuth)` resync stays guarded by `!isDraggingSun` (76-79), so the dial's own writes do not feed back.
- [x] **Step 5: Green:** the full harness and the UI build check.
- [x] **Step 6: Mutants:**
  - (a) Restart the deadline on each sample (set `trailingDue` every time). Expect FAIL on "a drag sampled …".
  - (b) `pending` is set only when scheduling. Expect FAIL on "the trailing write carries the newest bearing …".
  - (c) Drop the whole-degree guard. Expect FAIL on "samples wandering …".
- [x] **Step 7: Simulator** (with the go-ahead). Add a temporary, uncommitted `NBD-LOG sun <deg>` log in `azimuth`'s `didSet`. With Hillshade, `touch_path` round the dial (its centre is from a screenshot; 24 points on a circle of radius 30 pt, `dt_ms` 60, about 1.4 s). The log shows sun writes throughout the drag, about 20 a second, not one at the end. A screenshot right after shows the terrain lit from the end bearing. Remove the log.
- [x] **Step 8: Commit** `agent-checkpoint: the sun dial re-lights the map while it is dragged: a leading and trailing 50 ms throttle of whole degrees (sundialcommit) in place of a 60 ms debounce that every sample restarted, so a moving drag never wrote the sun until it lifted; x1 red against the old debounce, 3 mutants caught; simulator: <n> writes over a 1.4 s drag`

**Verified by:**
- Harness: X1.
- `xcodebuild`.
- Simulator: the log count during an injected drag.
- **Device only:** that it feels like the roll with the Pencil and with a finger, and whether heavy products (LRM with a Raking Light blend, z19–z20) keep up. Stale tiles stay drawn, so the worst case is a partial re-light, not a blank.

**Execution note (63c1a18, review fixes 907b0af; holistic fix acfda68; harness 1525 at 907b0af):** X1 has 11 checks (one added for a `reset()` that does nothing), and the red run failed 10 of 11, not 6: the plan's "samples wandering" samples are 60 ms apart, past the interval, so the stub failed it too. In the Simulator the plan's 24-point path does not tell old from new (the old debounce raced 60 ms samples), so a dense 16 ms path was added: 33 writes over 1.68 s against 1 at lift before. The review round replaced the whole-degree rule with a 1° deadband from the bearing last written (a finger or the Pencil resting near a half degree had re-shaded the map up to 20 times a second), and a leading write voids a late trailing one (X1, 16 checks). The Simulator could not show a mid-drag re-light: its CPU shading takes 3–4 s a screen, so nothing landed while the dial moved. The holistic review traced the cause (its major: a continuous drag stopped re-lighting after about half a second): every write's reload cancelled the tile loads under way and dropped what they had shaded, so a re-shade slower than the gap between two writes never landed. acfda68 makes a shading reload keep the load of a tile it still draws, draw what it shades when it lands and ask for the tile again under the newest settings, so a dial dragged on re-lights throughout at the provider's pace (Simulator: 14 frames of change over a 175° drag, the longest stretch with none 0.57 s, against 3 and 2.47 s before; B12 updated, B16 new).

---

### Task 9: The sun dial while a profile is shown (D6)

Cause 14. The owner decided that the sun dial always works, but the profile panel replaces the dock (`TerrainViewerView.swift:177-183`).

**Files:**
- Create: `LidarExplorer/Presentation/SunDialControl.swift`. It holds the dial's state and commit, moved out of `ShadingDockView`: `localAzimuth`, `sunCommit`, `trailingTask`, the begin/snap/end haptics, the `onAppear` sync and the guarded `onChange(of: model.azimuth)`.
- Modify: `LidarExplorer/Presentation/ShadingDockView.swift`. The dock uses `SunDialControl(model:baseDiameter:isDragging:onEnded:)`, with `isDragging` bound to its `isDraggingSun` (the evacuation logic, 92-96) and `onEnded` calling `holdOpenIfCameraMoving()`. `SunAzimuthDial` gains `baseDiameter: CGFloat = 76`, set in `init` as `_diameter = ScaledMetric(wrappedValue: baseDiameter, relativeTo: .caption)`.
- Modify: `LidarExplorer/Presentation/ElevationProfileView.swift`. In `headerRow` (88-146), after `Spacer()` and when `model.sunDirectionMatters`, add `SunDialControl(model: model, baseDiameter: 56, isDragging: $isDraggingSun, onEnded: {})`. Pick 56 pt first, and 44 if the header crowds.

- [x] **Step 1: Extract with no change in behaviour.** Build, then take a Simulator screenshot of the dock: it is identical to before. The dial's drag and the X1 checks are unchanged.
- [x] **Step 2: Add the header dial.** Build. In the Simulator, with Hillshade, light the ruler and tap A and B: the panel's header shows the dial. `touch_path` round it: the sun writes log during the drag (as in Task 8, with a temporary log) and the terrain re-lights. Pick Slope (no sun): the dial goes. Check VoiceOver's "Sun direction" label on the header dial with the Accessibility Inspector, if available. Take screenshots at the 13-inch, portrait and landscape, and at the narrowest iPhone.
- [x] **Step 3: Commit** `agent-checkpoint: the sun dial stays reachable while a profile is shown: its state and 50 ms commit move into sundialcontrol, used by the dock and, at 56 pt, the profile panel's header when the style takes the sun`

**Verified by:** `xcodebuild` and Simulator screenshots and drags. There is no host check (a view). X1 still covers the commit rule. **Device only:** whether a 56 pt dial is usable with the Pencil and a finger, and the owner's verdict on D6.

**Execution note (59532a3, review fixes 9d55175; harness 1531):** 56 pt kept, with no bearing number on the header dial: the sun is drawn at a fixed size and inset, so on a dial under 72 pt it covers the centre's readout (`SunAzimuthDial.smallestDiameterWithReadout`); 44 pt would put the sun on the centre. VoiceOver still reads the bearing, and the dock's 76 pt dial keeps its number. `SunDialControl` takes `baseDiameter` explicitly and reads the model's sun in `onAppear`/`onChange`, not its init. The review round laid the header out with `ProfileHeaderLayout` (the title keeps two lines beside the dial, or takes a row of its own), reads a drag against the dial's frame at touch-down, draws the model's sun unless dragged, and gives the 56 pt dial a least turn of about 1.8° (`SunDialCommit.minimumTurn(forDiameter:)`, X1 +6). Not seen: landscape and VoiceOver (headless). Left for the device: grabbing the sun on the 56 pt dial can jump it up to about 33°, and the D6 verdict with the missing number.

---

### Task 10: View in 3D and the export read back the on-screen tiles the cache let go (TDD)

Cause 10. Before building, `activeGrid` and `analyticalRaster` read back every tile the renderer reports on screen (`visibleKeysSource`, `TerrainTileOverlay.swift:388-392, 2582-2586`) that the cache no longer holds. They read it from the disk tile cache through `loadTile` (1082-1122), which falls back to a fetch for fallback and local-file rasters that are never on disk. Rasters only: nothing is stored in the cache, because that would evict other tiles the map is drawing.

**Files:**
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift` (`activeGrid` 1701-1739, `analyticalRaster` 1755-1816, new private `readBackOnScreen(touching:)`)
- Modify: `Tools/ViewerHarness/Terrain3DChecks.swift` (new U3; the investigation's version is `build-review/feedback-investigation/3d-refusal/harness-probe-checks.diff`, there called U9)

- [x] **Step 1: Check U3** (called from `runTerrain3DChecks()`). This is the diff's `checkDrawnViewOutlivesTheBudget()` with two changes. **Register the on-screen source only after the 170 loads**, so that the check still tests the read-back once Task 12 spares on-screen tiles. And add a third assertion: `cachedTileKeys().count` is the same before and after `openTerrain3D` (the read-back stores nothing). Title: `"\n--- U3. a drawn view after the provider's cache has turned over ---"`.
- [x] **Step 2: Red.** Run `HARNESS_ONLY=U3`. Expected: "View in 3D over a view the map still draws meshes all of it after 170 tiles have loaded elsewhere" FAILs ("provider holds 0 of the view's 9 tiles; alert No terrain has drawn…"), and "and a GeoTIFF export of that view writes all of it" FAILs (`emptyGrid`), as the investigation saw in its copy.
- [x] **Step 3: Implement**

```swift
    /// Tiles the map is drawing over `geo` that the elevation cache has let go, read back for one build. The cache evicts
    /// by age, and the renderer never asks again for a tile it holds an image of, so a tile ages while it stays on screen
    /// (View in 3D refused a view the map had fully drawn: "No terrain has drawn for this view yet"). Read from the disk
    /// tile cache, or fetched again where the disk has none. Not stored: storing would evict other tiles on screen.
    private func readBackOnScreen(touching geo: GeoRegion) async -> [TileMosaicField.Layer] {
        guard let onScreen = visibleKeysSource?(), !onScreen.isEmpty, let pixels = observedTilePixels else { return [] }
        let generation = dataGeneration
        var layers: [TileMosaicField.Layer] = []
        for key in onScreen where cache[key] == nil {
            let parts = key.split(separator: "/").compactMap { Int($0) }
            guard parts.count == 3 else { continue }
            let path = MKTileOverlayPath(x: parts[1], y: parts[2], z: parts[0], contentScaleFactor: 1)
            let region = TerrainTileOverlay.region(for: path)
            guard region.minLatitude <= geo.maxLatitude, region.maxLatitude >= geo.minLatitude,
                  region.minLongitude <= geo.maxLongitude, region.maxLongitude >= geo.minLongitude else { continue }
            guard let entry = await loadTile(x: path.x, y: path.y, z: path.z, region: region, pixels: pixels),
                  dataGeneration == generation else { continue }
            layers.append(TileMosaicField.Layer(grid: entry.grid, bounds: entry.displayRegion))
        }
        return layers
    }
```
  In `activeGrid`, change `let layers` to `var layers`, then `layers += await readBackOnScreen(touching: geo)`, before the `isEmpty` guard. In `analyticalRaster`, do the same with `reach`.

  **Implementer decides:** on the fetch path `loadTile` also shades (`return await shade(fetched, margin:)`, 1122), which is wasted work here. Consider splitting it into `loadRaster` (disk or fetch) and `shade`, so the read-back skips shading. Mirror `dataChanged(since:x:y:z:source:started:)` (used at 503) if a mount can land mid-read. Decide whether a key with no `visibleKeysSource` (before the first region change) should fall back to the keys covering the region at the level `observedTilePixels` and the span imply (`tilePaths`, 2731-2762). The owner's case always had a region change first.
- [x] **Step 4: Green:** `HARNESS_ONLY=Terrain3D`, then the full harness and the UI build check.
- [x] **Step 5: Mutant.** Skip the read-back when `layers` is non-empty (`if layers.isEmpty { layers += … }`). U3 still passes, because the cache held nothing of the view. So also run a second U3 variant with one of the 9 tiles re-loaded after the turnover (the cache then holds one): the mutant FAILs on "meshes all of it". Keep that variant as a check.
- [x] **Step 6: Simulator** (with the go-ahead). The investigation's recipe: a Hillshade view about 1 km across at Cahokia. Drag the map about 150 pt sideways and hold until the strip draws, drag it back, and tap View in 3D. It opens with no notice (it was the refusal). Then More > Export 32-bit Float GeoTIFF: the share sheet shows (it was "Export Failed"). Then a view of several km near 36.40 N 88.34 W (Paris/Whitlock, TN), after a few pans and zooms: View in 3D opens. Put screenshots in `build-review/navigate-by-default/task10/`.
- [x] **Step 7: Commit** `agent-checkpoint: view in 3d and the geotiff exports read back the tiles the map is drawing that the elevation cache let go (from the disk cache, or fetched again), so a fully drawn view no longer says "no terrain has drawn"; u3 red first (provider held 0 of the view's 9 tiles); simulator: the 1 km recipe and a paris, tn view open in 3d`

**Verified by:**
- Harness: U3 and its variant.
- `xcodebuild`.
- Simulator: the recipe above.
- **Device only:** the owner's Paris, TN view, and which shading backend the device uses (Settings > Debug tile log), which says whether the count cap or the byte budget turned the cache over there.

**Execution note (7625479, review fixes 3b17285; harness 1542):** the investigation's U3 diff was gone from disk, so U3 was written from this text (6 checks, the variant and an LRM export check included; "nothing kept" compares the tile sets, since at the cap a store evicts one and the count never moves). `readBackOnScreen` takes the missing keys once, in the caller's turn, takes a tile that landed meanwhile from the cache, and stops when the data generation moves; there is no `loadRaster`/`shade` split (shading here only wraps the raster) and no fallback before the first region change. In the Simulator the Cahokia recipe gave "Only 47%" at 9d55175, not a refusal, and 98% after. The commits put the 2% down to cause 12, which Task 11 disproved: cause 12 leaves a view about 1 km tall 3 cm short, and a plain 1 km Cahokia view read complete at 3b17285. Its source after the drag was not traced, and Task 12's run of the same recipe, with the cache holding all 35 tiles, opened with no notice. The review round reads back only tiles the renderer has drawn (`drawnTiles()`, not loads in flight), from the disk first and the rest fetched together for at most 2 s; the 3D drape takes the renderer's own images first, so tiles the provider let go are shaded rather than white; a coarser placeholder that finer tiles cover is neither read back nor laid under them; a cancelled export builds nothing (U3, 11 checks).

---

### Task 11: The 3D and export grid reaches a tall view's edges (no false "Only 98%")

Cause 12.

**Files:**
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift` (`activeGrid` 1719-1730)
- Modify: `Tools/ViewerHarness/Terrain3DChecks.swift` (new U4, from the diff's `checkGridReachesTheViewEdges()`)

- [x] **Step 1: U4** (title `"\n--- U4. the grid reaches a tall view's edges ---"`), run on portrait regions of 12,642 × 16,219 m, 10,072 × 12,922 m and 933 × 1,198 m.
- [x] **Step 2: Red.** Expected: the first two FAIL (short by 17.8/9.5 m and 13.5/8.3 m), and the 1 km case fails by centimetres.
- [x] **Step 3: Implement.** Size and centre the mosaic from the region's Mercator bounds:
```swift
        let b = geo.mercatorBounds
        let centre = GeoRegion.fromMercatorMeters(x: (b.minX + b.maxX) / 2, y: (b.minY + b.maxY) / 2)
        let k = cos(centre.latitude * .pi / 180)
        // Half the longer Mercator side in ground metres at the centre (the builder divides by the same k), plus one of
        // the builder's largest cells, so the grid covers the view's edges rather than stopping a rounding short of them.
        let half = max(b.maxX - b.minX, b.maxY - b.minY) / 2 * k
        let radius = half + max(finest, 2 * half / 2048)
        // … MercatorMosaicBuilder.build(center: centre, radiusMeters: radius, …)
```
- [x] **Step 4: Green:** the full harness (U1–U4) and the UI build check.
- [x] **Step 5: Commit** `agent-checkpoint: the 3d and export grid is sized and centred in mercator, so a complete tall view reads complete (it fell 8-18 m short of the north and south edges and read "only 98%"); u4 red first`

**Verified by:** the harness (U4) and `xcodebuild`. In the Simulator, optionally: a fully drawn 10–16 km portrait view opens in 3D with no "Only 98%" notice. On the device, the notice percentages are part of step 6 of the old pass.

**Execution note (1875318, review fixes 6db1bdb; harness 1551):** U4 was written from this text (the investigation's diff was gone) and red reproduced the plan's figures; it gained a landscape view, a centring check and a share check over the 13-inch screen. The literal 2048 became a named `maximumSize`. 1875318's body says the grids sat "up to 1.045 of a cell" off centre; the right figure is about 0.52 (1.045 was the north-south difference), as 6db1bdb's body corrects. The review round centres the grid on `region.center`, MapKit's Mercator middle of the map's rect, and takes its half from there to the region box's farthest edge, so the rect's south edge is no longer lost on tall views (33 km short on a 1,520 km view, with no notice); a region with no extent has no grid (U4, 9 checks). Simulator: a fully drawn 12.7 × 16.2 km view at Paris, TN read "Only 98%" before and nothing after.

---

### Task 12: The provider's budget spares the tiles on screen, and sheds bitmaps and derivative planes first (recommended)

Task 10 fixes 3D and export. Spot inspection, viewshed and the transect still read the cache synchronously (`TerrainTileOverlay.swift:1375, 1400, 1533, 1591`) and still meet holes where the map draws. That is STATUS's open "tile-cache holes". In the Simulator the byte budget holds only about 31 3DEP tiles, because the CPU fallback keeps 7 derivative planes per tile (`616-650`; about 8.2 MB each, probe). The memory-warning handler already spares on-screen keys (`367-385`). The routine budget does not (`1967-1974`).

**Files:**
- Modify: `LidarExplorer/MapLayer/TerrainTileOverlay.swift` (`enforceMemoryBudget`)
- Modify: `Tools/ViewerHarness/Terrain3DChecks.swift`, or `ProviderMicroChecks.swift` if the implementer finds it a better home (new U5)

- [x] **Step 1: U5.** Load the scene's 9 tiles, register them as on screen **before** 170 loads elsewhere, then assert all three: the provider still holds all 9 (`cachedTileKeys()`); `cachedTileKeys().count <= 160`; and `await scene.provider.elevation(at: centre) != nil`. Then a byte-budget variant: force CPU derivative planes on the 9, if the harness can (the host normally shades on the GPU path). If it cannot, record that only the count cap is checked on the host.
- [x] **Step 2: Red.** Expected: "still holds all 9" fails.
- [x] **Step 3: Implement.** In `enforceMemoryBudget`, with `let onScreen = visibleKeysSource?() ?? []`:
  - (1) While over the byte budget, drop `rendered` and then `products` from the oldest entries that are not on screen.
  - (2) While still over either cap, evict whole entries that are not on screen, oldest first.
  - (3) Only then evict on-screen entries, oldest first: a zoomed-out view can hold more tiles than the cap.
  - Keep `renderedOrder` in step. Measure the cost of calling `visibleKeysSource` on every `store` (a lock and `keysToKeep`) with a temporary timing log in the Simulator. If it shows, cache the set per region change.
- [x] **Step 4: Green:** the full harness and the UI build check.
- [x] **Step 5: Simulator.** Run the Task 10 recipe with a temporary log of how many on-screen tiles the provider holds. Expected: all of them, where the investigation saw 31 of 88 and 22 of 35. Then a spot inspection right after panning back reads at once, without "Elevation unavailable".
- [x] **Step 6: Commit** `agent-checkpoint: the provider's memory budget spares the tiles on screen and sheds shaded bitmaps and cpu derivative planes before whole tiles, so spot inspection, the viewshed and transects stop meeting holes where the map draws; u5 red first; simulator: provider holds <n> of <n> on-screen tiles after the recipe`

**Verified by:**
- Harness: U5.
- `xcodebuild`.
- Simulator: the log.
- **Device only:** memory under a long session (no memory warning), and the spot, viewshed and 3D holes gone on real ground.

**Execution note (7d5bd4a, review fixes 9b3e081, holistic fix acfda68; harness 1563 at 9b3e081):** the shedding order departs from Step 3: bitmaps and then derivative planes are shed off screen, then on screen, before any whole tile is evicted (off screen first, on screen last). The Simulator's CPU fallback holds about 6 MB of planes a tile, so a view's 35 tiles alone pass 256 MB; with on-screen shedding after off-screen eviction, a pan a screen away and back dropped the rasters MapKit then redrew from its own layer, and a spot tap read "Elevation unavailable". U5 had 8 checks; the planes' step cannot be forced on the host (it shades on the GPU) and was seen only in the Simulator's logs. `visibleKeysSource` cost about 100 µs a pass, so it is not cached per region change. The review round counts as on screen every cached tile within the renderer's own keep rule of its view (`currentView()`, `TerrainTileView.keepsDrawn`), not only those the renderer holds images of, and no longer sheds a bitmap the renderer holds (U5, 12 checks); acfda68 gives the memory warning the same on-screen set and stops shedding bitmaps the renderer keeps drawn just past the screen (U5, 14). Only partly closed: a tile evicted while it was really off screen, which MapKit later redraws from its own layer, still reads "Elevation unavailable"; closing it needs a read-back on a miss for spot inspection, the profile, the transect and the viewshed. 7d5bd4a's body gives one check's red detail, "31 of 40 held", for four checks (the order check's red was "holds 1 of the 10 off the screen, 31 in all").

---

### Task 13 (owner-gated; do not start without the owner's yes): a scrub tick where the slope crosses the Slope tab's 20° line

Cause 13 is working as designed. The thump marks a *detected* earthwork's breaks, and the owner's Monks Mound line had none. Only if the owner wants feedback on any profile, add the following:
- A pure `SlopeCrossingDetector` beside `BreakCrossingDetector` (`HapticDetents.swift:66-97`): a tick on each arrival at |slope| = 20° with a 1 m tolerance, no repeat while it hovers, a reset on lift, and silence over NaN.
- A `HapticCue.slopeLine` routed like `earthworkBreak` (`HapticRouting.swift`).
- A call from the chart scrub (`ElevationProfileView.swift:511-543`), fed the slope at the ruler.

The host checks and mutants are the investigation's list (a tick on every sample above 20°; a tick on leaving). On Monks-like lines it falls at 4–8 points, all on the flanks (`haptics-dial/out/cues-run.log`).

**Execution note (the owner said yes; 8ae17ce, review fixes 961cc0e; harness 1589):** this task has no numbered steps; it ran the usual sequence (checks first, a red stub, the code, green, mutants, the Simulator). The investigation's checks were gone from disk, so V7 was written from the bullets above (17 checks, 10 mutants; 22 checks after the review round). A "place" is where the drawn steepness crosses 20°, rising or falling, interpolated between samples; both directions tick. A pure `ProfileScrubCues` feeds both detectors on every sample and plays one cue, the break first. The tick plays only on the Slope tab and only while the analysis is of the line on screen, and it reads the line the chart draws (`model.profileSlopeLine`), so it follows the drawn line, which runs straight across a stretch with no ground. `HapticCue.slopeLine` is canvas alignment on an iPad, the earthwork thump's medium impact at 0.7 on an iPhone; on an iPad the two feel alike. Simulator: 8 places on a 424 m Monks Mound line, all on its flanks. The review round holds an arrival until the scrub moves more than twice the tolerance away, with the tolerance following the chart (a metre, or two of its points where a point is more than half a metre); this changed the earthwork thump too. Each cue has its own 50 ms throttle, and a chart taken away mid-scrub clears the ruler and resets both detectors. A sway of 4 pt or more across a place still re-ticks each cycle.

---

### Task 14: Record — STATUS.md, `.agent/HANDOFF.json`, and the device checklist in `HUMAN_DO_THIS.md`

**Files:**
- Modify: `STATUS.md`
- Modify: `.agent/HANDOFF.json`
- Modify (untracked, never committed): `HUMAN_DO_THIS.md` at the repo root
- Optional: `docs/superpowers/NEXT_STEPS_FOR_AGY.md:123`. Its "Apple Pencil draws a transect in any mode" is a done task's spec. Add "(superseded 2026-09-28: the Pencil draws only with the ruler lit)".
- Add: this plan file, with its steps ticked and execution notes under any task that departed from it.

- [x] **Step 1: STATUS.md.**
  - Add a section "Navigate by default (2026-09-28)" under TODOs, linking this plan. It gives:
    - the owner's device results 1–6, verbatim in substance, with the build (e324172) and the device;
    - the root-cause table above, trimmed, keeping confirmed apart from inferred;
    - what each task changed, with its commit, how it was verified (harness count, Simulator runs, screenshots' paths), and the mechanism Task 5 landed (A or B, and what the gate showed);
    - what only the iPad can show;
    - the defaults D1–D10 as "owner may overrule".
  - In "UI polish pass (2026-09-26)", update the device line with what the owner confirmed: the ring, the roll without flashes, the pill, and the cut/fill over Monks Mound. Keep it open for what was not run.
  - Record that the spot read's tick, which fires after the tip lifts, *did* play through the Pencil. This settles one of the "may play nothing" cases for that cue.
  - Close the open follow-ups this plan fixed:
    - finding 17 (the readout during markup);
    - the Split wipe / Remove All bug;
    - tile-cache holes (only if Task 12 landed, otherwise narrow it to spot, viewshed and transect).
  - Replace the "Behaviour changes" bullet on the Pencil double-tap and squeeze.
  - Harness count, and simulator and device build status at the new HEAD.
- [x] **Step 2: `.agent/HANDOFF.json`:**
  - `active_task`: done, or the WIP state.
  - `last_commit`.
  - `modified_files`.
  - `verification_command`: `./Tools/run-harness.sh`.
  - `harness_status`: the count at HEAD.
  - `failing_assertions`: none, or the list.
  - `unverified`: the device-only items per task above.
  - `plan`: this file.
  - `next_instruction`: first, the owner's device pass (the new section in `HUMAN_DO_THIS.md`); then Task 13 only if the owner asks; then anything the pass finds.
- [x] **Step 3: `HUMAN_DO_THIS.md`** (edit in place, never commit).
  - Add at the top a section "Device pass: navigate by default (2026-09-28)" for the build at the new HEAD. Open it with:
    - the owner's results from the last sitting (items 1–6), and what changed because of each;
    - the answers to the owner's two questions. "The readout" is the box at the top left of the top bar, the one that says "Tap map for elevation", or "Drag or tap Point A" with the ruler lit in the old build (in the new build, "Pick a tool to measure" with no tool lit). Step 3's top bar dims to 35 % while the map moves (70 % under Increase Contrast or Reduce Transparency, `ViewerTopBarView.swift:74-77`). The owner saw it as "slightly transparent" and chose to keep the current fade.
  - Then the steps, in order, each with what is right and what to report:
    1. **Navigate.** No segment lit; the readout says "Pick a tool to measure". Tap the map with a finger and with the Pencil: nothing opens. Drag with one finger, then with the Pencil: both move the map. Pinch, two-finger rotate. Hover and roll: the ring and the sun move. Squeeze and double-tap: nothing happens and no pill shows.
    2. **The lock, gone.** Repeat what locked the map last time: Pencil taps and drags in every tool, close the profile with its X, squeeze and double-tap. After each, with no tool lit, pan with a finger and with the Pencil. The map must always move. If it ever does not, write down the last three things done and whether a segment is lit.
    3. **Spot Inspection** (the scope, first segment). The readout says "Tap map for elevation". Taps with a finger and the Pencil read the ground. Drags pan, and the segment stays lit. The callout's X closes the reading, and the segment stays lit. Tapping the segment turns it off. Say whether the Pencil tap plays its tick again.
    4. **Profile** (the ruler). The readout says "Tap Point A on map". Tap A, then B: the profile opens. A Pencil stroke draws the whole line from where the tip landed, and the map does not move under it, even with a palm resting on the glass. A one-finger drag pans at any time. The panel's X closes the profile, the ruler stays lit, and a finger still pans. A squeeze names the metric, and a double-tap names the signatures. With Settings > Apple Pencil > Double-Tap (and Squeeze) set to Off, neither does anything. Set them back. Double-tap to zoom with the ruler lit: no point is placed. Say whether the short wait before a tap places a point is noticeable. The dial in the panel's header turns the sun.
    5. **Viewshed.** A tap places the observer. A Pencil drag pans, and the eye stays lit.
    6. **The sun dial.** Drag it slowly and quickly with the Pencil and with a finger: the terrain re-lights *during* the drag, as with the roll. Repeat with LRM and a Raking Light blend at z19–z20, and say whether it keeps up.
    7. **3D over a drawn view.** Near Paris/Whitlock, TN, zoomed out several km, pan and zoom around for a minute, come back, and tap View in 3D. It opens. Also try More > Export Elevation GeoTIFF.
    8. **What plays when** (the haptics).
       - Through the Pencil: the dial's eight headings; the Spot Inspection tick, now only with the scope lit; the split wipe's middle.
       - The profile's thump: only when the chart scrub crosses a detected earthwork's break, and only with a "Mound: …" or "Berm/Ditch: …" chip showing. Nothing plays for dragging a line on the map or for the Slope tab's 20° line. The last Monks Mound line had no chip, so nothing could play.
       - A line that should thump: east–west, about 464 m long, about 15 m south of the summit, centred near 38.66027, −90.06205. Say whether it shows a Mound chip and thumps. If the owner wants a tick on every profile, say so (Task 13).
    9. **Split wipe.** Turn it on in Settings. Picking any segment ends it. Remove All with it on returns to no tool.
    10. **Top bar on an iPhone**, if one is handy: four segments fit.
  - Update the older sections so they do not contradict this one:
    - step 3 (a) (a coast tap no longer inspects in any case);
    - step 4 (four segments; the map rotates also in Spot Inspection and profile);
    - step 9 (a)–(c) (the pencil-tap/pan case is replaced by step 2 above; the spot tick needs the scope lit);
    - the open section's item 8 (b)–(c) (a squeeze no longer lights the ruler: it acts only in profile mode);
    - the "Haptics on this iPad" paragraph (the spot read's tick after lift did play; the dial's re-light is during the drag).
- [x] **Step 4:** Run `./Tools/run-harness.sh` and the UI build check (simulator and device), and record both.
- [x] **Step 5: Commit** (STATUS.md, HANDOFF.json, this plan; **not** HUMAN_DO_THIS.md) `agent-checkpoint: record navigate by default: the owner's first ipad results, the root causes and what each task changed and how it was verified, the device pass rewritten for the new model (untracked checklist), handoff updated; harness <n> pass, simulator and device builds succeeded`

**Execution note (the record, 2026-10-01, on acfda68):** done as listed, with these changes. The owner's answers came before execution (D1 confirmed, Tasks 12 and 13 in), so Step 3's item 8 is rewritten: the Slope tab now ticks where the slope crosses its 20° line, and the checklist says what the Pencil Pro plays and what plays nothing. The new device pass also has steps for the thalweg, markup, the top bar in a narrow window, and the defaults the owner may overrule. The record names the owner's results as passed, not passed or not reported. The tile-cache holes follow-up is narrowed, not closed: Task 12 left the case of tiles evicted while off screen. Step 4: the full harness passed with 1605 PASS, 0 FAIL. The Simulator build and the device compile check succeeded incrementally and from scratch, with no Swift warnings. The optional `NEXT_STEPS_FOR_AGY.md` line is marked superseded and goes in the same commit.

---

## Explicitly out of scope (candidates for later)

- The barrel roll during markup's pen and highlighter. The canvas has no hover recognizer (`PencilMarkupOverlay.swift`), and the owner kept markup's behaviour. Forwarding the hover through the canvas is a small follow-up if the owner wants it.
- `pushSettings` as a leading+trailing throttle, so that a fast barrel twist also re-shades mid-twist. The owner accepted today's fast-twist behaviour (STATUS.md:176), and it touches every shading control.
- The 3D drape's white blocks: only 48 shaded bitmaps are kept (`TerrainTileOverlay.swift:179, 995-1003`). The read-back idea applies, but re-shading into the composite is its own task.
- A narrow Slide Over window (320 pt), which already overflows the top bar today (8 + 10 + 304 > 288).
- Ignoring a tap that stops a coasting map (`isCameraGestureActive`). The owner did not raise it. Add it to the policy if the device pass shows accidental readings or points from it.

## Self-review

- Every owner decision maps to a task: no-tool taps and drags (1, 2, 5); the roll and the dial always (5 leaves the hover alone; 9); the Spot Inspection toggle (2, 6, 7); the profile's taps, Pencil stroke and finger pan (1, 5, 6); viewshed and markup kept (1's table; 5); the top bar's fade untouched.
- The task's requirements map to tasks: the pan lock by construction with checks that would have caught it (1, 5: R1's "one finger pans…", R4's source checks); the squeeze and double-tap meaning (3, 5); the dial throttle (8); 3D over a drawn view (10–12); the profile haptics explained, with an optional feature (13, 14); the record (14).
- Tasks 5, 7, 9 and 10–12 have Simulator steps. Only an agent with the go-ahead runs them. Everything else is harness and `xcodebuild`.
- Placeholders left for the implementer are marked "Implementer decides" or "<…>" in commit messages, to be filled from what the run showed.
