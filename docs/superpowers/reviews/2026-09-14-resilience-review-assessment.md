# Resilience & Concurrency Review — Assessment

> **Status (2026-10-01):** complete. The fixes landed in cf841ab (plus a log line in 5bfa23b), merged to `main` as PR #56 (fc0eb34, 2026-09-17), and they still hold: `purgeIdlePools()` (`MetalTerrainPipelineActor.swift:488`), the zero-copy offset guard (`:716`), the Welford `statistics()` doc (`ElevationGrid.swift:195-201`) and the 48-render blit check (`MicroTopographyChecks.swift:745`). The follow-ups named below were done later: R1-B1's failure memory is a circuit breaker on the 3DEP ImageServer, 3 consecutive failures then 30 s of failing fast (a 60 s cooldown in 66d0783, made a breaker in a826d6a; `USGS3DEPService`, `ElevationService.swift:81-91`; COG-header failures got no such memory), and R1-M1 was measured (6310f56, harness B10), which found no flight gate warranted. Superseded since:
> - R1-B4: `GeoTileKey` and its overloads were deleted outright (8773583, 2026-09-19), taking the `dilate32To64` checks with them.
> - R2 i2: a Pencil touch no longer turns off `isScrollEnabled`. Since 720731d (2026-09-28) `MapTouchPolicy` answers for every recognizer, and nothing writes that property.
> - R1-M2: renderer-side cancellation was added (66d0783 on a style switch, 3bc9e84 for off-screen tiles).
>
> Branch `fix/review-verified-remediation` no longer exists.

_2026-09-14 · branch `fix/review-verified-remediation`_

Two external reviews arrived the same day: a "REJECTED (4 Blockers, 3 Majors,
2 Minors)" resilience review, and a follow-up covering Swift 6 concurrency,
Metal, memory and iPadOS ergonomics. Each claim was checked against the code
and, where possible, measured. Most blockers did not survive verification; one
issue the reviews misdiagnosed turned out to be a real race.

## Verdicts

| # | Claim | Verdict | Evidence | Action |
|---|---|---|---|---|
| R1-B1 | Retry storm: fallback tiles never cached, every pan refetches | **Partial → Minor** | Fallback tiles skip the *disk* cache only; they enter the provider's memory cache (`store(entry, for:)`) and are re-served from it. Stale-tile redraws reshade from cache, not network. `HTTPTransport` caps at 3 attempts with jittered backoff; TNM empty-product results are cached 300 s. Refetch only happens after memory eviction (160 tiles / 256 MB). | Not done. Candidate follow-up: short TTL on ImageServer/COG-header transport failures. |
| R1-B2 | `SIGBUS` when LRU eviction unlinks an mmap'd cache file | **Rejected** | Probe (`mmap` `MAP_PRIVATE`, then `unlink`; and then atomic rename-over): all bytes still read back, no fault. SIGBUS needs *truncation*; `TileDiskCache` only unlinks and writes `.atomic` (new inode). | None. |
| R1-B3 / R2 | 448 MB never released; no memory-warning handling | **Partial** | `TerrainTileProvider` already halves its cache on memory warnings. The Metal idle pool (≤ 192 MB) had no release path. Both figures are caps, not resident baselines. | **Fixed:** `purgeIdlePools()`, called on memory warning and on entering background. |
| R1-B4 | `interleave` and `GeoTileKey.init` produce divergent keys → cache misses | **Rejected as blocker; dead code confirmed** | `interleave`/`dilate16To32` had no production callers and no persisted keys; `GeoTileKey` itself is only used by unused `TileDiskCache` overloads. `dilate32To64` is a correct 32→64 dilation. The type's doc described the dead function. | **Fixed:** removed both functions, rewrote the doc, retargeted harness bit-level checks to `dilate32To64` (round-trip + even-bit-only). |
| R1-M1 | Actor reentrancy → transient surface spikes; add 2-flight gate | **Plausible, unmeasured** | Renders do interleave at `await complete(...)`. No measured spike; a flight gate trades tile latency for peak memory. | Not done. Measure pool peak under a MapKit-like burst first. |
| R1-M2 | No cooperative cancellation downstream | **Rejected** | `HTTPTransport` handles `CancellationError`/`URLError.cancelled`; the provider checks `Task.isCancelled` at 6 points. Also, `TerrainTileOverlayRenderer.request` launches unstructured `Task`s nobody cancels, so extra `checkCancellation()` calls would never fire. Superseded requests are dropped by generation in `TileImageStore`. | None. The real gap, if wanted, is renderer-side cancellation of off-screen requests. |
| R1-M3 / R2 | `statistics()` doc claims Accelerate; ~35 ms on 2048² viewshed mosaics | **Doc wrong; perf claim rejected** | No vDSP path exists (doc was false). Only caller is `USGS3DEPService.makeGrid`, once per ImageServer fetch; `MercatorMosaicBuilder` never calls it. | **Fixed:** doc now describes the actual scalar Welford pass and why. |
| R1-m1 / R2 | UTM `pow` inflates per-pixel reprojection to >180 ms | **Rejected** | `COGResampler.resample` projects only 16×16 block corners and bilinearly interpolates inside blocks: ~4 k projections per 512² tile, not 262 k. | None. |
| R1-m2 / R2 | Multi-window state collisions | **Rejected** | `TerrainViewerModel` is `@State` in `TerrainViewerView`, so each scene gets its own. Shared singletons are caches/pipelines, and `UserDefaults` preferences are meant to be app-wide. `@SceneStorage` restoration is a feature request. | None. |
| R2 C1 | Zero-copy linear texture ignores offset alignment | **Valid hardening** | Metal validation asserts: *"Offset of a buffer-backed texture with pixelFormat(R32Float) must be aligned to 16 bytes, found offset(4)"* (M5 Pro probe). Current offsets are 0 and 4096, so this does not fire today. | **Fixed:** guard `source.offset % alignment == 0`; otherwise take the copy path. |
| R2 C2 | Blit-mode staging buffers leak (never drained) | **Diagnosis wrong, real race found** | They were drained, but by render *mark*: a render resuming first recycled siblings' staging buffers while their blits were still queued, and a following render could take one and overwrite it. New harness check (8 workers × 6 back-to-back blit renders vs linear reference) **failed 1/48 and 2/48 before the fix**, and passed 3/3 runs after. Also leaked entries on abandon paths. Affects the Simulator (`.blit`) path; devices use `.linear`. | **Fixed:** each staging buffer is recycled from its own command buffer's completion handler; mark/drain machinery removed from `render` and `viewshed`. |
| R2 C3 | GPU nodata pass writes through to the disk cache | **Rejected** | `MappedFile` maps `MAP_PRIVATE`. `normalizeNoDataInPlace` runs only on `COGMappedStorage` (`posix_memalign` heap). The harness reads after `await complete`, i.e. after the completion handler. | None. |
| R2 M1 | Scalar trig in CPU `multiDirectionalRelief` | **Valid, low value** | Only reached when Metal is unavailable. | Not done (YAGNI). |
| R2 i2 | Apple Pencil fights MapKit pan | **Rejected: already implemented** | `UIPencilInteraction` plus `gestureRecognizer(_:shouldReceive:)` disables `isScrollEnabled` on `.pencil`/`.stylus` touches (`TerrainMapView.swift`). | None. |
| R2 R4 | Thermal/memory coordinator singleton | **Rejected (YAGNI)** | The memory part is covered by the pool purge; nothing consumes a thermal ray budget. | None. |

## Verification

- `./Tools/run-harness.sh`: 559 PASS / 0 FAIL (3 consecutive runs, plus a final run after the UIKit import).
- `xcodebuild … -destination "generic/platform=iOS Simulator" … build`: BUILD SUCCEEDED, no warnings in touched files.
- Probes (scratch, not committed): Metal linear-texture offset validation; mmap survival across unlink and rename-over.
