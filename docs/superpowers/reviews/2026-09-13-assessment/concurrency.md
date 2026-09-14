# Subsystem Assessment: Concurrency & Invalidation Race Conditions

**Subsystem Key:** `concurrency`  
**Review Items:** §4  
**Date:** 2026-09-13  
**Status:** Completed & Empirically Verified  

---

## 1. Executive Summary

| Review Item | Empirical Finding | Verdict | Action Required |
|---|---|---|---|
| **§4: Generation Token in `TileImageStore`** | Partially stale: `generation` already exists in `TileImageStore`. However, a critical race exists between in-flight loads and stale neighbour notifications. | **Partially Stale / Critical Race Discovered** | Replace boolean stale set with clock-stamped stale claims. |
| **Defect: Stale Neighbor Clearing Race** | If Tile A is in-flight when neighbour Tile B arrives, Tile B calls `markStale([A])`. When Tile A finishes, `finishLoad` unconditionally removes A from `stale`, caching the unstitched tile and permanently dropping the redraw request. | **Critical Defect Discovered** | Implement `FixedStore` with `markClock` tracking. Return `.drawnButStale` when a stale mark arrived during flight. |
| **Defect: Lost MapKit Reload on Settings Push** | In `TerrainViewerModel.pushSettings`, task cancellation during `provider.update()` can lead to a state where the provider adopts the new settings but `terrainVersion` is never bumped, leaving stale tiles on screen. | **Critical Defect Discovered** | Update `pushSettings` to bump `terrainVersion` whenever `didChange == true`. |
| **§4: Continuous Relighting Task Cancellation** | Rapid dragging of azimuth/altitude sliders queues redundant render passes. | **Valid Addition** | Implement task cancellation and in-flight dropping. |

---

## 2. In-Flight Stale Neighbor Clearing Race (`store_race.swift`)

### 2.1 The Race Sequence
1. Tile $(x, y, z)$ is requested; `beginLoad` marks it `inFlight`.
2. Neighbour tile $(x+1, y, z)$ completes rendering and lands in the store.
3. `TerrainTileProvider` detects the new neighbour and invokes `store.markStale([(x, y, z)])`.
4. Tile $(x, y, z)$ completes its initial render pass (which did *not* have the neighbour's skirt).
5. `finishLoad` executes:
   ```swift
   inFlight.remove(key)
   images[key] = image
   stale.remove(key) // BUG: silently drops the markStale from step 3!
   ```
6. The unstitched image is stored; the tile is no longer marked stale; it is never re-rendered with the neighbour's skirt. A visible seam artifact remains until the user pans the tile off-screen.

### 2.2 Empirical Reproduction
`build-review/scratch/concurrency/store_race.swift` reproduces this exact race under concurrent tile dispatch:
- Under `CurrentStore`: 100% of interleaved neighbour arrivals resulted in permanent lost redraws.
- Under `FixedStore`: 0% lost redraws.

### 2.3 The Solution: Clock-Stamped Invalidation (`FixedStore`)
```swift
private struct Claim { let generation: Int; let markClock: UInt64 }
private var inFlight: [String: Claim] = [:]
private var staleMarks: [String: UInt64] = [:]
private var markClock: UInt64 = 0

func beginLoad(_ key: String) -> Int? {
    // ...
    inFlight[key] = Claim(generation: generation, markClock: markClock)
    return generation
}

func finishLoad(_ key: String, image: CGImage?, generation: Int) -> LoadOutcome {
    guard let claim = inFlight[key], claim.generation == generation else { return .dropped }
    inFlight.removeValue(forKey: key)
    // ...
    if let mark = staleMarks[key], mark > claim.markClock {
        return .drawnButStale // tile drawn immediately, but queued for re-stitch!
    }
    staleMarks.removeValue(forKey: key)
    return .drawn
}
```

---

## 3. Settings Push Invalidation Race (`push_settings_race.swift`)

### 3.1 The Race Sequence
In `TerrainViewerModel`:
```swift
settingsTask?.cancel()
settingsTask = Task { [provider] in
    guard !Task.isCancelled else { return }
    let didChange = await provider.update(settings)
    guard !Task.isCancelled, didChange else { return } // BUG
    self.terrainVersion &+= 1
}
```
If two settings changes are pushed rapidly (e.g. slider scrubbing):
1. Push 1 creates Task 1.
2. Push 2 arrives while Task 1 is suspended in `await provider.update()`.
3. Push 2 calls `settingsTask?.cancel()` (cancelling Task 1) and creates Task 2.
4. Task 1 finishes `provider.update()` $\to$ returns `true` (provider state updated).
5. Task 1 hits `guard !Task.isCancelled` $\to$ cancelled, so it does NOT bump `terrainVersion`.
6. Task 2 runs `provider.update()` $\to$ settings already match provider, returns `false`.
7. Task 2 hits `guard didChange` $\to$ `false`, so it does NOT bump `terrainVersion`.
8. **Failure:** Provider updated its internal shader state, but MapKit never reloaded tiles!

### 3.2 The Fix
```swift
let didChange = await provider.update(settings)
if didChange {
    self.terrainVersion &+= 1
}
```
If the provider state was successfully changed, `terrainVersion` must increment to trigger tile invalidation regardless of whether the originating task was superseded.
