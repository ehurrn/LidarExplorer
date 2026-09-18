# Finish, Merge and Upload — Handoff

_Written 2026-09-15 when the driving session hit its limit. Everything below is what remains; everything not listed here is done and verified._

## Where things stand

`feat/remove-ads` (HEAD `f0955ea`) is 13 commits ahead of `main` and is the tip of a **linear stack**:

```
main
 └─ fix/fractional-tile-scale   (tile pixel rounding + .gitignore)
     └─ feat/style-guide        (Map Styles reference panel + guide content)
         └─ feat/remove-ads     (AdMob/UMP/StoreKit removal + sun-control fix)
```

Separately, **PR #56** (`fix/review-verified-remediation`, branched from `main`, CI green) is still open:
https://github.com/ehurrn/LidarExplorer/pull/56

### Verified on this tip (`f0955ea`)

| Check | Result |
|---|---|
| `./Tools/run-harness.sh` | **613 PASS / 0 FAIL** |
| iOS Simulator build (iPad Pro 13") | BUILD SUCCEEDED, **no warnings** in app sources |
| Map Styles panel, iPad Pro 13" | Opens beside the map; map narrows and keeps rendering; sections, chips, in-use checkmark, Overlays, search, close all correct |
| Style detail + **Use This Style**, iPad Pro 13" | Switches the map to LRM, dock chip follows, button flips to disabled **In Use** |
| Top-bar overflow, iPad Pro 11" **portrait**, panel open | All 7 buttons visible; readout truncates to "Tap map f…" (review Major 2 fixed) |
| iPhone 17 Pro | Panel presents as a medium sheet; **Replay Intro shows the intro sheet on top of it** (review Major 1 fixed) |
| Sun controls | Dock azimuth slider no longer shown for Multi-directional (it never moved it) |

## What remains

### 1. Read the pre-merge review workflow (blocking the merge)

A 6-dimension adversarial review of `main...feat/remove-ads` was still running:

- Run ID: `wf_36def3bb-397`
- Transcript: `~/.claude/projects/-Users-herren-dev-LidarExplorer/c6b6634d-0c50-4076-ad81-1ae9d70d165c/subagents/workflows/wf_36def3bb-397`
- Script: `~/.claude/projects/-Users-herren-dev-LidarExplorer/c6b6634d-0c50-4076-ad81-1ae9d70d165c/workflows/scripts/pre-merge-stack-review-wf_36def3bb-397.js`

Read `journal.jsonl` in the transcript directory for each agent's return value. Dimensions: ads-removal, swiftui-presentation, core-guide-search, sun-controls, build-config, docs-accuracy. Each finding was verified by two skeptics; only findings at least one skeptic failed to refute are reported as confirmed. **Fix confirmed blockers/majors before merging**; log minors as follow-ups.

### 2. Finish the Elevation reload-count check (Minor, from the design review)

Half-done on the iPad Pro 11" Simulator (`A45411EC-2055-4615-961B-AB5C354B69AF`): style set to Elevation, log stream running, baseline = 1 reload. A tap meant to close the panel missed, because **the ? button moves when the panel is open** (~(371, 58) points with the panel open, ~(712, 58) closed, on the 11").

```bash
S=/private/tmp/claude-501/-Users-herren-dev-LidarExplorer/c6b6634d-0c50-4076-ad81-1ae9d70d165c/scratchpad
xcrun simctl spawn A45411EC-2055-4615-961B-AB5C354B69AF log stream --level debug --style compact \
  --predicate 'eventMessage CONTAINS "Terrain tiles reloaded"' > "$S/reload.log" 2>&1 &
# screenshot first, then tap ? at its current position; close, wait 5s, reopen, wait 5s
grep -c "Terrain tiles reloaded" "$S/reload.log"
```

Expected: **at most one** additional reload per open/close cycle. If more, exclude inspector-driven resizes from `refreshElevationRange()` (contingency in the spec). Also kill the background log-stream shell task left running from this session.

### 3. Device verification (needs the user)

The iPad (`iGonk Pro M5`, `00008142-001604881E2B801C`) was **locked**, so the build/install failed:
`The operation failed because the device was still locked (RemotePairingError 1016)`.

After unlocking:

```bash
S=/private/tmp/claude-501/-Users-herren-dev-LidarExplorer/c6b6634d-0c50-4076-ad81-1ae9d70d165c/scratchpad
xcodebuild -project LidarExplorer.xcodeproj -scheme LidarExplorer \
  -destination "id=00008142-001604881E2B801C" -configuration Debug \
  -derivedDataPath "$S/dd" -allowProvisioningUpdates build
xcrun devicectl device install app --device 00008142-001604881E2B801C \
  "$S/dd/Build/Products/Debug-iphoneos/LidarExplorer.app"
DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE=YES xcrun devicectl device process launch \
  --device 00008142-001604881E2B801C --console --terminate-existing com.detsom.LidarExplorer
```

If SpringBoard refuses with "invalid code signature … or its profile has not been explicitly trusted" (seen 2026-09-14), the fix is on the device: open the app from the home screen, trusting the developer profile in Settings → General → VPN & Device Management if prompted. Signature, entitlements and profile were all verified valid from the Mac.

### 4. Merge, commit, upload (the actual ask)

The stack is linear, so `main` fast-forwards. Only after steps 1–3 are clean:

```bash
cd /Users/herren/dev/LidarExplorer
git checkout main
git merge --ff-only feat/remove-ads        # brings all 13 commits
./Tools/run-harness.sh                      # expect 613 PASS / 0 FAIL on main
git push origin main
git push origin fix/fractional-tile-scale feat/style-guide feat/remove-ads   # optional, for history
```

Then PR #56, which is independent of the stack and still open:

```bash
gh pr checks 56          # confirm still green after main moves
gh pr merge 56 --merge   # or --squash, user's preference
git checkout main && git pull
```

### 5. Open decisions for the user

- **`.claude/` is untracked.** It holds the imported `devils-advocate` skill (`.claude/skills/devils-advocate/SKILL.md`) and agent (`.claude/agents/devils-advocate.md`, frontmatter added so Claude Code loads it). Either commit it so the skill is shared, or add `.claude/` to `.gitignore` next to `CLAUDE.md`, `GEMINI.md` and `.agent/`. The user was asked and had not answered.
- **Merge style for PR #56**: merge commit vs squash.

### 6. After the merge

- Update `STATUS.md`: branch line, harness count (613), and the verification table.
- Update `.agent/HANDOFF.json`: `active_task`, `harness_status`, `next_instruction`.
- Remaining queued work, in order:
  1. **Compass placement** — `MKMapView.showsCompass` draws under the top-bar buttons; hide it and anchor an `MKCompassButton` below the bar. Note the bar now narrows when the Map Styles panel is open, so place it relative to the map's trailing edge.
  2. Cancel stranded tile renders on a style switch: keep the request `Task` handles in `TerrainTileOverlayRenderer` and cancel them in `reloadData()` (review Minor).
- Two stale local branches exist from the parallel agent sessions and can be deleted once their work is confirmed merged: `claude/admiring-jepsen-099b95`, `claude/mystifying-gould-fdcb46`.
