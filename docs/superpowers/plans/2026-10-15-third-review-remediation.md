# Third review remediation: micro-terrain defects (2026-10-15)

> **Status (2026-10-15):** complete. One commit for the defect-level items, f5d90e6 on `main` after 0b950b6, then
> this record. Harness 1695 to 1720 PASS / 0 FAIL at f5d90e6; Debug Simulator build for the iPad Pro 11-inch (M5)
> BUILD SUCCEEDED, no Swift warnings. As the owner asked: red first, all items, then one commit.

## Source

The owner's micro-terrain analysis (`micro_terrain_codebase_analysis.md`, kept outside the repository), twelve gaps
A1 to A12 and a roadmap. Each gap was checked against HEAD before any change. The owner chose the defect-level
items: A1, A2, A4's dead parameter and band uniform, A5, A8, A10 and A12. A3, A6, A7, A9, A11, the rest of A4 and
the roadmap are feature work and were not part of this pass.

Red-first evidence came by mutation. With the fixes reverted at once, eight of the new checks failed
(`build-review/r3-mutant.log`): the tilted-start mound, the REM blend band, the curvature channel, the three-sigma
Gaussian tap, the Openness route, the Openness seam, and two spot readings.

## Items

### A1, openness across tiles

The legacy openness kernel started its horizon search from sentinels that a flat neighbourhood never beat, and
Topographic Openness was shaded on the CPU per tile, so it stepped at tile seams. The Metal kernels now start both
horizons from `-FLT_MAX`. Topographic Openness renders a new `differentialOpenness` product, half the difference
of positive and negative openness, drawn blue-white-red over the RRIM openness range, from the stitched analysis
raster. B22 puts a tower 18 m beyond a seam and checks that the tile it borders is enclosed on both sides of the
seam (it read 0 on one side and 58 on the other before).

### A2, Gaussian support

The taps cut at two sigma, where the weight is 13.5 %, and the step rang around high-contrast mounds. They now cut
at three sigma (`GaussianTaps.sigmasPerRadius`, weight e^-4.5, about 1 %). The DoG radii follow from it. **Intended
side effect:** at the same Local Relief radius slider value the Local Relief Model and the robust LRM were narrower
(sigma 8.3 m instead of 12.5 m at the default 25 m). The owner chose to keep the old band, so in 526bb84 the default
became 37.5 m and the slider 7.5 to 75 m in 1.5 m steps: sigma 12.5 m by default and 2.5 to 25 m on the slider, as
before. A check pins it (red first). The cost is 1.5 times the taps over a wider skirt. A warm z19 tile takes 7.6 to
8.3 ms on the host against 5.3 to 6.6 ms at 25 m, so the B6 timing budget went from 8 to 11 ms.

### A4, the REM's dead parameter

`remIDWPower` was never read by the kernel. It is now `remBlendBandMeters` (25 m), the band over which the thalweg
surface blends between segments, passed to the Metal kernel and the CPU reference alike. The REM check bends a
thalweg and shows 25 m and 5 m each match the reference and differ beside the bend.

### A5, curvature channels

Curvature computed profile and planform but showed and exported profile only. Settings offers profile, planform
and mean (`CurvatureChannel`); the display and the exported values follow the choice. J checks the flank pixel
that planform colours and profile leaves grey, and the exported channel.

### A8, a mound's volume

A platform mound was measured against the transect's own baseline, so a drag begun on a slope tilted the chord
under it. It is measured against the chord between its own feet, on the smoothed surface where there is one
(a single noisy return no longer tilts it). A mound on a transect begun on a slope gives the frustum's volume
within 10 %; the mutant gave 3995 m³ against 1514.

### A10, CPU references

Occlusion, openness, the vector ruggedness measure, the difference of Gaussians and the robust LRM had no CPU
reference. `MicroTopographyReference` now has one for each, mirroring the kernels, and the K to O checks compare
GPU to CPU on a synthetic scene (occlusion and DoG within 3e-3, openness within 0.05°, VRM within 1e-4).

### A12, spot inspection reads the product

The spot callout showed elevation and slope whatever the layer. It now carries the active product's value at the
tap (`SpotInspection.ProductReading`): the LRM residual, sky-view percent, openness degrees, curvature per metre
or foot, VRM, and so on; none for REM or a plain style. B23 checks Local Relief and Sky View.

## Verification

| Gate | Result |
|---|---|
| `./Tools/run-harness.sh` | 1720 PASS / 0 FAIL, ALL CHECKS PASSED (`build-review/r3-final.log`); 1721 at 526bb84 after the A2 default change (`build-review/r4-full.log`) |
| Simulator build | `xcodebuild` Debug, iPad Pro 11-inch (M5): BUILD SUCCEEDED, no Swift warnings (`build-review/r3-sim-final.log`; at 526bb84, `build-review/r4-sim.log`) |
| Mutation | the fixes reverted together: 8 of the new checks failed (`build-review/r3-mutant.log`) |

A review pass after the gates found the stale "sigma is half" comment and the mound's raw-sample feet. Both were
fixed before the commit and the harness and build were run again.

## Unverified

- The curvature picker and the spot callout's product box are SwiftUI and compiled only.
- Differential openness on a device, and its cost against the CPU path it replaces.

## Follow-ups (not done)

- The Local Relief tile's cost at 37.5 m on a device (the host budget is now 11 ms).
- The feature-level gaps and the analysis's roadmap.
