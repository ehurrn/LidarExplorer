# User Flow & Map HUD Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Modernize LidarExplorer's first-run experience by replacing the dense text manual with a 2-slide visual primer and redesigning the map overlay into an unobtrusive floating bottom HUD and modal settings sheet.

**Architecture:** Deconstruct the bulky overlay sidebar into focused, single-purpose SwiftUI components: `VisualPrimerView` (interactive 2-slide bare-earth guide), `ViewerTopBarView` (compact elevation readout, help, and settings triggers), `ViewerBottomDockView` (floating thumb-scrubber for sun azimuth and shading modes), and `ViewerSettingsSheetView` (modal settings). Coordinate Google UMP / AdService initialization to trigger safely after first-launch primer dismissal.

**Tech Stack:** Swift 6, SwiftUI, CoreLocation, MapKit, StoreKit, GoogleMobileAds.

---

### Task 1: Create `VisualPrimerView`

**Files:**
- Create: `LidarExplorer/Presentation/VisualPrimerView.swift`
- Reference: `docs/superpowers/specs/2026-09-07-user-flow-and-hud-redesign.md`

- [ ] **Step 1: Write `VisualPrimerView.swift`**

Create `LidarExplorer/Presentation/VisualPrimerView.swift` with a 2-page horizontal `TabView`, visual illustrations for bare-earth stripping and dynamic relief relighting, and a primary "Start Exploring" button.

```swift
//
//  VisualPrimerView.swift
//  LidarExplorer
//
//  Visual guide explaining bare-earth lidar and relief shading.
//

import SwiftUI

/// A 2-slide visual primer demonstrating bare-earth lidar and dynamic relighting.
///
/// Shown automatically on first launch and accessible anytime from the help button.
public struct VisualPrimerView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var currentPage = 0

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    slideOne.tag(0)
                    slideTwo.tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                bottomBar
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Lidar Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Slide 1: Bare-Earth Concept

    private var slideOne: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .frame(width: 180, height: 130)
                    .shadow(color: .black.opacity(0.08), radius: 10, y: 4)

                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "tree.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.green.opacity(0.4))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.secondary)
                        Image(systemName: "mountain.2.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.blue)
                    }

                    Text("Foliage Stripped")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 8) {
                Text("See Beneath the Canopy")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)

                Text("USGS 3DEP bare-earth lidar digitally strips away vegetation and structures, revealing subtle earthworks, foundations, fault lines, and terrain contours hidden to aerial photography.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()
        }
        .padding(.bottom, 20)
    }

    // MARK: - Slide 2: Dynamic Relighting

    private var slideTwo: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .frame(width: 180, height: 130)
                    .shadow(color: .black.opacity(0.08), radius: 10, y: 4)

                VStack(spacing: 10) {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)

                    Text("Raking Light Shadows")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 8) {
                Text("Relighting the Ground")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)

                Text("Ridges and ditches parallel to the sun cast no shadows and vanish. Raking light across them makes subtle relief pop immediately. Sweep the sun slider to uncover hidden contours.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()
        }
        .padding(.bottom, 20)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 12) {
            Divider()

            Button {
                dismiss()
            } label: {
                Text("Start Exploring")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }
}
```

- [ ] **Step 2: Verify compilation**

Run: `xcodebuild -scheme LidarExplorer -destination "platform=iOS Simulator,name=iPhone 17 Pro" build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add LidarExplorer/Presentation/VisualPrimerView.swift
git commit -m "feat(presentation): add VisualPrimerView 2-slide guide"
```

---

### Task 2: Create `ViewerTopBarView`

**Files:**
- Create: `LidarExplorer/Presentation/ViewerTopBarView.swift`
- Modify: `LidarExplorer/Presentation/TerrainViewerView.swift` (integrate readout styling)

- [ ] **Step 1: Write `ViewerTopBarView.swift`**

Extract and modernize the top bar into a glass capsule elevation readout and two circular glass buttons (`?` help and `⚙️` settings):

```swift
//
//  ViewerTopBarView.swift
//  LidarExplorer
//
//  Top bar containing compact elevation readout and action buttons.
//

import SwiftUI

public struct ViewerTopBarView: View {

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
        HStack(alignment: .center) {
            elevationCapsule
            Spacer()
            actionButtons
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Elevation Capsule

    private var elevationCapsule: some View {
        HStack(spacing: 6) {
            Image(systemName: "mountain.2.fill")
                .font(.caption2)
                .foregroundStyle(.tint)

            if let elevation = model.elevationReadout {
                Text(model.formattedElevation(elevation))
                    .font(.caption.weight(.semibold))
            } else {
                Text("Tap map for elevation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                showsPrimer = true
            } label: {
                Image(systemName: "questionmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            .accessibilityLabel("Lidar Guide")

            Button {
                showsSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            .accessibilityLabel("Settings")
        }
    }
}
```

- [ ] **Step 2: Verify compilation**

Run: `xcodebuild -scheme LidarExplorer -destination "platform=iOS Simulator,name=iPhone 17 Pro" build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add LidarExplorer/Presentation/ViewerTopBarView.swift
git commit -m "feat(presentation): create ViewerTopBarView with elevation and actions"
```

---

### Task 3: Create `ViewerBottomDockView`

**Files:**
- Create: `LidarExplorer/Presentation/ViewerBottomDockView.swift`

- [ ] **Step 1: Write `ViewerBottomDockView.swift`**

Implement a floating glass dock featuring the 4-mode shading switcher, a 16ms throttled sun azimuth scrubber, and an unobtrusive activity indicator badge:

```swift
//
//  ViewerBottomDockView.swift
//  LidarExplorer
//
//  Floating dock hosting direct shading mode switcher and sun azimuth scrubber.
//

import SwiftUI

public struct ViewerBottomDockView: View {

    @Bindable var model: TerrainViewerModel

    public init(model: TerrainViewerModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 10) {
            modeRow
            azimuthRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Mode Row

    private var modeRow: some View {
        HStack(spacing: 8) {
            Picker("Shading Mode", selection: $model.shadingMode) {
                ForEach(ShadingMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if model.isDownloading || model.isRendering {
                ProgressView()
                    .controlSize(.mini)
                    .transition(.opacity.combined(with: .scale))
            }
        }
    }

    // MARK: - Azimuth Scrubber Row

    private var azimuthRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.max.fill")
                .font(.caption)
                .foregroundStyle(.orange)

            Slider(value: $model.sunAzimuth, in: 0...360, step: 1) {
                Text("Sun Direction")
            }
            .tint(.orange)

            Text(String(format: "%03.0f°", model.sunAzimuth))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

private extension ShadingMode {
    var label: String {
        switch self {
        case .multiDirectional: return "Multi-Dir"
        case .hillshade: return "Hillshade"
        case .slope: return "Slope"
        case .elevation: return "Elevation"
        }
    }
}
```

- [ ] **Step 2: Verify compilation**

Run: `xcodebuild -scheme LidarExplorer -destination "platform=iOS Simulator,name=iPhone 17 Pro" build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add LidarExplorer/Presentation/ViewerBottomDockView.swift
git commit -m "feat(presentation): create ViewerBottomDockView for mode and sun scrubbing"
```

---

### Task 4: Create `ViewerSettingsSheetView`

**Files:**
- Create: `LidarExplorer/Presentation/ViewerSettingsSheetView.swift`

- [ ] **Step 1: Write `ViewerSettingsSheetView.swift`**

Consolidate secondary terrain adjustments, basemap picker, elevation units, ad removal, and tile diagnostics into a standard iOS settings form:

```swift
//
//  ViewerSettingsSheetView.swift
//  LidarExplorer
//
//  Settings sheet for terrain adjustments, basemap styling, units, and diagnostics.
//

import StoreKit
import SwiftUI

public struct ViewerSettingsSheetView: View {

    @Bindable var model: TerrainViewerModel
    let store: StoreService
    let ads: AdService
    @Binding var showsDebug: Bool
    @Environment(\.dismiss) private var dismiss

    public init(
        model: TerrainViewerModel,
        store: StoreService,
        ads: AdService,
        showsDebug: Binding<Bool>
    ) {
        self.model = model
        self.store = store
        self.ads = ads
        self._showsDebug = showsDebug
    }

    public var body: some View {
        NavigationStack {
            Form {
                terrainSection
                basemapSection
                unitsSection
                monetizationSection
                diagnosticsSection
                attributionsSection
            }
            .navigationTitle("Terrain Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Terrain Section

    private var terrainSection: some View {
        Section("Terrain Fine-Tuning") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Sun Altitude")
                    Spacer()
                    Text(String(format: "%.0f°", model.sunAngle))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.sunAngle, in: 5...85, step: 1)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Vertical Exaggeration")
                    Spacer()
                    Text(String(format: "%.1f×", model.verticalExaggeration))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.verticalExaggeration, in: 1...5, step: 0.5)
            }
        }
    }

    // MARK: - Basemap Section

    private var basemapSection: some View {
        Section("Basemap Layer") {
            Picker("Style", selection: $model.selectedBasemap) {
                ForEach(BasemapType.allCases, id: \.self) { basemap in
                    Text(basemap.rawValue).tag(basemap)
                }
            }
        }
    }

    // MARK: - Units Section

    private var unitsSection: some View {
        Section("Elevation Units") {
            Picker("Display Units", selection: $model.elevationUnit) {
                ForEach(ElevationUnit.allCases, id: \.self) { unit in
                    Text(unit.title).tag(unit)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Monetization Section

    private var monetizationSection: some View {
        Section("Upgrades") {
            if store.hasRemoveAds {
                Label("Ads Removed", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Button {
                    Task {
                        await store.purchaseRemoveAds()
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Remove Ads")
                                .font(.body.weight(.medium))
                            Text("One-time purchase")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let price = store.removeAdsPrice {
                            Text(price)
                                .fontWeight(.semibold)
                        } else {
                            ProgressView()
                        }
                    }
                }

                Button("Restore Purchases") {
                    Task {
                        await store.restorePurchases()
                    }
                }
                .font(.footnote)
            }
        }
    }

    // MARK: - Diagnostics Section

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            Button {
                dismiss()
                showsDebug = true
            } label: {
                Label("Tile Activity Logs", systemImage: "ladybug")
            }
        }
    }

    // MARK: - Attributions Section

    private var attributionsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Elevation Data: USGS 3DEP & AWS Terrain Tiles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Basemaps: The National Map, USGS")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] **Step 2: Verify compilation**

Run: `xcodebuild -scheme LidarExplorer -destination "platform=iOS Simulator,name=iPhone 17 Pro" build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add LidarExplorer/Presentation/ViewerSettingsSheetView.swift
git commit -m "feat(presentation): create ViewerSettingsSheetView for secondary settings"
```

---

### Task 5: Refactor `TerrainViewerView` & Wire Coordinated Lifecycle

**Files:**
- Modify: `LidarExplorer/Presentation/TerrainViewerView.swift`
- Remove: deprecated `ControlPanelView` and `toggleButton` internal structures

- [ ] **Step 1: Update `TerrainViewerView.swift`**

Replace the side-panel overlay with `ViewerTopBarView` at the top and `ViewerBottomDockView` above the banner ad. Replace `OnboardingView` with `VisualPrimerView`, and wire `ViewerSettingsSheetView`:

```swift
//
//  TerrainViewerView.swift
//  LidarExplorer
//
//  The primary terrain viewer screen.
//

import CoreLocation
import MapKit
import StoreKit
import SwiftUI

public struct TerrainViewerView: View {

    @State private var model = TerrainViewerModel()
    @State private var store = StoreService()
    @State private var ads = AdService()
    @State private var showsPrimer = false
    @State private var showsSettings = false
    @State private var showsDebug = false

    /// Persisted so the primer appears automatically on first launch only.
    @AppStorage("hasSeenTerrainIntro") private var hasSeenIntro = false

    public init() {}

    public var body: some View {
        TerrainMapView(model: model)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                ViewerTopBarView(
                    model: model,
                    showsPrimer: $showsPrimer,
                    showsSettings: $showsSettings
                )
            }
            .overlay(alignment: .bottom) {
                ViewerBottomDockView(model: model)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                BannerAdSlot(isActive: ads.canShowAds && !store.hasRemoveAds)
            }
            .sheet(isPresented: $showsPrimer, onDismiss: {
                Task {
                    await ads.prepare(hasRemoveAds: store.hasRemoveAds)
                }
            }) {
                VisualPrimerView()
            }
            .sheet(isPresented: $showsSettings) {
                ViewerSettingsSheetView(
                    model: model,
                    store: store,
                    ads: ads,
                    showsDebug: $showsDebug
                )
            }
            .sheet(isPresented: $showsDebug) {
                TileDebugView(log: model.tileLog)
            }
            .task {
                model.start()
                await store.refresh()
                if !hasSeenIntro {
                    hasSeenIntro = true
                    showsPrimer = true
                } else {
                    await ads.prepare(hasRemoveAds: store.hasRemoveAds)
                }
            }
    }
}
```

- [ ] **Step 2: Clean up obsolete views if unused**

Check if `OnboardingView.swift` has any external callers. Since `VisualPrimerView` completely replaces it, remove `OnboardingView.swift`.

Run: `git rm LidarExplorer/Presentation/OnboardingView.swift`

- [ ] **Step 3: Verify compilation**

Run: `xcodebuild -scheme LidarExplorer -destination "platform=iOS Simulator,name=iPhone 17 Pro" build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add LidarExplorer/Presentation/TerrainViewerView.swift
git commit -m "feat(presentation): refactor TerrainViewerView with floating dock and top bar"
```

---

### Task 6: Full Verification & Automated Regression Suite

**Files:**
- Verify: `Tools/run-harness.sh`
- Verify: `Tools/run-live-check.sh`
- Verify: `xcodebuild` clean build

- [ ] **Step 1: Run core regression test suite**

Run: `Tools/run-harness.sh`
Expected: All 46 tests pass with 0 failures and 0 memory anomalies.

- [ ] **Step 2: Run live network verification**

Run: `Tools/run-live-check.sh`
Expected: 100% passed for live USGS 3DEP tile fetches and decoding.

- [ ] **Step 3: Run full Xcode clean build**

Run: `xcodebuild -scheme LidarExplorer -destination "platform=iOS Simulator,name=iPhone 17 Pro" clean build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit and finalize branch**

```bash
git commit --allow-empty -m "chore: verify user flow and HUD redesign suite"
```
