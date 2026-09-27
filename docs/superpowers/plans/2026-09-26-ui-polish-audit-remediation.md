# UI Polish Audit Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remediate the 2026-09-26 UI audit's five work areas: a shared adaptive glass-panel treatment, a circular sun-azimuth dial replacing the linear slider (new shading dock), gestural evacuation of chrome during map gestures, a regrouped top bar with 44 pt targets, and on-glass Pencil Pro feedback (barrel-roll ring + squeeze/tap notice).

**Architecture:** Pure geometry (dial bearing math, detent proximity) goes in a host-compilable `nonisolated` enum in `Presentation/`, harness-checked exactly like `PencilRollAzimuth`. SwiftUI chrome (glass modifier, dock, top bar, pencil overlays) is iOS-only and is verified by `xcodebuild` plus Simulator runs — the harness does not compile SwiftUI/MapKit views. `TerrainViewerModel` (which IS harness-compiled) gains three small pieces of UI state; the MapKit coordinator wires two delegate callbacks into them.

**Tech Stack:** Swift 6 (`-strict-concurrency=complete`, `-default-isolation MainActor`), SwiftUI, MapKit, existing `HapticFeedbackManager` / `HapticDetents` stack. No new dependencies.

---

## Context an engineer needs (read first)

- **Verification command:** `./Tools/run-harness.sh` from the repo root (`/Users/herren/dev/LidarExplorer`). Run it after EVERY edit. Full run must end `ALL CHECKS PASSED`. Baseline before this plan: 1219 PASS / 0 FAIL. Partial runs while iterating: `HARNESS_ONLY=DialGeometryChecks ./Tools/run-harness.sh` (partial runs never print ALL CHECKS PASSED — that is expected).
- **UI build check** (the harness does not compile `Presentation/` views or `MapLayer/`):
  ```
  xcodebuild -project LidarExplorer.xcodeproj -scheme LidarExplorer \
    -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
    -derivedDataPath build-review/DerivedData build
  ```
  Expected: `** BUILD SUCCEEDED **`. Keep builds/recordings inside the repo (e.g. `build-review/`), never in `/tmp` — the workspace rule forbids writing outside `/Users/herren/dev`.
- **Simulator run** (needed for any change a screenshot must prove; the app auto-selects styles via env vars):
  ```
  xcrun simctl boot 'iPad Pro 11-inch (M5)' 2>/dev/null || true
  APP=build-review/DerivedData/Build/Products/Debug-iphonesimulator/LidarExplorer.app
  BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$APP/Info.plist")
  xcrun simctl install booted "$APP"
  SIMCTL_CHILD_TEST_INITIAL_STYLE=Hillshade xcrun simctl launch --terminate-running-process booted "$BUNDLE_ID"
  sleep 8 && xcrun simctl io booted screenshot build-review/shot.png
  ```
  `TEST_INITIAL_STYLE` accepts a `dockLabel` or `displayName` (e.g. `Hillshade` needs the sun, `Slope` does not) — see [TerrainViewerView.swift:260](../../../LidarExplorer/Presentation/TerrainViewerView.swift).
- **New files need no Xcode project edit.** The project uses filesystem-synchronized groups (`objectVersion = 77`): any `.swift` file created or deleted under `LidarExplorer/` is picked up automatically. Pure files that the harness must also compile DO need adding to the `SOURCES` list in `Tools/run-harness.sh` (Task 3 does this).
- **Commit style:** `agent-checkpoint: <lowercase description>`, ending with the line `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Isolation gotchas:** default isolation is MainActor. A new pure protocol/enum that the harness uses from checks must be `nonisolated` (see `PencilRollAzimuth.swift` as the model). `os.Logger` interpolation inside actors needs locals.
- **Scope guard:** never edit multiple disparate subsystems in one pass; every task below is one component. If the harness fails after an edit, fix it before touching another file.

---

### Task 1: `GlassSurface` modifier + adopt on the spot callout and profile panel

> **Execution note (2026-09-26):** review kept `.minimumScaleFactor(0.75)` beside the new tabular digits (removing it truncated values at narrow widths and large text) and gave the rim a solid 1 pt stroke under Increase Contrast; every commit in the pass carries the Opus 5.5 attribution line instead of Fable 5.

The audit's material defect: every panel hand-rolls `Color.white.opacity(0.12)` rims (invisible in light mode) with drifting corner radii (16/18/20). One modifier, two shapes, adopted everywhere in Tasks 1–2. Also fixes the light-mode-invisible white chart cursor and the non-tabular spot metrics while those files are open.

**Files:**
- Create: `LidarExplorer/Presentation/GlassSurface.swift`
- Modify: `LidarExplorer/Presentation/SpotInspectionCalloutView.swift`
- Modify: `LidarExplorer/Presentation/ElevationProfileView.swift`

- [x] **Step 1: Create `LidarExplorer/Presentation/GlassSurface.swift`**

```swift
//
//  GlassSurface.swift
//  LidarExplorer
//
//  The one glass treatment every floating panel shares: regular material, an adaptive rim (a lit top
//  edge in dark, a hairline in light — a fixed white rim disappears over snow-white hillshade), and
//  the house shadow. Panels use 20 pt continuous corners; capsules and circles pass their own shape.
//

import SwiftUI

struct GlassSurface<S: InsettableShape>: ViewModifier {

    @Environment(\.colorScheme) private var scheme
    let shape: S

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: scheme == .dark
                            ? [Color.white.opacity(0.28), Color.white.opacity(0.06)]
                            : [Color.black.opacity(0.10), Color.black.opacity(0.04)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75))
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.16), radius: 14, y: 5)
    }
}

extension View {
    /// A floating panel: 20 pt continuous corners over the map.
    func glassPanel() -> some View {
        modifier(GlassSurface(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)))
    }

    /// The same glass on another shape (a capsule readout, a circular button).
    func glassSurface<S: InsettableShape>(in shape: S) -> some View {
        modifier(GlassSurface(shape: shape))
    }
}
```

- [x] **Step 2: Adopt in `SpotInspectionCalloutView.swift`**

Replace lines 39–46 (the `.padding(14)` through `.frame(maxWidth: 480)` chain after the outer `VStack`):

```swift
        .padding(14)
        .glassPanel()
        .frame(maxWidth: 480)
```

(The `.background(.regularMaterial, in: ...)`, `.overlay(...strokeBorder(Color.white.opacity(0.12)...)`, and `.shadow(...)` lines are deleted — `glassPanel()` replaces all three.)

In `metricBox(icon:label:value:tint:)`, replace the value `Text` and inset background:

```swift
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
```

(Adds `.monospacedDigit()`, removes `.minimumScaleFactor(0.75)`, replaces the static `Color.primary.opacity(0.04)` fill with a vibrancy-aware style.)

In `footerRow`, replace the copy chip's background line:

```swift
                .background(.quaternary.opacity(0.5), in: Capsule())
```

- [x] **Step 3: Adopt in `ElevationProfileView.swift`**

Replace lines 64–72 (the panel chrome after the outer `VStack`):

```swift
        .padding(16)
        .glassPanel()
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
```

In all three charts (`elevationChart`, `slopeChart`, `curvatureChart`), replace the scrub cursor's style — each occurrence of:

```swift
            if let selectedDistance {
                RuleMark(x: .value("Selected", selectedDistance))
                    .foregroundStyle(.white.opacity(0.75))
```

with:

```swift
            if let selectedDistance {
                RuleMark(x: .value("Selected", selectedDistance))
                    .foregroundStyle(Color.primary.opacity(0.6))
```

(Three occurrences: [ElevationProfileView.swift:334](../../../LidarExplorer/Presentation/ElevationProfileView.swift), :395, :453. A white cursor is invisible on the light-mode material card.)

- [x] **Step 4: Verify**

Run: `./Tools/run-harness.sh` — Expected: `ALL CHECKS PASSED` (1219 checks; these files are not harness-compiled, this catches accidental damage elsewhere).
Run the `xcodebuild` command from the context section — Expected: `** BUILD SUCCEEDED **`.

- [x] **Step 5: Commit**

```bash
git add LidarExplorer/Presentation/GlassSurface.swift LidarExplorer/Presentation/SpotInspectionCalloutView.swift LidarExplorer/Presentation/ElevationProfileView.swift
git commit -m "agent-checkpoint: one adaptive glass treatment for the spot callout and profile panel, tabular spot metrics, a scrub cursor visible in light mode

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Adopt `GlassSurface` on the markup toolbar and 3D panel; 44 pt markup targets

> **Execution note (2026-09-26):** the row-level `.frame(minHeight: 44)` only made the row taller, so review gave each waypoint/undo/clear/export button its own 44 pt target, packed both rows to fit a 375 pt iPhone, capped the toolbar's Dynamic Type at accessibility 2, drew the selected ink's ring outside the swatch, named the swatches by colour and forced the dark scheme on the 3D panel (its canvas is always dark).

**Files:**
- Modify: `LidarExplorer/Presentation/FieldMarkupView.swift`
- Modify: `LidarExplorer/Presentation/Terrain3DOrbitView.swift`

- [x] **Step 1: `FieldMarkupView.swift` panel chrome and targets**

Replace lines 90–94 (after the outer `VStack(spacing: 8)`):

```swift
        .padding(12)
        .glassPanel()
        .padding(.horizontal, 16)
```

In the tool `ForEach`, grow the buttons to the 44 pt minimum — replace the label's frame:

```swift
                        Image(systemName: tool.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(model.markupTool == tool ? Color.accentColor.opacity(0.25) : .clear, in: Circle())
```

In the swatch `ForEach`, wrap each 22 pt circle in a 44 pt-tall tappable frame — replace the swatch button label:

```swift
                        Circle()
                            .fill(Color(markupHex: hex))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(.primary.opacity(model.markupColorHex == hex ? 0.9 : 0.25), lineWidth: 2))
                            .frame(width: 36, height: 44)
                            .contentShape(Rectangle())
```

In the action row (`Waypoint`/`Undo`/`Clear`/`Export`), give the icon-only buttons real targets — after the `.labelStyle(.iconOnly)` line, change the two modifier lines to:

```swift
            .labelStyle(.iconOnly)
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
```

- [x] **Step 2: `Terrain3DOrbitView.swift` panel chrome**

Replace lines 49–51 (the control panel's chrome):

```swift
            .padding(14)
            .glassPanel()
            .padding(16)
```

- [x] **Step 3: Verify**

Run: `./Tools/run-harness.sh` — Expected: `ALL CHECKS PASSED`.
Run `xcodebuild` — Expected: `** BUILD SUCCEEDED **`.

- [x] **Step 4: Commit**

```bash
git add LidarExplorer/Presentation/FieldMarkupView.swift LidarExplorer/Presentation/Terrain3DOrbitView.swift
git commit -m "agent-checkpoint: glass treatment on the markup toolbar and 3D panel, 44 pt markup tool targets

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `DialGeometry` — pure dial math, harness-checked first (TDD)

> **Execution note (2026-09-26):** review added 8 checks (1241, not 1233) and `compassDetents` now takes its list from `AzimuthDetents.headings`; the holistic review later replaced the fixed 4 pt dead zone with a quarter of the diameter while a touch could still be a tap on the readout, 4 pt once a drag swings the sun (0059a31, 54764b6), and a touch that goes down on the sun takes it at once (1e86161).

The sun dial's touch-to-bearing mapping and detent proximity are pure geometry, host-compilable like `PencilRollAzimuth`. Checks are written first and must fail before the type exists.

**Files:**
- Create: `Tools/ViewerHarness/DialGeometryChecks.swift`
- Create: `LidarExplorer/Presentation/DialGeometry.swift` (in Step 4, after red)
- Modify: `Tools/run-harness.sh` (SOURCES list)
- Modify: `Tools/ViewerHarness/main.swift` (`runSections()`)

- [x] **Step 1: Write the failing checks — create `Tools/ViewerHarness/DialGeometryChecks.swift`**

```swift
//
//  DialGeometryChecks.swift
//  ViewerHarness
//
//  The sun dial's touch geometry: a drag around the face, the dead centre, the wrap through north,
//  and which compass detent a bearing sits near.
//

import CoreGraphics
import Foundation

@MainActor
func runDialGeometryChecks() {
    print("\n=== Dial geometry ===")
    let d: CGFloat = 76

    func bearing(_ x: CGFloat, _ y: CGFloat) -> Double? {
        DialGeometry.bearing(at: CGPoint(x: x, y: y), diameter: d)
    }

    check("top of the face is north", abs((bearing(38, 0) ?? -1) - 0) < 0.001)
    check("right is east", abs((bearing(76, 38) ?? -1) - 90) < 0.001)
    check("bottom is south", abs((bearing(38, 76) ?? -1) - 180) < 0.001)
    check("left is west", abs((bearing(0, 38) ?? -1) - 270) < 0.001)
    check("top-right corner is north-east", abs((bearing(76, 0) ?? -1) - 45) < 0.001)
    check("dead centre has no bearing", bearing(38, 38) == nil)
    check("just inside the dead zone has no bearing", bearing(41.9, 38) == nil)
    check("just outside the dead zone reads east", abs((bearing(42.1, 38) ?? -1) - 90) < 0.001)
    if let wrapped = bearing(37, 0) {
        check("a hair west of north wraps below 360", wrapped > 358 && wrapped < 360, "\(wrapped)")
    } else {
        check("a hair west of north wraps below 360", false, "nil")
    }

    check("44 degrees is near the NE detent", DialGeometry.nearestDetent(to: 44, tolerance: 6) == 45)
    check("357 degrees is near north around the wrap", DialGeometry.nearestDetent(to: 357, tolerance: 6) == 0)
    check("3 degrees is near north", DialGeometry.nearestDetent(to: 3, tolerance: 6) == 0)
    check("22.5 degrees sits between detents", DialGeometry.nearestDetent(to: 22.5, tolerance: 6) == nil)
    check("tolerance is inclusive", DialGeometry.nearestDetent(to: 51, tolerance: 6) == 45)
}
```

- [x] **Step 2: Register the section and the sources**

In `Tools/ViewerHarness/main.swift`, inside `runSections()`, add after the `PencilRollChecks` line:

```swift
    await harnessSection("DialGeometryChecks") { runDialGeometryChecks() }
```

In `Tools/run-harness.sh`, in the `SOURCES=(` list:
- after the line `LidarExplorer/Presentation/PencilRollAzimuth.swift \` add:
  ```
  LidarExplorer/Presentation/DialGeometry.swift \
  ```
- after the line `Tools/ViewerHarness/PencilRollChecks.swift \` add:
  ```
  Tools/ViewerHarness/DialGeometryChecks.swift \
  ```

- [x] **Step 3: Run to verify it fails**

Run: `HARNESS_ONLY=DialGeometryChecks ./Tools/run-harness.sh`
Expected: **compile failure** — `error: cannot find 'DialGeometry' in scope` (the checks are red because the type does not exist; a missing-file error for `DialGeometry.swift` also counts as red — create an empty file if the driver refuses to start).

- [x] **Step 4: Implement — create `LidarExplorer/Presentation/DialGeometry.swift`**

```swift
//
//  DialGeometry.swift
//  LidarExplorer
//
//  The geometry of a circular bearing dial: which bearing a touch asks for, and which compass detent a
//  bearing sits near. Pure, so a drag around the face is testable without a screen (the pattern of
//  PencilRollAzimuth.swift).
//

import CoreGraphics
import Foundation

public nonisolated enum DialGeometry {

    /// Touches within this many points of the centre have no usable direction.
    public static let deadZoneRadius: CGFloat = 4

    /// The eight compass headings the azimuth haptics tick at (HapticDetents), in degrees.
    public static let compassDetents: [Double] = stride(from: 0.0, to: 360.0, by: 45.0).map { $0 }

    /// The bearing, in degrees [0, 360), north up and clockwise, of `point` from the centre of a dial
    /// `diameter` points across whose origin is its top-left corner; `nil` inside the dead zone.
    public static func bearing(at point: CGPoint, diameter: CGFloat) -> Double? {
        let dx = point.x - diameter / 2
        let dy = point.y - diameter / 2
        guard dx * dx + dy * dy > deadZoneRadius * deadZoneRadius else { return nil }
        var degrees = Foundation.atan2(Double(dx), Double(-dy)) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees == 360 ? 0 : degrees
    }

    /// The compass detent within `tolerance` degrees of `azimuth`, measured around the circle, or `nil`.
    public static func nearestDetent(to azimuth: Double, tolerance: Double) -> Double? {
        var best: (detent: Double, distance: Double)?
        for detent in compassDetents {
            let distance = abs((azimuth - detent).remainder(dividingBy: 360))
            if distance <= tolerance, distance < (best?.distance ?? .infinity) {
                best = (detent, distance)
            }
        }
        return best?.detent
    }
}
```

- [x] **Step 5: Run to verify it passes**

Run: `HARNESS_ONLY=DialGeometryChecks ./Tools/run-harness.sh`
Expected: 14 `PASS` lines under `=== Dial geometry ===`, then `PARTIAL RUN (HARNESS_ONLY=DialGeometryChecks): all 14 checks that ran passed`.

Run the full suite before committing: `./Tools/run-harness.sh`
Expected: `ALL CHECKS PASSED` (1233 checks).

- [x] **Step 6: Commit**

```bash
git add LidarExplorer/Presentation/DialGeometry.swift Tools/ViewerHarness/DialGeometryChecks.swift Tools/ViewerHarness/main.swift Tools/run-harness.sh
git commit -m "agent-checkpoint: dial geometry for the sun dial, checked on the host: bearing from a touch, dead centre, wrap through north, detent proximity

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: `ShadingDockView` — style tray + circular sun dial, replacing the linear slider

> **Execution note (2026-09-26):** detent ticks use `Color(uiColor: .tertiaryLabel)` (the plan's hierarchical `.tertiary` drew 2 of the 8 rotated ticks); review added drag ends on cancellation, an accessibility 2 cap, the press spring kept off the sun's rotation, the sun on an orbit inside the ticks, 44 pt chips, a whole-degree VoiceOver value and chip labels matching their text (18 more dial checks, 1259); later rounds added a chevron for chips past the tray's edge, a button that pages the tray (1e86161).

Replaces `ViewerBottomDockView`. The dial wraps freely through north (the slider could not cross 359°→0°), draws the eight detents the haptics already tick, and brightens the near one so every felt snap is seen. The 60 ms re-shade debounce and the `HapticFeedbackManager` call sequence are preserved exactly.

**Files:**
- Create: `LidarExplorer/Presentation/ShadingDockView.swift`
- Modify: `LidarExplorer/Presentation/TerrainViewerView.swift:154` (one identifier)
- Delete: `LidarExplorer/Presentation/ViewerBottomDockView.swift`

- [x] **Step 1: Create `LidarExplorer/Presentation/ShadingDockView.swift`**

```swift
//
//  ShadingDockView.swift
//  LidarExplorer
//
//  Floating dock: the relief-style tray and a circular sun-azimuth dial. The dial wraps freely through
//  north — a linear slider cannot cross 359° to 0° — and draws the eight compass detents the haptics
//  tick (HapticDetents), the near one brightening, so every snap that is felt is also seen.
//

import SwiftUI
import UIKit

public struct ShadingDockView: View {

    @Bindable var model: TerrainViewerModel

    /// The sun while a finger is on the dial; committed through the same 60 ms debounce the old slider
    /// used, so a scrub does not re-shade every visible tile per sample.
    @State private var localAzimuth: Double = 315
    @State private var debounceTask: Task<Void, Never>?
    @State private var isDraggingSun = false
    /// The style picker's own tick; the dial's ticks belong to ``HapticFeedbackManager``.
    @State private var selectionFeedback = UISelectionFeedbackGenerator()
    @Namespace private var chipSelection

    public init(model: TerrainViewerModel) {
        self.model = model
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 14) {
            styleTray
            if model.sunDirectionMatters {
                sunDial
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassPanel()
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.sunDirectionMatters)
        .onAppear { localAzimuth = model.azimuth }
        .onChange(of: model.azimuth) { _, new in
            // The pencil roll or a reset moved the sun; follow unless a finger owns the dial.
            if !isDraggingSun, abs(localAzimuth - new) > 0.5 { localAzimuth = new }
        }
        .onChange(of: model.style) { _, _ in selectionFeedback.selectionChanged() }
    }

    // MARK: - Style tray

    private var styleTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(ReliefStyle.allCases) { style in
                    let selected = model.style == style
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            model.style = style
                        }
                    } label: {
                        Text(style.dockLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 40)
                            .background {
                                if selected {
                                    Capsule()
                                        .fill(Color.accentColor.gradient)
                                        .matchedGeometryEffect(id: "chip", in: chipSelection)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(style.displayName)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
        .mask {
            // The tray fades at its edges instead of clipping chips mid-glyph.
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 12)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 12)
            }
        }
    }

    // MARK: - Sun dial

    private var sunDial: some View {
        SunAzimuthDial(
            azimuth: localAzimuth,
            isActive: isDraggingSun,
            onBegan: {
                isDraggingSun = true
                HapticFeedbackManager.shared.beginAzimuthGesture(at: localAzimuth)
            },
            onChanged: { degrees in
                localAzimuth = degrees
                HapticFeedbackManager.shared.azimuthSnap(degrees: degrees)
                debounceTask?.cancel()
                debounceTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    guard !Task.isCancelled else { return }
                    model.azimuth = degrees
                }
            },
            onEnded: {
                isDraggingSun = false
                HapticFeedbackManager.shared.endAzimuthGesture()
                debounceTask?.cancel()
                model.azimuth = localAzimuth
            }
        )
    }
}

// MARK: - Dial

/// A circular bearing instrument: drag anywhere on the face to swing the sun, wrapping freely through
/// north. 0° is up (north), increasing clockwise, matching the shading azimuth convention.
struct SunAzimuthDial: View {

    let azimuth: Double
    let isActive: Bool
    let onBegan: () -> Void
    let onChanged: (Double) -> Void
    let onEnded: () -> Void

    @ScaledMetric(relativeTo: .caption) private var diameter: CGFloat = 76
    @State private var isTracking = false

    var body: some View {
        ZStack {
            Circle()
                .fill(.quaternary.opacity(0.5))
            Circle()
                .strokeBorder(.separator, lineWidth: 0.75)

            detentMarks

            // The sun, riding the rim.
            Circle()
                .fill(Color.orange.gradient)
                .frame(width: 14, height: 14)
                .shadow(color: .orange.opacity(isActive ? 0.8 : 0.35), radius: isActive ? 7 : 3)
                .offset(y: -(diameter / 2 - 12))
                .rotationEffect(.degrees(azimuth))

            Text(readout)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .contentTransition(.numericText(value: azimuth))
                .animation(.spring(response: 0.25, dampingFraction: 0.9), value: azimuth.rounded())
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(isActive ? 1.06 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isActive)
        .contentShape(Circle())
        .gesture(dialGesture)
        .accessibilityElement()
        .accessibilityLabel("Sun direction")
        .accessibilityValue(String(format: "%.0f degrees", azimuth))
        .accessibilityAdjustableAction { direction in
            let step: Double = direction == .increment ? 5 : -5
            var next = (azimuth + step).truncatingRemainder(dividingBy: 360)
            if next < 0 { next += 360 }
            onBegan(); onChanged(next); onEnded()
        }
    }

    private var readout: String {
        let whole = azimuth.rounded() == 360 ? 0 : azimuth.rounded()
        return String(format: "%03.0f°", whole)
    }

    /// Ticks at the eight headings the haptics snap to; the one the sun sits nearest glows, so the
    /// haptic and the picture agree.
    private var detentMarks: some View {
        ForEach(DialGeometry.compassDetents, id: \.self) { heading in
            let near = DialGeometry.nearestDetent(to: azimuth, tolerance: 6) == heading
            Capsule()
                .fill(near ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                .frame(width: near ? 2.5 : 1.5,
                       height: heading.truncatingRemainder(dividingBy: 90) == 0 ? 7 : 5)
                .offset(y: -(diameter / 2 - 6))
                .rotationEffect(.degrees(heading))
                .animation(.easeOut(duration: 0.12), value: near)
        }
    }

    private var dialGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isTracking {
                    isTracking = true
                    onBegan()
                }
                guard let degrees = DialGeometry.bearing(at: value.location, diameter: diameter) else { return }
                onChanged(degrees)
            }
            .onEnded { _ in
                isTracking = false
                onEnded()
            }
    }
}
```

- [x] **Step 2: Swap it in and delete the old dock**

In `LidarExplorer/Presentation/TerrainViewerView.swift:154`, replace:

```swift
                    ViewerBottomDockView(model: model)
```

with:

```swift
                    ShadingDockView(model: model)
```

Then: `git rm LidarExplorer/Presentation/ViewerBottomDockView.swift` (filesystem-synced project — no pbxproj edit).

- [x] **Step 3: Verify builds**

Run: `./Tools/run-harness.sh` — Expected: `ALL CHECKS PASSED` (1233).
Run `xcodebuild` — Expected: `** BUILD SUCCEEDED **`. A leftover reference to `ViewerBottomDockView` anywhere is a build error — there is exactly one call site (the line edited above).

- [x] **Step 4: Verify in the Simulator**

Use the Simulator run recipe from the context section with `SIMCTL_CHILD_TEST_INITIAL_STYLE=Hillshade`, screenshot to `build-review/dock-hillshade.png`. Confirm: dial visible at the dock's right, sun dot at the azimuth, tray chips legible. Relaunch with `SIMCTL_CHILD_TEST_INITIAL_STYLE=Slope`, screenshot — confirm the dial is absent (slope ignores the sun). Also toggle dark appearance (`xcrun simctl ui booted appearance dark`, screenshot) — the rim must be visible in both.

- [x] **Step 5: Commit**

```bash
git add -A LidarExplorer/Presentation/ShadingDockView.swift LidarExplorer/Presentation/ViewerBottomDockView.swift LidarExplorer/Presentation/TerrainViewerView.swift
git commit -m "agent-checkpoint: a circular sun dial in the dock, wrapping through north with visible compass detents, in place of the linear azimuth slider

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Gestural evacuation — chrome yields while the camera moves

> **Execution note (2026-09-26):** the swap sits in a `ZStack(alignment: .bottom)` (a `Group` played no transition) and first yielded only when `isCameraGestureActive && !isDraggingSun`; after review the dock yields while the camera moves unless a finger is on the dial or the tray, the dock was held open during the move, or VoiceOver or Switch Control is running, and it stays mounted (hidden, under the pill, with a touch catcher over its footprint) instead of being replaced; the top bar's dim is skipped under VoiceOver and Switch Control, softened under Increase Contrast or Reduce Transparency (a369b62), and applied piece by piece over a clear backing (a dimmed bar let taps fall through to the map, 0059a31).

**Files:**
- Modify: `LidarExplorer/Presentation/TerrainViewerModel.swift` (one property)
- Modify: `LidarExplorer/MapLayer/TerrainMapView.swift` (coordinator: one new delegate method, one line in an existing one)
- Modify: `LidarExplorer/Presentation/ShadingDockView.swift` (evacuated-pill branch)
- Modify: `LidarExplorer/Presentation/ViewerTopBarView.swift` (dim while active)

- [x] **Step 1: Model flag**

In `TerrainViewerModel.swift`, directly after the `toggleSignaturesOverlay()` function (around line 819), add:

```swift
    /// True while the map camera is moving (a pan, pinch, rotation, or a programmatic flight); the
    /// floating chrome yields while it is. Set by the map coordinator's region-will/did-change pair.
    public var isCameraGestureActive = false
```

- [x] **Step 2: Coordinator wiring**

In `TerrainMapView.swift`, add a new delegate method directly above the existing `mapView(_:regionDidChangeAnimated:)` (around line 869):

```swift
        public func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            model.isCameraGestureActive = true
        }
```

And make the first line of the existing `mapView(_:regionDidChangeAnimated:)` body:

```swift
            model.isCameraGestureActive = false
```

(before the existing `model.visibleRegion = mapView.region` line).

- [x] **Step 3: Dock evacuates to a pill**

In `ShadingDockView.swift`, replace the whole `public var body: some View { ... }` with:

```swift
    public var body: some View {
        Group {
            if model.isCameraGestureActive {
                evacuatedPill
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                dock
                    .transition(.scale(scale: 0.96, anchor: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.isCameraGestureActive)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onAppear { localAzimuth = model.azimuth }
        .onChange(of: model.azimuth) { _, new in
            // The pencil roll or a reset moved the sun; follow unless a finger owns the dial.
            if !isDraggingSun, abs(localAzimuth - new) > 0.5 { localAzimuth = new }
        }
        .onChange(of: model.style) { _, _ in selectionFeedback.selectionChanged() }
    }

    /// While the map is being panned or pinched the dock yields to a single read-only pill: the
    /// current style, and the sun bearing when it matters.
    private var evacuatedPill: some View {
        HStack(spacing: 6) {
            Text(model.style.dockLabel)
                .font(.caption.weight(.semibold))
            if model.sunDirectionMatters {
                Text("·").foregroundStyle(.tertiary)
                Image(systemName: "sun.max.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text(String(format: "%03.0f°", model.azimuth.rounded() == 360 ? 0 : model.azimuth.rounded()))
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassSurface(in: Capsule())
        .frame(maxWidth: .infinity, alignment: .center)
        .allowsHitTesting(false)
    }

    private var dock: some View {
        HStack(alignment: .center, spacing: 14) {
            styleTray
            if model.sunDirectionMatters {
                sunDial
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassPanel()
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.sunDirectionMatters)
    }
```

(`styleTray` and `sunDial` are unchanged; the outer paddings and `onChange` handlers move to the `Group`.)

- [x] **Step 4: Top bar dims**

In `ViewerTopBarView.swift`, add to the end of the outer `HStack`'s modifier chain (after `.padding(.top, 8)`):

```swift
        .opacity(model.isCameraGestureActive ? 0.35 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.isCameraGestureActive)
```

- [x] **Step 5: Verify**

Run: `./Tools/run-harness.sh` — Expected: `ALL CHECKS PASSED` (the model change compiles host-side here; a wiring mistake in the coordinator only surfaces in xcodebuild).
Run `xcodebuild` — Expected: `** BUILD SUCCEEDED **`.
Simulator (per the handoff lesson: any MapKit behaviour must be seen running): launch, start `xcrun simctl io booted recordVideo build-review/evacuation.mov` in the background, pan the map (Simulator control tool swipe, or by hand), stop the recording (SIGINT), extract frames (`ffmpeg -i build-review/evacuation.mov -vf fps=10 build-review/evac-%03d.png`). Confirm: mid-pan frames show the compact pill and a dimmed top bar; settled frames show the full dock again. A programmatic flight (Fly to Site) also evacuating is intended behaviour.

- [x] **Step 6: Commit**

```bash
git add LidarExplorer/Presentation/TerrainViewerModel.swift LidarExplorer/MapLayer/TerrainMapView.swift LidarExplorer/Presentation/ShadingDockView.swift LidarExplorer/Presentation/ViewerTopBarView.swift
git commit -m "agent-checkpoint: chrome yields while the camera moves: the dock collapses to a pill and the top bar dims, restored on settle

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Top bar regroup — telemetry, location, 3D, a mode cluster, and one menu

> **Execution note (2026-09-26):** the modes became exclusive in the model (`toggleProfileMode`/`toggleViewshedMode` leave markup; a Pencil double-tap or squeeze does nothing during markup); glass controls got a lighter control shadow (`GlassElevation`, f526cc7); the bar gained the two-row tier the plan said was not needed (its ~290 pt of fixed chrome left out gaps and margins, ~364 pt in fact; c220826); the buttons cap Dynamic Type at accessibility 1 (a369b62).

Nine 36 pt circles become: the telemetry capsule (which now wins the width fight), two 44 pt circular buttons (location, 3D), a three-segment mode cluster with a single accent and a sliding selection capsule, and one utilities menu (landmarks, styles guide, export, settings). Fixed chrome shrinks from ~390 pt to ~290 pt, so no `ViewThatFits` tier is needed even beside the 300 pt inspector on an 11" portrait.

**Files:**
- Modify: `LidarExplorer/Presentation/ViewerTopBarView.swift` (full rewrite)

- [x] **Step 1: Rewrite `ViewerTopBarView.swift`**

Replace the entire file contents with:

```swift
//
//  ViewerTopBarView.swift
//  LidarExplorer
//
//  Top bar: the telemetry capsule, location and 3D buttons, a cluster for the three interaction
//  modes (one accent, a sliding selection), and one menu for everything that is not moment-to-moment.
//

import CoreLocation
import SwiftUI

public struct ViewerTopBarView: View {

    @Bindable var model: TerrainViewerModel
    @Binding var showsStyleReference: Bool
    @Binding var showsSettings: Bool

    @Namespace private var modeSelection

    public init(
        model: TerrainViewerModel,
        showsStyleReference: Binding<Bool>,
        showsSettings: Binding<Bool>
    ) {
        self.model = model
        self._showsStyleReference = showsStyleReference
        self._showsSettings = showsSettings
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            elevationCapsule
            Spacer(minLength: 8)
            circularButton("My location", icon: "location.fill",
                           disabled: model.locationAuthorization == .denied) {
                Task { await model.goToUserLocation() }
            }
            terrain3DButton
            modeCluster
            utilitiesMenu
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .opacity(model.isCameraGestureActive ? 0.35 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.isCameraGestureActive)
    }

    // MARK: - Elevation Capsule

    private var elevationCapsule: some View {
        HStack(spacing: 8) {
            if model.isProfileModeActive {
                if model.isGeneratingProfile {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "ruler.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
            } else if model.interactionMode == .thalweg {
                Image(systemName: "water.waves")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            } else if model.interactionMode == .historicalWipe {
                Image(systemName: "slider.horizontal.2.square")
                    .font(.caption2)
                    .foregroundStyle(.purple)
            } else if case .loading = model.inspectionState {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "mountain.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.tint)
            }

            Text(readoutText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .glassSurface(in: Capsule())
    }

    private var isPlaceholder: Bool {
        if model.interactionMode != .explore { return false }
        if case .idle = model.inspectionState { return true }
        return false
    }

    private var readoutText: String {
        switch model.interactionMode {
        case .thalweg:
            if model.thalwegDraft.isEmpty {
                return "Drag along channel"
            } else {
                return "Tracing thalweg…"
            }
        case .historicalWipe:
            return "Drag split wipe to compare"
        case .transect:
            if model.isGeneratingProfile {
                return "Calculating profile…"
            } else if model.profileStart == nil {
                return "Drag or tap Point A"
            } else if model.profileEnd == nil {
                return "Tap Point B on map"
            } else {
                return "Transect sampled"
            }
        case .viewshed:
            if model.isComputingViewshed {
                return "Computing viewshed…"
            } else if model.viewshedObserverCoordinate == nil {
                return "Tap map for observer"
            } else {
                return "Observer placed (drag pin to move)"
            }
        case .explore:
            switch model.inspectionState {
            case .idle:
                return "Tap map for elevation"
            case .loading:
                return "Reading ground…"
            case .elevation(let e, _):
                return model.formattedElevation(e)
            case .noCoverage:
                return "No coverage here"
            case .failed:
                return "Elevation unavailable"
            }
        }
    }

    // MARK: - Circular buttons

    private func circularButton(
        _ label: String, icon: String, disabled: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .glassSurface(in: Circle())
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private var terrain3DButton: some View {
        Button {
            Task { await model.openTerrain3D() }
        } label: {
            Group {
                if model.isPreparingTerrain3D {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "cube.transparent")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .glassSurface(in: Circle())
        .disabled(model.isPreparingTerrain3D)
        .accessibilityLabel("View in 3D")
    }

    // MARK: - Mode cluster

    /// The three mutually exclusive interaction tools, one accent, the selection sliding between them.
    private var modeCluster: some View {
        HStack(spacing: 2) {
            modeSegment("Cross-Section Profile", id: "profile",
                        icon: "ruler", selectedIcon: "ruler.fill",
                        selected: model.isProfileModeActive) {
                model.toggleProfileMode()
            }
            modeSegment("Viewshed Analysis", id: "viewshed",
                        icon: "eye", selectedIcon: "eye.fill",
                        selected: model.interactionMode == .viewshed) {
                model.toggleViewshedMode()
            }
            modeSegment("Field Markup", id: "markup",
                        icon: "pencil.tip.crop.circle", selectedIcon: "pencil.tip.crop.circle.fill",
                        selected: model.isMarkingUp) {
                model.toggleFieldMarkup()
            }
        }
        .padding(3)
        .glassSurface(in: Capsule())
    }

    private func modeSegment(
        _ label: String, id: String, icon: String, selectedIcon: String,
        selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                action()
            }
        } label: {
            Image(systemName: selected ? selectedIcon : icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 44, height: 38)
                .background {
                    if selected {
                        Capsule()
                            .fill(Color.accentColor.gradient)
                            .matchedGeometryEffect(id: "mode", in: modeSelection)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Utilities menu

    private var utilitiesMenu: some View {
        Menu {
            Button {
                model.showsLandmarks = true
            } label: {
                Label("Explore LiDAR Sites", systemImage: "safari")
            }
            Button {
                showsStyleReference.toggle()
            } label: {
                Label("Map Styles Guide", systemImage: "questionmark.circle")
            }
            Section("Export") {
                Button {
                    Task { await model.shareGeoTIFF(.elevation) }
                } label: {
                    Label(
                        model.analyticalExportStyle == nil ? "Export 32-bit Float GeoTIFF" : "Export Elevation GeoTIFF",
                        systemImage: "doc.badge.gearshape.fill"
                    )
                }
                .disabled(model.isPreparingExport)
                // A micro-topography style can also export its product: the analysis values, not the colour map.
                if let style = model.analyticalExportStyle {
                    Button {
                        Task { await model.shareGeoTIFF(.analytical(style)) }
                    } label: {
                        Label("Export \(style.displayName) GeoTIFF", systemImage: "chart.xyaxis.line")
                    }
                    .disabled(model.isPreparingExport)
                }
            }
            Divider()
            Button {
                showsSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .glassSurface(in: Circle())
        .accessibilityLabel("More")
    }
}
```

Note: Task 5 already added the `.opacity`/`.animation` evacuation pair; the rewrite above keeps it. If Task 5 has not run yet (tasks executed out of order), omit those two lines and let Task 5 add them.

- [x] **Step 2: Verify**

Run: `./Tools/run-harness.sh` — Expected: `ALL CHECKS PASSED`.
Run `xcodebuild` — Expected: `** BUILD SUCCEEDED **`.
Simulator: launch, screenshot `build-review/topbar.png`. Confirm: capsule + 2 circles + 3-segment cluster + ellipsis, all ≥44 pt tall; tap the ellipsis (Simulator control tool or hand) and screenshot the open menu — landmarks, styles guide, export section, settings all present. Enter profile mode via the cluster: the segment fills with the accent and the capsule readout switches to the transect prompt.

- [x] **Step 3: Commit**

```bash
git add LidarExplorer/Presentation/ViewerTopBarView.swift
git commit -m "agent-checkpoint: the top bar regrouped: telemetry first, a three-mode cluster with one accent, and a single menu for landmarks, guide, export and settings

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Pencil Pro on-glass feedback — barrel-roll ring and squeeze/tap notice

> **Execution note (2026-09-26):** the handlers keep calling `model.handlePencilDoubleTap()`/`handlePencilSqueeze()` (Step 2's inline `toggleProfileMode()` would have undone Task 6's markup fix) and the notices are set in the model; the ring and pill are separate views (`PencilRollRingLayer`, `ToolNoticeOverlay`); review moved the hover rules into the model (`handlePencilHover`, `endPencilHover`) and kept the ring clear of the tip, the top bar, the pill and the panels; the device item went into `HUMAN_DO_THIS.md`, which now lives at this repo's root.

The barrel roll re-lights the terrain with no visible instrument, and squeeze/tap remap modes silently. A vibrant ring above the hover point now echoes the sun the roll is steering (reusing `DialGeometry` detents), and a transient pill acknowledges squeeze/tap. Existing behaviours (which gesture does what) are unchanged.

**Files:**
- Modify: `LidarExplorer/Presentation/TerrainViewerModel.swift` (nested type + two properties)
- Modify: `LidarExplorer/MapLayer/TerrainMapView.swift` (hover/squeeze/tap handlers)
- Create: `LidarExplorer/Presentation/PencilAzimuthRing.swift`
- Modify: `LidarExplorer/Presentation/TerrainViewerView.swift` (two overlays)

- [x] **Step 1: Model state**

In `TerrainViewerModel.swift`, directly after the `isCameraGestureActive` property added in Task 5, add:

```swift
    /// Where a Pencil Pro barrel roll is steering the sun, in map-view points, for the ring the
    /// viewer projects above the hover point. `CGPoint` only — no UIKit — so the harness still
    /// compiles this file.
    public struct PencilRollIndication: Equatable {
        public var point: CGPoint
        public var azimuth: Double
    }

    /// Live while a barrel roll is moving the sun; the viewer fades it ~1 s after the last change.
    public var pencilRollIndication: PencilRollIndication?

    /// A transient acknowledgement of a Pencil squeeze or double-tap; the viewer fades it on its own.
    public var toolNotice: String?
```

(If `CGPoint` is not yet in scope in that file, add `import CoreGraphics` to its imports — CoreLocation/MapKit usually re-export it; the harness build will say immediately.)

- [x] **Step 2: Coordinator — hover sets the ring, squeeze/tap set the notice**

In `TerrainMapView.swift`, replace the whole `handleHover(_:)` method with:

```swift
        @objc func handleHover(_ recognizer: UIHoverGestureRecognizer) {
            // Only a hover in progress reports a roll to follow. Terrain that ignores the sun (the style and any layer
            // over it) is left alone: the roll would overwrite the user's setting unseen.
            switch recognizer.state {
            case .began, .changed:
                break
            default:
                model.pencilRollIndication = nil
                return
            }
            guard model.sunDirectionMatters else { return }
            // Every hover sample reports a roll, and a resting hand trembles: the sun trails the roll through a
            // backlash, or each sample would re-shade every visible tile (see PencilRollAzimuth).
            if #available(iOS 17.5, *),
               let azimuth = PencilRollAzimuth.azimuth(forRoll: Double(recognizer.rollAngle), current: model.azimuth) {
                model.azimuth = azimuth
                if let map = mapView {
                    model.pencilRollIndication = .init(point: recognizer.location(in: map), azimuth: azimuth)
                }
            } else if model.pencilRollIndication != nil, let map = mapView {
                // The ring, once up, follows the pencil between sun moves; the viewer fades it on its own.
                model.pencilRollIndication?.point = recognizer.location(in: map)
            }
        }
```

Replace `pencilInteractionDidTap(_:)` with:

```swift
        public func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            Task { @MainActor in
                if model.isProfileModeActive {
                    model.toggleSignaturesOverlay()
                    model.toolNotice = model.showsTransectSignatures
                        ? "Earthwork Signatures On" : "Earthwork Signatures Off"
                } else {
                    model.toggleProfileMode()
                    model.toolNotice = "Cross-Section Profile"
                }
            }
        }
```

Replace the body of the squeeze handler's `if squeeze.phase == .ended` task with:

```swift
            if squeeze.phase == .ended {
                Task { @MainActor in
                    if model.isProfileModeActive {
                        model.cycleProfileMetric()
                        model.toolNotice = "Metric: \(model.activeProfileMetric.rawValue)"
                    } else {
                        model.toggleProfileMode()
                        model.toolNotice = "Cross-Section Profile"
                    }
                }
            }
```

- [x] **Step 3: Create `LidarExplorer/Presentation/PencilAzimuthRing.swift`**

```swift
//
//  PencilAzimuthRing.swift
//  LidarExplorer
//
//  The instrument a Pencil Pro barrel roll projects onto the glass: a ring above the hover point with
//  the sun riding its rim and the compass detents drawn, so the roll's effect is seen where the hand
//  is, not only in the re-shaded tiles.
//

import SwiftUI

struct PencilAzimuthRing: View {

    let azimuth: Double

    private let diameter: CGFloat = 92

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
            Circle()
                .strokeBorder(.separator, lineWidth: 0.75)

            ForEach(DialGeometry.compassDetents, id: \.self) { heading in
                let near = DialGeometry.nearestDetent(to: azimuth, tolerance: 6) == heading
                Capsule()
                    .fill(near ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                    .frame(width: near ? 2.5 : 1.5,
                           height: heading.truncatingRemainder(dividingBy: 90) == 0 ? 8 : 5)
                    .offset(y: -(diameter / 2 - 7))
                    .rotationEffect(.degrees(heading))
            }

            Circle()
                .fill(Color.orange.gradient)
                .frame(width: 12, height: 12)
                .shadow(color: .orange.opacity(0.7), radius: 5)
                .offset(y: -(diameter / 2 - 14))
                .rotationEffect(.degrees(azimuth))

            Text(String(format: "%03.0f°", azimuth.rounded() == 360 ? 0 : azimuth.rounded()))
                .font(.caption.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText(value: azimuth))
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
        .accessibilityHidden(true)
    }
}
```

- [x] **Step 4: Project the ring and the notice in `TerrainViewerView.swift`**

Inside the root `ZStack`, after the historical-wipe `if let fraction = ...` block's closing brace (after line ~130), add:

```swift
            // Pencil Pro barrel roll: a ring above the hover point echoes the sun it is steering.
            Group {
                if let indication = model.pencilRollIndication {
                    PencilAzimuthRing(azimuth: indication.azimuth)
                        .position(x: indication.point.x, y: max(indication.point.y - 80, 60))
                        .allowsHitTesting(false)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .task(id: indication) {
                            try? await Task.sleep(for: .milliseconds(900))
                            guard !Task.isCancelled else { return }
                            model.pencilRollIndication = nil
                        }
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: model.pencilRollIndication == nil)
```

(Every point update restarts the 900 ms `task(id:)` clock, so the ring lives while the roll does and fades ~1 s after it stops. `position` is in the ZStack's space, which matches the map view's because both fill the screen.)

Then, immediately after the ZStack's closing brace and **before** `.safeAreaInset(edge: .top)`, add:

```swift
        .overlay(alignment: .top) {
            Group {
                if let notice = model.toolNotice {
                    Text(notice)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .glassSurface(in: Capsule())
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: notice) {
                            try? await Task.sleep(for: .milliseconds(1400))
                            guard !Task.isCancelled else { return }
                            model.toolNotice = nil
                        }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.toolNotice)
        }
```

(Attached before the safe-area insets, so the pill drops in just below the top bar.)

- [x] **Step 5: Verify**

Run: `./Tools/run-harness.sh` — Expected: `ALL CHECKS PASSED` (the model additions compile host-side here; a `CGPoint`-not-found error means the missing `import CoreGraphics` from Step 1).
Run `xcodebuild` — Expected: `** BUILD SUCCEEDED **`.
Simulator: the Simulator has no Pencil (hover, roll, squeeze cannot be exercised — the same limit the handoff records for the strobe fix). Verify what it can: launch with `SIMCTL_CHILD_TEST_VIEWSHED_READOUT=1` unset, app runs, no ring or pill appears uninvoked, screenshot clean. Then **append the device checklist**: add to `/Users/herren/dev/HUMAN_DO_THIS.md` an item — "Pencil Pro on iPad: hover-roll over a Hillshade map shows a ring above the pencil with the sun dot tracking the roll and detents glowing at compass points, fading ~1 s after the roll stops; squeeze shows a 'Cross-Section Profile' pill below the top bar; in profile mode, squeeze cycles the metric pill and double-tap toggles the signatures pill."

- [x] **Step 6: Commit**

```bash
git add LidarExplorer/Presentation/TerrainViewerModel.swift LidarExplorer/MapLayer/TerrainMapView.swift LidarExplorer/Presentation/PencilAzimuthRing.swift LidarExplorer/Presentation/TerrainViewerView.swift
git commit -m "agent-checkpoint: the pencil shows itself: a roll ring above the hover point with detents that glow, and a transient pill naming what a squeeze or tap just did

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Final sweep — full verification, docs, handoff

> **Execution note (2026-09-27):** 1361 checks at the end (1342 when this was first recorded in a61ac11), not 1233; `.agent/` is gitignored, so HANDOFF.json was updated in place and not committed, and this plan file was committed with STATUS.md. Work beyond the plan, recorded in STATUS.md: the export crash fix (7bfce3e, 00dba5c, fabefbe) and the whole-pass review fixes (a369b62, 0059a31, 2d04dd2, 54764b6, 1e86161); after 1e86161 the record was brought up to date and Step 1 run again at it.

**Files:**
- Modify: `STATUS.md`
- Modify: `.agent/HANDOFF.json`

- [x] **Step 1: Full verification pass**

```bash
./Tools/run-harness.sh
```
Expected: `ALL CHECKS PASSED` (1233).

```bash
xcodebuild -project LidarExplorer.xcodeproj -scheme LidarExplorer \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
  -derivedDataPath build-review/DerivedData build
xcodebuild -project LidarExplorer.xcodeproj -scheme LidarExplorer -configuration Release \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
  -derivedDataPath build-review/DerivedData build
```
Expected: `** BUILD SUCCEEDED **` twice, zero concurrency errors.

Simulator light/dark screenshots of the main screen (`xcrun simctl ui booted appearance light` / `dark`, screenshot each): every panel rim visible in both.

- [x] **Step 2: Update `STATUS.md`**

Add a bullet under the current work section (follow the file's existing style): the five UI polish changes (glass treatment + which panels, sun dial replacing the slider, evacuation, top bar regroup, pencil feedback), the harness count (1233), and the open device checks (Pencil ring/notice — Simulator has no Pencil; dial feel and evacuation feel on hardware). Do not restate what the commits already say; record what is verified and what is not.

- [x] **Step 3: Update `.agent/HANDOFF.json`**

Per the repo protocol: `active_task` (UI polish plan complete through Task 8), `modified_files`, `verification_command` (`./Tools/run-harness.sh`), `failing_assertions` (none, or the truth), and under `unverified`: the Pencil Pro ring/squeeze pill on a physical iPad (HUMAN_DO_THIS.md item added in Task 7), and the dial/evacuation feel on hardware. `next_instruction`: point at the remaining audit findings NOT in this plan — settings sliders to a non-modal tray, waypoint/bookmark alerts to sheets, custom annotation glyphs replacing balloon markers, 3D orbit momentum, wipe divider contrast.

- [x] **Step 4: Commit**

```bash
git add STATUS.md .agent/HANDOFF.json
git commit -m "agent-checkpoint: record the UI polish pass in STATUS and the handoff, with the device checks still open

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Explicitly out of scope (next plan candidates, from the same audit)

Settings-sheet live sliders → non-modal tray with `presentationBackgroundInteraction`; waypoint/bookmark `.alert` forms → sheets; custom `MKAnnotationView` glyphs replacing balloon markers; 3D orbit momentum + animated reset; wipe divider adaptive contrast + 44 pt handle; per-drag haptic generator allocation in the wipe overlay; markup toolbar full re-layout (open TODO in HANDOFF).
