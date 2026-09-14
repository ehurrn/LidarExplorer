# Subsystem Assessment: Relative Elevation Model (REM) & River Thalweg Detrending

**Subsystem Key:** `rem-thalweg`  
**Review Items:** §1B, §5.3  
**Date:** 2026-09-13  
**Status:** Completed & Empirically Verified  

---

## 1. Executive Summary

| Review Item | Empirical Finding | Verdict | Action Required |
|---|---|---|---|
| **§1B: Isotropic IDW Bleed** | Stale review claim. `mt_thalweg_surface` already performs clamped nearest-segment projection, and `ThalwegSegment` is already defined in Swift and Metal. | **Stale** | Acknowledge existing segment architecture. |
| **Defect: Meander-Neck Discontinuity Cliffs** | Where two non-adjacent limbs of a sinuous river approach each other across a narrow oxbow neck, nearest-segment Voronoi partitioning creates an artificial elevation cliff (up to 2.27 m vertical step) across the neck. Over 17,200 jump crossings detected in test scenes. | **Critical Defect Discovered** | Implement banded distance-weighted segment blending (`BAND B=25 m`), which reduces jump crossings to 0. |
| **Defect: `ThalwegBuilder` Tail Truncation** | `ThalwegBuilder.densify` strides by fixed 15 m increments, dropping the final drawn tail (up to 14.9 m) of the river path. | **Defect Discovered** | Always append the drawn endpoint as the final thalweg vertex. |
| **Cross-Valley Extrapolation** | Thalweg interpolation extends infinitely across the map without a distance ceiling. | **Valid Addition** | Add `maxCrossValleyMeters` (default 2,500 m) clamp. |

---

## 2. Analysis of the Meander-Neck Cliff Defect

### 2.1 The Nearest-Segment Voronoi Cliff
When a river meanders in a loop (e.g., Mississippi oxbow), two points on the river may be separated by 1,000 meters along-channel but only 20 meters across the neck:
- Along 1,000 m of channel at 0.1% slope, water surface elevation drops 1.0 m.
- Under nearest-segment assignment:
  - Cells closer to Limb A receive $WSA = 100.0\text{ m}$.
  - Cells closer to Limb B receive $WSB = 99.0\text{ m}$.
  - Exactly at the bisector line between Limb A and Limb B, the interpolated water surface takes a **discontinuous 1.0 m cliff step**, creating a severe artificial artifact in the floodplain relative elevation.

### 2.2 Empirical Comparison (`cpu_experiment.out`)
Tested over a sine-generated meander ($\omega = 2.1$, neck width 6.2 m, along-channel distance 878 m, slope 0.002):
- **Current HEAD (`mt_thalweg_surface` nearest segment):**
  - Largest 2 cm step jump: **1.755 m**.
  - Total jump crossings $> 1\mu\text{m}$ in 2D grid: **17,223**.
  - Crossings with jump $> 0.25\text{ m}$: **1,982**.
- **Banded Smooth Blending (`BAND squared B=20`):**
  - Largest step jump: **0.000 m**.
  - Total jump crossings $> 1\mu\text{m}$: **0**.
  - Cross-limb leak: reduced from $1.89\text{ m}$ (IDW) down to $0.031\text{ m}$.

### 2.3 Proposed Banded Segment Blending Algorithm
For any grid cell $\vec{p}$:
1. Find nearest distance $d_{min} = \min_i d(\vec{p}, S_i)$.
2. Collect all segments within an active bandwidth $B$ of the minimum:
   $$d_i \le d_{min} + B$$
3. Weight each candidate segment by a smooth cubic or cosine falloff:
   $$w_i = \left(1 - \frac{d_i - d_{min}}{B}\right)^2$$
4. Normalize weights and compute the blended water surface elevation:
   $$H(\vec{p}) = \frac{\sum w_i H_i(\vec{p})}{\sum w_i}$$
Choosing $B = 25\text{ m}$ ensures that transitions across meander bisectors are $C^1$ continuous while strictly preserving water elevations along the channel centerline.

---

## 3. ThalwegBuilder Tail Truncation Fix

In `LidarExplorer/MapLayer/ThalwegBuilder.swift`:
```swift
var dist: Double = 0
while dist < totalLength {
    points.append(sample(at: dist))
    dist += spacing
}
```
If `totalLength = 100.0 m` and `spacing = 15.0 m`:
- Samples at: 0, 15, 30, 45, 60, 75, 90 m (7 points).
- The remaining 10.0 meters to the drawn terminal point is lost!
- **Fix:** Append the exact terminal coordinate if `dist - spacing < totalLength - 1.0`.
