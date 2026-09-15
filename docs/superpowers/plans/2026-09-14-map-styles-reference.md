# Map Styles Reference Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the long "Map Styles" page inside the intro carousel with a searchable Map Styles reference that opens beside the map (iPad inspector column, compact-width sheet) from the top-bar **?** button.

**Architecture:** Guide text and search rules live in Core (`ReliefStyleGuide.swift`) where the offline harness checks them. A new SwiftUI view, `MapStylesReferenceView`, renders list → detail inside a `NavigationStack` and is attached to `TerrainViewerView` with `.inspector`. The intro (`VisualPrimerView`) returns to its original two slides and is replayed from inside the panel, never from the map screen's root sheet.

**Tech Stack:** Swift 6 (strict concurrency, default MainActor isolation), SwiftUI (iOS 27: `.inspector`, `.searchable`, `ContentUnavailableView`), offline harness `Tools/run-harness.sh`.

**Spec:** `docs/superpowers/specs/2026-09-14-map-styles-reference-design.md` · **Review:** `docs/superpowers/reviews/2026-09-14-map-styles-reference-review.md`

**Branch:** `feat/style-guide` (stacked on `fix/fractional-tile-scale`). Commit messages use `agent-checkpoint: <description>` per `CLAUDE.md`, ending with the `Co-Authored-By` trailer.

---

## File map

| File | Change | Responsibility |
|---|---|---|
| `LidarExplorer/Core/Raster/ReliefStyleGuide.swift` | Modify (append) | Search: `styles(in:matching:)`, `overlays(matching:)`, `ReliefStyle.guideSearchText` |
| `Tools/ViewerHarness/main.swift` | Modify (`=== Map style guide ===` block) | Search checks |
| `LidarExplorer/Presentation/VisualPrimerView.swift` | Restore from `d6d236f` | Two-slide intro only |
| `LidarExplorer/Presentation/MapStylesReferenceView.swift` | Create | List, search, detail pages, Replay Intro sheet |
| `LidarExplorer/Presentation/TerrainViewerView.swift` | Modify | `showsStyleReference` state; `.inspector` |
| `LidarExplorer/Presentation/ViewerTopBarView.swift` | Modify | **?** toggles panel; readout truncates; buttons keep priority |
| `LidarExplorer/MapLayer/TerrainMapView.swift` | Modify (`reloadTerrain`) | Debug log line used to count reloads during verification |

The Xcode project uses folder-synchronised groups, so new files under `LidarExplorer/` join the app target automatically. The harness compiles an explicit file list; `ReliefStyleGuide.swift` is already in it.

---

### Task 1: Search in `ReliefStyleGuide` (Core, test-first)

**Files:**
- Modify: `Tools/ViewerHarness/main.swift` (inside the `do { … }` block after `print("\n=== Map style guide ===")`)
- Modify: `LidarExplorer/Core/Raster/ReliefStyleGuide.swift` (append at end of file)

- [ ] **Step 1: Write the failing checks**

In `Tools/ViewerHarness/main.swift`, find this existing check (last one in the Map style guide block):

```swift
    check("the guide explains the shared overlays", !ReliefStyleGuide.overlays.isEmpty
          && ReliefStyleGuide.overlays.allSatisfy { !$0.name.isEmpty && !$0.explanation.isEmpty })
```

Insert directly after it, still inside the same `do { }`:

```swift

    // Search, as the Map Styles reference panel uses it.
    func found(_ query: String) -> Set<ReliefStyle> {
        Set(ReliefStyleGuide.sections.flatMap { ReliefStyleGuide.styles(in: $0, matching: query) })
    }
    check("a blank search lists every style",
          found("").count == ReliefStyle.allCases.count && found("   ").count == ReliefStyle.allCases.count)
    check("searching \"rem\" finds Relative Elevation",
          found("rem").contains(.relativeElevation), "\(found("rem").map(\.displayName))")
    let ditch = found("ditch")
    check("searching \"ditch\" finds Local Relief and only styles whose searched text mentions ditches",
          ditch.contains(.localRelief) && ditch.allSatisfy { style in
              style.guideSearchText.contains { $0.localizedStandardContains("ditch") }
          }, "\(ditch.map(\.displayName))")
    check("search skips the Adjust-with text, so \"settings\" does not match every style",
          found("settings").count < ReliefStyle.allCases.count, "\(found("settings").count) matched")
    check("a nonsense search finds nothing",
          found("zzqx-no-such-style").isEmpty && ReliefStyleGuide.overlays(matching: "zzqx-no-such-style").isEmpty)
    check("overlays are searchable by name and explanation",
          ReliefStyleGuide.overlays(matching: "contour").map(\.name) == ["Contour Lines"]
          && ReliefStyleGuide.overlays(matching: "amber").map(\.name) == ["Habitation Potential Mask"])
    check("results keep dock order within a section",
          ReliefStyleGuide.sections.allSatisfy { ReliefStyleGuide.styles(in: $0, matching: "") == $0.styles })
```

- [ ] **Step 2: Run the harness to verify it fails**

Run: `./Tools/run-harness.sh`
Expected: compile failure mentioning `styles(in:matching:)`, `overlays(matching:)` or `guideSearchText` (no such member).

- [ ] **Step 3: Implement search**

Append to the end of `LidarExplorer/Core/Raster/ReliefStyleGuide.swift`:

```swift

public extension ReliefStyleGuide {

    /// The styles in `section` whose guide text matches `query`, in dock
    /// order; every style in the section when the query is blank.
    static func styles(in section: Section, matching query: String) -> [ReliefStyle] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return section.styles }
        return section.styles.filter { style in
            style.guideSearchText.contains { $0.localizedStandardContains(needle) }
        }
    }

    /// Overlays whose name or explanation matches `query`; every overlay when
    /// the query is blank.
    static func overlays(matching query: String) -> [Overlay] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return Self.overlays }
        return Self.overlays.filter {
            $0.name.localizedStandardContains(needle) || $0.explanation.localizedStandardContains(needle)
        }
    }
}

extension ReliefStyle {

    /// The text the Map Styles reference searches.
    ///
    /// Leaves out the Adjust-with lines: nearly all of them say "Settings" or
    /// "slider", which would make those words match almost every style.
    var guideSearchText: [String] {
        let entry = guide
        return [displayName, dockLabel, entry.shows, entry.reading, entry.bestFor]
    }
}
```

- [ ] **Step 4: Run the harness to verify it passes**

Run: `./Tools/run-harness.sh`
Expected: `ALL CHECKS PASSED`; the Map style guide block shows 11 PASS lines (4 existing + 7 new). Total goes from 567 to 574.

- [ ] **Step 5: Commit**

```bash
git add LidarExplorer/Core/Raster/ReliefStyleGuide.swift Tools/ViewerHarness/main.swift
git commit -m "agent-checkpoint: search the map style guide

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Restore the two-slide intro

**Files:**
- Modify: `LidarExplorer/Presentation/VisualPrimerView.swift` (restore the version from commit `d6d236f`)

The Map Styles page, its toolbar button and `StyleGuideCard` were added in `61a6ee1`; nothing else uses them.

- [ ] **Step 1: Restore the file**

```bash
git checkout d6d236f -- LidarExplorer/Presentation/VisualPrimerView.swift
```

- [ ] **Step 2: Verify the restore**

Run: `grep -c "stylesPage\|StyleGuideCard\|Map Styles" LidarExplorer/Presentation/VisualPrimerView.swift; wc -l < LidarExplorer/Presentation/VisualPrimerView.swift`
Expected: `0` then `152`.

- [ ] **Step 3: Commit** (the harness does not compile Presentation; the app build in Task 5 covers it)

```bash
git add LidarExplorer/Presentation/VisualPrimerView.swift
git commit -m "agent-checkpoint: return the intro to its two slides

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: `MapStylesReferenceView`

**Files:**
- Create: `LidarExplorer/Presentation/MapStylesReferenceView.swift`

- [ ] **Step 1: Create the view**

```swift
//
//  MapStylesReferenceView.swift
//  LidarExplorer
//
//  Searchable reference for every map style and overlay, shown beside the map.
//

import SwiftUI

/// What each map style shows and when to use it.
///
/// ``TerrainViewerView`` presents this as an inspector: a trailing column on
/// iPad, a sheet on compact widths. Because it may itself be a sheet, the intro
/// it replays is presented from here. A request to the map screen's root
/// `.sheet` would be dropped while this sheet is up.
public struct MapStylesReferenceView: View {

    let model: TerrainViewerModel
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var path: [Destination] = []
    @State private var showsIntro = false

    private enum Destination: Hashable {
        case style(ReliefStyle)
        case overlay(String)
    }

    public init(model: TerrainViewerModel, isPresented: Binding<Bool>) {
        self.model = model
        self._isPresented = isPresented
    }

    public var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                list
                    // Reopening starts at the list, scrolled to the style in use.
                    .onAppear { proxy.scrollTo(model.style, anchor: .center) }
            }
            .navigationTitle("Map Styles")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search styles")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close Map Styles")
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .style(let style):
                    StyleDetailView(model: model, style: style)
                case .overlay(let name):
                    if let overlay = ReliefStyleGuide.overlays.first(where: { $0.name == name }) {
                        OverlayDetailView(overlay: overlay)
                    }
                }
            }
        }
        .sheet(isPresented: $showsIntro) {
            VisualPrimerView()
        }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasResults: Bool {
        ReliefStyleGuide.sections.contains { !ReliefStyleGuide.styles(in: $0, matching: query).isEmpty }
            || !ReliefStyleGuide.overlays(matching: query).isEmpty
    }

    private var list: some View {
        List {
            ForEach(ReliefStyleGuide.sections) { section in
                let styles = ReliefStyleGuide.styles(in: section, matching: query)
                if !styles.isEmpty {
                    Section {
                        ForEach(styles) { style in
                            NavigationLink(value: Destination.style(style)) {
                                StyleRow(style: style, isInUse: model.style == style)
                            }
                            .id(style)
                        }
                    } header: {
                        Text(section.title)
                    } footer: {
                        Text(section.subtitle)
                    }
                }
            }

            let overlays = ReliefStyleGuide.overlays(matching: query)
            if !overlays.isEmpty {
                Section("Overlays") {
                    ForEach(overlays) { overlay in
                        NavigationLink(overlay.name, value: Destination.overlay(overlay.name))
                    }
                }
            }

            if !isSearching {
                Section {
                    Button("Replay Intro") { showsIntro = true }
                }
            }
        }
        .overlay {
            if !hasResults {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}

// MARK: - Rows

private struct StyleRow: View {
    let style: ReliefStyle
    let isInUse: Bool

    var body: some View {
        HStack(spacing: 10) {
            StyleChip(style: style)
            Text(style.displayName)
            Spacer(minLength: 8)
            if isInUse {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isInUse ? "In use" : "")
    }
}

/// The style's dock chip label, styled like a chip.
private struct StyleChip: View {
    let style: ReliefStyle

    var body: some View {
        Text(style.dockLabel)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }
}

// MARK: - Detail pages

private struct StyleDetailView: View {
    let model: TerrainViewerModel
    let style: ReliefStyle

    var body: some View {
        let entry = style.guide
        let isInUse = model.style == style
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    StyleChip(style: style)
                    Text(style.displayName)
                        .font(.title3.weight(.semibold))
                }
                Text(entry.shows)
                GuideParagraph(title: "How to read it", text: entry.reading)
                GuideParagraph(title: "Best for", text: entry.bestFor)
                if !entry.controls.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Adjust with")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(entry.controls, id: \.self) { control in
                            Label(control, systemImage: "slider.horizontal.3")
                                .font(.subheadline)
                        }
                    }
                }
                Button {
                    model.style = style
                } label: {
                    Label(isInUse ? "In Use" : "Use This Style",
                          systemImage: isInUse ? "checkmark.circle.fill" : "map")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isInUse)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(style.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct OverlayDetailView: View {
    let overlay: ReliefStyleGuide.Overlay

    var body: some View {
        ScrollView {
            Text(overlay.explanation)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(overlay.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct GuideParagraph: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
        }
    }
}
```

- [ ] **Step 2: Build for the Simulator to verify it compiles**

```bash
xcodebuild -project LidarExplorer.xcodeproj -scheme LidarExplorer \
  -destination "platform=iOS Simulator,id=1E25EA1A-124E-48BF-BDFB-EC688EB84934" \
  -configuration Debug -derivedDataPath "$SCRATCH/dd-sim" CODE_SIGNING_ALLOWED=NO build > "$SCRATCH/xb-sim.log" 2>&1
grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$SCRATCH/xb-sim.log"
```

(`$SCRATCH` is the session scratchpad directory.) Expected: `** BUILD SUCCEEDED **`. The view is unused until Task 4, which is fine.

- [ ] **Step 3: Commit**

```bash
git add LidarExplorer/Presentation/MapStylesReferenceView.swift
git commit -m "agent-checkpoint: Map Styles reference view

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Open the reference from **?** beside the map

**Files:**
- Modify: `LidarExplorer/Presentation/TerrainViewerView.swift`
- Modify: `LidarExplorer/Presentation/ViewerTopBarView.swift`
- Modify: `LidarExplorer/MapLayer/TerrainMapView.swift`

- [ ] **Step 1: `TerrainViewerView` state and inspector**

After `@State private var showsPrimer = false` add:

```swift
    @State private var showsStyleReference = false
```

In the top bar call, replace:

```swift
            ViewerTopBarView(
                model: model,
                showsPrimer: $showsPrimer,
                showsSettings: $showsSettings
            )
```

with:

```swift
            ViewerTopBarView(
                model: model,
                showsStyleReference: $showsStyleReference,
                showsSettings: $showsSettings
            )
```

Directly before the first `.fileImporter(` (the one with `isPresented: $showsHistoricalImporter`), insert:

```swift
        // Attached outside both safe-area insets, so the top bar and dock
        // narrow with the map when the panel opens beside it.
        .inspector(isPresented: $showsStyleReference) {
            MapStylesReferenceView(model: model, isPresented: $showsStyleReference)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
                .presentationDetents([.medium, .large])
        }
```

Leave `.sheet(isPresented: $showsPrimer, …)` and the first-launch `.task` untouched.

- [ ] **Step 2: `ViewerTopBarView`**

Replace:

```swift
    @Bindable var model: TerrainViewerModel
    @Binding var showsPrimer: Bool
    @Binding var showsSettings: Bool

    public init(
        model: TerrainViewerModel,
        showsPrimer: Binding<Bool>,
        showsSettings: Binding<Bool>
    ) {
        self.model = model
        self._showsPrimer = showsPrimer
        self._showsSettings = showsSettings
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            elevationCapsule
            Spacer()
            actionButtons
        }
```

with:

```swift
    @Bindable var model: TerrainViewerModel
    @Binding var showsStyleReference: Bool
    @Binding var showsSettings: Bool

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
            Spacer(minLength: 0)
            // With the Map Styles panel open the bar can be narrower than its
            // content (iPad Pro 11" portrait); the readout truncates first.
            actionButtons
                .layoutPriority(1)
        }
```

Replace:

```swift
            Text(readoutText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
```

with:

```swift
            Text(readoutText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
```

Replace:

```swift
            Button {
                showsPrimer = true
            } label: {
                Image(systemName: "questionmark")
```

with:

```swift
            Button {
                showsStyleReference.toggle()
            } label: {
                Image(systemName: "questionmark")
```

and replace `.accessibilityLabel("Lidar Guide")` with `.accessibilityLabel("Map Styles")`.

- [ ] **Step 3: Reload log line (verification aid)**

In `LidarExplorer/MapLayer/TerrainMapView.swift`, replace:

```swift
            guard let overlay = terrainOverlay,
                  let renderer = map.renderer(for: overlay) as? MKTileOverlayRenderer
            else { return }
            renderer.reloadData()
```

with:

```swift
            guard let overlay = terrainOverlay,
                  let renderer = map.renderer(for: overlay) as? MKTileOverlayRenderer
            else { return }
            Log.ui.debug("Terrain tiles reloaded")
            renderer.reloadData()
```

- [ ] **Step 4: Harness and Simulator build**

Run: `./Tools/run-harness.sh` → expected `ALL CHECKS PASSED` (574).
Run the Task 3 Step 2 `xcodebuild` command → expected `** BUILD SUCCEEDED **`, and
`grep -E "warning:" "$SCRATCH/xb-sim.log" | grep -E "MapStylesReferenceView|TerrainViewerView|ViewerTopBarView|TerrainMapView|VisualPrimerView|ReliefStyleGuide"` prints nothing new.

- [ ] **Step 5: Commit**

```bash
git add LidarExplorer/Presentation/TerrainViewerView.swift LidarExplorer/Presentation/ViewerTopBarView.swift LidarExplorer/MapLayer/TerrainMapView.swift
git commit -m "agent-checkpoint: open Map Styles beside the map from the ? button

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Verify on Simulators

Simulators: iPad Pro 13" (M5) `1E25EA1A-124E-48BF-BDFB-EC688EB84934`, iPad Pro 11" (M5) `A45411EC-2055-4615-961B-AB5C354B69AF`, iPhone 17 Pro `E7CDF071-DE02-4C9C-9867-F4DB63262EBE`. One Simulator build (Task 3 Step 2) installs on all three.

For each device: `xcrun simctl boot <id>` (ignore "already booted"), `xcrun simctl install <id> "$SCRATCH/dd-sim/Build/Products/Debug-iphonesimulator/LidarExplorer.app"`, `xcrun simctl launch <id> com.detsom.LidarExplorer`, dismiss the first-launch intro with **Done**, then screenshot with `xcrun simctl io <id> screenshot <file>.png` (or the Simulator control tool) and look at the image.

- [ ] **Step 1: iPad Pro 11", portrait (review Major 2).** Tap **?**. Screenshot: the panel sits beside the map and all seven top-bar buttons are fully visible. Tap the eye button and then the map, so the readout shows its viewshed text; screenshot again with the panel open. Buttons still fully visible, and the readout truncates with "…" rather than wrapping.
- [ ] **Step 2: iPad Pro 13".** Tap **?** → Micro-Topography → **Local Relief**. Screenshot the detail page. Tap **Use This Style**: the dock's **LRM** chip becomes selected and the button reads **In Use**. Go back: the LRM row carries the checkmark. Search "ditch": the list filters. Search "zzqx": the empty-results view appears. Close with ✕, reopen: the list shows, scrolled to LRM.
- [ ] **Step 3: iPhone 17 Pro (review Major 1).** Tap **?**: a medium-height sheet. Tap **Replay Intro**: the intro sheet appears on top of the panel (screenshot). **Done** returns to the panel.
- [ ] **Step 4: Elevation reload count (review Minor).** On the iPad Pro 11", pick the **Elevation** chip and wait for tiles. Start
  `xcrun simctl spawn A45411EC-2055-4615-961B-AB5C354B69AF log stream --level debug --predicate 'subsystem == "com.detsom.LidarExplorer" AND eventMessage CONTAINS "Terrain tiles reloaded"'`
  in the background, open and close the panel once, wait 2 s, and stop the stream. Expected: at most 1 `Terrain tiles reloaded` line. If there are more, stop and report. The spec's contingency (excluding inspector-driven resizes from the elevation-range refresh) needs its own change.

---

### Task 6: Device run, docs, handoff

- [ ] **Step 1: Device build and install**

```bash
xcodebuild -project LidarExplorer.xcodeproj -scheme LidarExplorer -destination "id=00008142-001604881E2B801C" \
  -configuration Debug -derivedDataPath "$SCRATCH/dd" -allowProvisioningUpdates build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
xcrun devicectl device install app --device 00008142-001604881E2B801C "$SCRATCH/dd/Build/Products/Debug-iphoneos/LidarExplorer.app"
```

Expected: `** BUILD SUCCEEDED **`, then `App installed`. Launch with
`DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE=YES xcrun devicectl device process launch --device 00008142-001604881E2B801C --console --terminate-existing com.detsom.LidarExplorer`
in the background. If SpringBoard refuses with a trust or code-signature error (seen once on 2026-09-14), ask the user to open the app from the home screen instead.

- [ ] **Step 2: Update `STATUS.md`**

Add a bullet under "Map & UI integration":

```markdown
- Map Styles reference: the top-bar **?** opens a searchable panel beside the map (sheet on compact widths) explaining every style and overlay, with **Use This Style**; the intro is first-launch only and replayable from the panel. Guide text and search live in `Core/Raster/ReliefStyleGuide.swift` (harness-checked).
```

- [ ] **Step 3: Update `.agent/HANDOFF.json`** (not tracked in git): set `active_task` to the state after verification, `harness_status` to the latest count, and `next_instruction` to "Ask the user before pushing `fix/fractional-tile-scale` and `feat/style-guide`; then AdMob removal, then compass placement."

- [ ] **Step 4: Commit**

```bash
git add STATUS.md
git commit -m "agent-checkpoint: record the Map Styles reference in STATUS

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```
