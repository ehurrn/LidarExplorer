# Adversarial Audit — Assessment

_2026-09-21 · branch `main` · commits audited: `65e5930` (notebook persistence), `dfd10aa` (GeoTIFF import), `e3c7ff0` (offline download screen), `329a95f` (layer blending on the tile path)_

An adversarial pass over the four newest features, run to find what the feature checks did not: each claim below was
reproduced with a probe before anything was changed, and each fix was written test-first (the check fails against a stub,
then passes), then mutation-tested (a deliberate defect is planted in a copy of the tree and the harness must fail).

## Verdicts

| # | Finding | Severity | Evidence | Status |
|---|---|---|---|---|
| A | **A downloaded area is silently evicted by ordinary browsing.** Harvested rasters were written into the tile cache: an LRU store in `Caches/` capped at 500 MB that prunes to 400 MB. A download is the tiles nobody has looked at lately, which is what LRU evicts first, so as the user browsed, the earliest and coarsest tiles of a finished download went, and the screen still said "Downloaded all N tiles". The screen also compared a job with the cache's *cap* (500 / 256 MB), not its *prune target* (400 / 200 MB). | **Major** | Probe: after a 20-tile harvest and further browsing, 6 of the 20 were gone, coarsest first. Live app: after ordinary browsing the tile cache stood at 431 MB of its 500 MB cap, one stretch of browsing from a prune that would take the oldest tiles, which a finished download's are. | **Fixed.** |
| B | **A failed tile's reason was dropped.** `case .failed: if !cancelled { failed += 1 }` kept a count and threw the reason away, and nothing logged it: "3,000 could not be downloaded" could be a dead server, a full disk or a lost connection. | **Major** | Code: no `Log` call in the coordinator or either harvest source; `HarvestSummary` had no reason field. | **Fixed.** |
| C | **The notebook was read whole, whatever its size.** `FieldNotebookStore.load()` did `Data(contentsOf:)` before deciding anything. A file many times the memory the app may use is killed on launch, and again on every launch after it. | Major (crash loop) | Probe: a 400 MB file took peak resident memory from 892 to 1292 MB; in the harness a 3 GB file was read whole (0.41 s) and only then refused. | **Fixed.** |
| D | **The notebook is rewritten whole on every save**, so a save costs O(items). | Minor at the intended scale, Major past it | Measured: 31 ms at 1,000 strokes, 154 ms at 5,000, 622 ms at 20,000; decoding at launch 591 ms at 20,000. Off the main actor, so it costs battery and background CPU, not frames. | Open. Counter-proposal: an append-only journal (JSON Lines) compacted at launch and on background. |
| E | **The damaged-notebook alert points at a folder the user cannot reach.** It says the file was kept "in the app's Documents folder", but file sharing is not enabled (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace` are absent), so the Files app does not show it. | Minor (product decision) | Read of the target's Info.plist keys and the alert text in `TerrainViewerModel.restoreFieldMarkup`. | Open. Either enable file sharing (which also exposes anything else in Documents) or word the alert for what is true. |
| F | **Unknown data does not survive a round trip.** An item of a kind this build does not know is dropped on load and gone from the file at the next save; a file saved by a *newer* format is moved to `.damaged-…` rather than left alone, so downgrading and upgrading again splits the notebook in two. | Minor | Read of `FieldNotebook.decode` and the store's quarantine path; the format check `unsupportedVersion` sends it to quarantine. | Open. Counter-proposal: keep unknown items as raw JSON and write them back; refuse to overwrite a newer file instead of moving it. |
| G | **Smaller items**, each measured or read, none fixed: a transient network error is not retried (a resumed run retries by hand); a second import of a file with the same name replaces the first without asking; a file in iCloud that has not been downloaded is not read through `NSFileCoordinator` (untested); exports ignore the active blend layer; a job's manifest is never deleted, and its size grows with the tile count (a clean job leaves a dead one); the size estimate counts tiles already held, so a job that would add little can be refused. | Minor | | Open; see `STATUS.md`. |

**Test gaps found.** The model's ordered save chain (each save waits for the one before, so a stale notebook cannot replace a
newer one) was unproven: a mutant that removed the ordering survived every check. A `FieldNotebookPersisting` protocol lets a
double with a slow first save stand in for the disk, and check P5 now fails when the order breaks. Two ThreadSanitizer warnings
remain in the harness's own test double (`MockHarvestSource`), not in the product.

## What was tried and held

| Vector | Result |
|---|---|
| TIFF decoder against corrupt input | 3,040,000 mutated inputs (bit flips, random bytes, truncation, boundary values in the header and directory, appended and moved blocks, a wrong byte order, changed tag types, counts and values; a deterministic generator): no trap, none took a second, 12 MB peak resident. |
| Harvest arithmetic and the controller | 3.3 million `tileCount` calls over hostile regions (NaN, infinities, ±1e308, the poles, the antimeridian, Mercator's limit) and zoom pairs: none negative, and every count small enough to walk equals the enumeration. 20,000 controller runs with hostile regions and viewport widths: no trap, no negative estimate. |
| MapKit region validity | `flyTo` clamps latitude, longitude and both spans; the clamp's outputs were run through `MKMapView.setRegion` and none raised. (An unclamped region does raise an uncatchable exception; the probe that showed it crashed on purpose, which is what produced the crash-report dialog.) |
| Import cost | Decoding a 4,096 px file takes 32 to 41 ms with memory flat afterwards; sampling a 520-sample tile costs 1.5 ms (Web Mercator), 3.7 ms (geographic) and 16.5 ms (UTM). |
| Concurrency | ThreadSanitizer build of the whole harness: 2 warnings, both in the harness's own test double, none in product code. The download screen builds a `URLSession`-bearing source each time it appears; 3,000 of them built in a loop moved resident memory from 9 to 12 MB and threads from 1 to 3. |
| Release build | Compiles with no warnings; the DEBUG-only environment hooks are absent from the Release binary. |
| Notebook, stateful fuzz (P4) | 40 seeds of 40 operations (add, undo, clear, sleep, flush, relaunch, kill) against a reference model. Non-vacuous: it fails three planted defects. |

## The six stress-test vectors, for this app

| Vector | Where it applies | Verdict |
|---|---|---|
| Partial failures and retries | The harvest talks to USGS and AWS with no retry or backoff. | Not a storm (four tiles in flight, one attempt each), but a transient error costs a tile until the user resumes: G. |
| Cold starts and herds | Tile fetches coalesce per key; the launch-time notebook and cache reads are single-shot. | No finding. |
| Poison input | A corrupt notebook, a corrupt or hostile GeoTIFF, a captive-portal page in place of a tile. | Held: quarantine (C extended it to size), decoder fuzz, and the harvester refuses a non-image. |
| Format drift | The notebook has a version and a strict decoder. | F: a newer file is moved aside and unknown items are dropped. |
| Bounded buffers | Every queue and cache has a cap. | The one that had none is fixed (C); protected downloads are bounded by a budget checked at each job (A). |
| Trust boundaries | Security-scoped reads for imports; no accounts, no credentials, no server of ours. | No finding. |

## Fix design (A)

Protected storage is a second folder beside the tile cache that the cache's cap, pruning and `clear()` never touch. The
provider and the basemap source write there (`write(_:forKey:protected: true)`); a tile the tile cache already holds is
moved in, not copied or fetched again (`pin(forKey:)`); a read finds either. It lives in Application Support and is excluded
from backups, since it can be downloaded again. Budgets: 2 GiB of elevation and 1 GiB of basemap, and a 1 GiB reserve of free
disk that a download never eats into (`OfflineStorageBudget.remaining`). The download screen asks what may still be added each
time it sizes a job, because it shrinks with every download. Settings shows *Offline Downloads* apart from *Cached Tiles* and
offers *Remove Offline Downloads* (confirmed, refused while a download runs), which also deletes the job manifests and makes
the last job unresumable, since a manifest would otherwise skip tiles that are gone.

Not migrated: tiles a build before this one harvested sit in the tile cache as ordinary entries, and behave as before until a
new download of the same area moves them into protected storage.

## Verification

- `./Tools/run-harness.sh`: 1109 PASS / 0 FAIL, exit 0 (1050 before this audit). New: S1-S7, 47 checks (protected storage,
  budget arithmetic, a download outlasting browsing, basemap tiles, the screen's room, manifests, the model's rows and
  removal); F1-F4, 7 (failure reasons); the notebook's size limit, 3; save order P5, 1; the stateful notebook fuzz P4, 1.
- Mutation testing on copies of the tree: 68 defects planted across the cache, budget, provider, basemap source, controller,
  coordinator, notebook store and model. 66 caught. Two are equivalent on APFS, where a folder reports no file size, so the
  guards against counting or evicting one cannot be told from their absence; they stay as insurance for filesystems that do
  report one. Four survived the first pass (the usage of a protected folder that does not exist yet, pinning a key that is
  already protected, which budget the provider reads, the model deleting job manifests itself when no download screen
  exists); each pointed at a check that could not fail, and each was caught once the check was sharpened.
  Two more things the runs turned up: a real defect in my first draft (a protected folder that already existed was never
  excluded from backup, found by a check), and a flaky check (a free-space margin of 100 KB moved by 300 KB under parallel
  builds; it is now 100 MB against a 1 GB budget). Runs in parallel also collide on shared temp files and on `UserDefaults`,
  so a mutant counts as caught only if a check that names the defect fails, not any check.
- ThreadSanitizer, the whole harness: 2 warnings, both in the harness's own `MockHarvestSource` (a recorded-calls array
  appended under a lock while a check reads a copy of it, the copy-on-write pattern ThreadSanitizer cannot see through), none
  in product code. 37 render-time budget checks (B6, C6, K6) fail under instrumentation, as slower code must; the other 1,072
  pass, all the new ones among them.
- `xcodebuild` Debug and Release for the generic iOS Simulator: BUILD SUCCEEDED, 0 errors, 0 compiler warnings. The
  DEBUG-only `FIELD_NOTEBOOK_SAVE_DELAY_MS` hook is in the Debug binary and absent from Release.

- Live check on the iPad Pro 13" (M5) Simulator: a 16-tile download of tiles the map already held moved them (Cached Tiles
  431.1 MB to 417 MB, Offline Downloads None to 14.2 MB, original file timestamps kept); *Clear Tile Cache* emptied the tile
  cache to zero bytes and left the 14.2 MB; the folder carries the `com.apple.MobileBackup` exclusion attribute;
  *Remove Offline Downloads* confirmed, then the row read None, the folder and the job manifest were empty, and the tile cache
  rebuilt itself (52 MB) from the network.
- Not run: the same on the physical iPad, and Airplane Mode replay (`HUMAN_DO_THIS.md`, item 5, now also clears the tile cache
  first).
