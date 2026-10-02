# Remove Google Mobile Ads, UMP, and StoreKit Ad Removal Implementation Plan

> **Status (2026-10-01):** complete — executed 2026-09-14, the day before this file's date (the plan was committed with Task 1), in 4df6f8b (Task 1, which also removed `xcshareddata/swiftpm/Package.resolved`), a5ac599 (Task 2), 23b9ffb (Task 3) and 63ced1c (Task 4); the README's last ads/IAP claim went in dfe11c4 (2026-09-17). Verified on the stack tip f0955ea: harness 613 PASS (the sun-control merge's checks included), not 574, and a Simulator build with no warnings in app sources (`2026-09-15-finish-merge-upload.md`, "Verified on this tip"); the iPad run waited for 2026-09-17 (11f3179) because the iPad was locked. `LidarExplorer/Monetization/` and `Config/LidarExplorer.storekit`, named below, are gone (removed by this plan); `Config/PrivacyInfo.xcprivacy` has since gained the FileTimestamp required-reason API (1197d37). Task 4 Step 6 is ticked for its commit; its `.agent/HANDOFF.json` update cannot be checked (gitignored). The `/tmp/lidar-scratch` build paths in Task 4 Step 5 are outside the repo; builds now go in `build-review/` (CLAUDE.md).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transition LidarExplorer to a paid-upfront release model by completely removing Google Mobile Ads SDK, Google User Messaging Platform (UMP) consent SDK, banner ad views, AdService, StoreKit 2 "Remove Ads" in-app purchase, and the StoreService entitlement coordinator.

**Architecture:** Remove the SPM package `swift-package-manager-google-mobile-ads` and all framework linkages from `project.pbxproj`. Strip GAD and SKAdNetwork configuration from `Info.plist`, device ID tracking from `PrivacyInfo.xcprivacy`, and the StoreKit scheme configuration from `LidarExplorer.xcscheme`. Delete the `LidarExplorer/Monetization` module (`AdService.swift`, `BannerAdView.swift`, `StoreService.swift`) and remove `Log.ads` and `Log.store` logging categories. Cleanly remove `BannerAdSlot`, ad-state lifecycle hooks, and the `Upgrades` purchase section from `TerrainViewerView` and `ViewerSettingsSheetView`.

**Tech Stack:** Swift 6 (Strict Concurrency), SwiftUI, MapKit, Metal, Xcode 16.

---

### Task 1: Clean Project Configuration, Privacy Manifest, and Build Dependencies

**Files:**
- Modify: `LidarExplorer.xcodeproj/project.pbxproj:10,34,88,119,377-393`
- Modify: `LidarExplorer.xcodeproj/xcshareddata/xcschemes/LidarExplorer.xcscheme:53-55`
- Modify: `Config/Info.plist:5-13`
- Modify: `Config/PrivacyInfo.xcprivacy:9-23`
- Delete: `Config/LidarExplorer.storekit`

- [x] **Step 1: Remove StoreKit configuration reference from scheme**
  In `LidarExplorer.xcodeproj/xcshareddata/xcschemes/LidarExplorer.xcscheme`, delete lines 53-55:
  ```xml
        <StoreKitConfigurationFileReference
           identifier = "../../../Config/LidarExplorer.storekit">
        </StoreKitConfigurationFileReference>
  ```

- [x] **Step 2: Delete `Config/LidarExplorer.storekit`**
  Remove `Config/LidarExplorer.storekit` from disk.

- [x] **Step 3: Strip GADApplicationIdentifier and SKAdNetworkItems from Info.plist**
  In `Config/Info.plist`, replace the dictionary content with an empty dict `<dict/>`.

- [x] **Step 4: Remove DeviceID from PrivacyInfo.xcprivacy**
  In `Config/PrivacyInfo.xcprivacy`, replace `NSPrivacyCollectedDataTypes` array with an empty `<array/>`.

- [x] **Step 5: Remove GoogleMobileAds package and framework linkage from project.pbxproj**
  In `LidarExplorer.xcodeproj/project.pbxproj`:
  - Delete `115E0BAF2F1D9D0D0073904F /* GoogleMobileAds in Frameworks */ = {isa = PBXBuildFile; productRef = 115E0BAE2F1D9D0D0073904F /* GoogleMobileAds */; };`
  - In `PBXFrameworksBuildPhase` (`110544132EEBD91900D92854 /* Frameworks */`), empty `files = ();`
  - In `PBXNativeTarget` (`110544152EEBD91900D92854 /* LidarExplorer */`), empty `packageProductDependencies = ();`
  - In `PBXProject` (`1105440E2EEBD91900D92854 /* Project object */`), empty `packageReferences = ();`
  - Delete the entire `/* Begin XCRemoteSwiftPackageReference section */ ... /* End XCRemoteSwiftPackageReference section */`
  - Delete the entire `/* Begin XCSwiftPackageProductDependency section */ ... /* End XCSwiftPackageProductDependency section */`

- [x] **Step 6: Verify project file syntax and build settings**
  Run: `plutil -lint Config/Info.plist Config/PrivacyInfo.xcprivacy`
  Expected: OK

- [x] **Step 7: Commit project configuration cleanup**
  ```bash
  git add Config/Info.plist Config/PrivacyInfo.xcprivacy LidarExplorer.xcodeproj/
  git rm Config/LidarExplorer.storekit
  git commit -m "agent-checkpoint: strip GoogleMobileAds and StoreKit configuration from project"
  ```

---

### Task 2: Delete Monetization Module and Remove Diagnostic Categories

**Files:**
- Delete: `LidarExplorer/Monetization/AdService.swift`
- Delete: `LidarExplorer/Monetization/BannerAdView.swift`
- Delete: `LidarExplorer/Monetization/StoreService.swift`
- Modify: `LidarExplorer/Core/Diagnostics/Log.swift:44-49`

- [x] **Step 1: Delete files in `LidarExplorer/Monetization/`**
  Remove `AdService.swift`, `BannerAdView.swift`, and `StoreService.swift`. Delete directory `LidarExplorer/Monetization`.

- [x] **Step 2: Remove `Log.store` and `Log.ads` from `Log.swift`**
  In `LidarExplorer/Core/Diagnostics/Log.swift`, remove:
  ```swift
      /// Purchases, entitlements, and StoreKit transactions.
      public static let store = Logger(subsystem: subsystem, category: "Store")

      /// Ad SDK initialisation, consent, and ad lifecycle.
      public static let ads = Logger(subsystem: subsystem, category: "Ads")
  ```

- [x] **Step 3: Commit deletion of Monetization module**
  ```bash
  git rm -r LidarExplorer/Monetization
  git add LidarExplorer/Core/Diagnostics/Log.swift
  git commit -m "agent-checkpoint: delete Monetization module and logging categories"
  ```

---

### Task 3: Remove Ads and StoreKit from UI Presentation

**Files:**
- Modify: `LidarExplorer/Presentation/ViewerSettingsSheetView.swift`
- Modify: `LidarExplorer/Presentation/TerrainViewerView.swift`

- [x] **Step 1: Clean `ViewerSettingsSheetView.swift`**
  - Remove `import StoreKit`
  - Remove properties `var store: StoreService` and `var ads: AdService`
  - Update `init(model: TerrainViewerModel, showsDebug: Binding<Bool>, showsHistoricalImporter: Binding<Bool> = .constant(false), showsSoilImporter: Binding<Bool> = .constant(false))`
  - In `Form`, remove `upgradesSection`
  - Delete `private var upgradesSection: some View { ... }`

- [x] **Step 2: Clean `TerrainViewerView.swift`**
  - Remove `import StoreKit`
  - Remove `@State private var store = StoreService()`
  - Remove `@State private var ads = AdService()`
  - In bottom dock container, remove `BannerAdSlot(isActive: ads.canShowAds && !store.hasRemoveAds)`
  - In `.sheet(isPresented: $showsPrimer)` remove `onDismiss: { Task { await ads.prepare(hasRemoveAds: store.hasRemoveAds) } }`
  - In `.sheet(isPresented: $showsSettings)`, update invocation to:
    ```swift
    ViewerSettingsSheetView(
        model: model,
        showsDebug: $showsDebug,
        showsHistoricalImporter: $showsHistoricalImporter,
        showsSoilImporter: $showsSoilImporter
    )
    ```
  - Remove `.onChange(of: store.hasRemoveAds)`
  - In `.task`, remove `await store.refresh()` and `await ads.prepare(...)`

- [x] **Step 3: Verify build for iOS Simulator**
  Run: `xcodebuild -project LidarExplorer.xcodeproj -scheme LidarExplorer -destination "generic/platform=iOS Simulator" -configuration Debug CODE_SIGNING_ALLOWED=NO build`
  Expected: `** BUILD SUCCEEDED **` with 0 warnings in modified files.

- [x] **Step 4: Commit UI presentation changes**
  ```bash
  git add LidarExplorer/Presentation/ViewerSettingsSheetView.swift LidarExplorer/Presentation/TerrainViewerView.swift
  git commit -m "agent-checkpoint: remove ad slot and store upgrades from UI"
  ```

---

### Task 4: Documentation, Verification, and Physical Device Validation

**Files:**
- Modify: `README.md`
- Modify: `STATUS.md`

- [x] **Step 1: Update README.md**
  - Remove `StoreService` and `AdService` from the architecture diagram and `@MainActor` description.
  - Remove the "Monetization & Privacy Architecture" section.
  - Remove `Monetization/` from directory structure tree.
  - Remove `GoogleMobileAds`, `UserMessagingPlatform`, and `StoreKit` from dependencies.

- [x] **Step 2: Update STATUS.md**
  - Record the removal of Google Mobile Ads and StoreKit for paid-upfront release.

- [x] **Step 3: Run offline regression harness**
  Run: `./Tools/run-harness.sh`
  Expected: `ALL CHECKS PASSED (574 PASS / 0 FAIL)`

- [x] **Step 4: Codebase audit for legacy strings**
  Run: `git grep -Ei "(GoogleMobileAds|GADApplicationIdentifier|BannerView)"`
  Expected: Only historical documentation/plans in `Archive/` or `docs/superpowers/plans/` (no hits in active code, project files, or current README).

- [x] **Step 5: Physical device build & run**
  Build:
  `xcodebuild -project LidarExplorer.xcodeproj -scheme LidarExplorer -destination "id=00008142-001604881E2B801C" -configuration Debug -derivedDataPath /tmp/lidar-scratch/dd-device -allowProvisioningUpdates build`
  Install:
  `xcrun devicectl device install app --device 00008142-001604881E2B801C /tmp/lidar-scratch/dd-device/Build/Products/Debug-iphoneos/LidarExplorer.app`
  Launch:
  `xcrun devicectl device process launch --device 00008142-001604881E2B801C com.detsom.LidarExplorer`
  Expected: App launches cleanly on physical iPad without ads or storekit overhead.

- [x] **Step 6: Update `.agent/HANDOFF.json` and commit**
  ```bash
  git add README.md STATUS.md
  git commit -m "agent-checkpoint: remove Google Mobile Ads, UMP, and StoreKit for paid release"
  ```
