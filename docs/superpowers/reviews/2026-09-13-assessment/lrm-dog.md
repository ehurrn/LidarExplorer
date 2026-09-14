# Subsystem Assessment: LRM Edge-Preserving Detrending & Difference of Gaussians (DoG)

**Subsystem Key:** `lrm-dog`  
**Review Items:** §1C, §2 (DoG)  
**Date:** 2026-09-13  
**Status:** Completed & Empirically Verified  

---

## 1. Executive Summary

| Review Item | Empirical Finding | Verdict | Action Required |
|---|---|---|---|
| **§1C: LRM Negative Moat Halos** | Valid diagnosis. Standard Gaussian detrending ($R=25\text{ m}$) leaves a $-0.46\text{ m}$ artificial depression ring around a 2 m platform mound. | **Confirmed Diagnosis** | Remediate detrending filter. |
| **§1C: Proposed Bilateral Filter ($\sigma_r = 0.5\text{ m}$)** | **Catastrophic Failure.** Because the bilateral filter clamps photometric range at $0.5\text{ m}$, any feature taller than $0.5\text{ m}$ (such as a 2 m mound) is classified as an edge and preserved in the trend. Subtraction results in **0% mound amplitude retention** (the mound is completely erased). | **Reject Proposed Fix** | Do NOT use bilateral filter. |
| **Alternative: Robust Tukey M-Estimator LRM** | Iterative Tukey biweight detrending preserves **98% mound amplitude** while slashing the moat from $-0.456\text{ m}$ down to **$-0.022\text{ m}$** (a 95% reduction in halo artifact). | **Adopt** | Implement Robust Tukey LRM in `TerrainKernels.metal`. |
| **§2: Difference of Gaussians (DoG)** | Excellent band-pass spatial filter ($\sigma_1 = 2\text{ m}, \sigma_2 = 10\text{ m}$) for isolating narrow linear features (sunken roads, ruts, palisades). | **Adopt** | Add separable DoG compute kernel and style/overlay toggle. |

---

## 2. Experimental Verification of Detrending Methods (`out-1c.txt`)

Tested on a synthetic benchmark: 256×256 grid @ 1 m GSD, 2% regional slope, 2 m sinusoidal swell, 5 cm noise, featuring:
- Platform mound: 2 m high, 30 m top, 46 m base.
- Earth lodge / house dome: 0.4 m high, 12 m diameter.
- Palisade ditch: 1 m deep, 4 m top width.

### 2.1 Benchmark Results

| Method | Mound Amplitude | Moat Depth (Ring Min) | Ditch Amplitude | Feature RMSE |
|---|---|---|---|---|
| **Gaussian LRM ($R=25\text{ m}$, default)** | 33% | **-0.456 m** | 89% | 0.206 |
| **Gaussian LRM ($R=50\text{ m}$, slider max)** | 76% | -0.304 m | 92% | 0.139 |
| **Bilateral Filter (Review proposal: $\sigma_s=3.5, \sigma_r=0.5$)** | **0% (ERASED)** | -0.061 m | **29%** | 0.305 |
| **Bilateral Filter ($\sigma_s=12.5, \sigma_r=2.0$)** | 25% | -0.326 m | 87% | 0.222 |
| **Hesse Purged-DEM LRM ($R=25\text{ m}$)** | 68% | -0.108 m | 91% | 0.138 |
| **Robust Tukey M-Estimator ($R=25\text{ m}, c=0.5\text{ m}$, 3 iter)** | **98%** | **-0.022 m** | **99%** | **0.070** |

### 2.2 Why the Bilateral Filter Failed
A bilateral filter computes:
$$W(x, y) = G_{\sigma_s}(\|\Delta \vec{x}\|) \cdot G_{\sigma_r}(|Z(x, y) - Z_{center}|)$$
In photography, $\sigma_r$ stops smoothing at contrast edges. But in topographic detrending, the goal is to produce the *regional ground surface underneath the archaeological feature*. If the filter stops smoothing at the mound flank because $|Z - Z_{center}| > \sigma_r$, the filter averages only points on top of the mound. The computed trend is therefore equal to the mound height, so $Z - Z_{trend} \approx 0$, erasing the structure.

### 2.3 Why Robust Tukey Biweight Succeeds
In Tukey M-estimation, the initial trend is a broad Gaussian blur. Residuals $r = Z - Z_{trend}$ are evaluated against tuning parameter $c \approx 0.5\text{ m}$:
$$w(r) = \begin{cases} \left(1 - (r/c)^2\right)^2 & |r| \le c \\ 0 & |r| > c \end{cases}$$
Outliers (the elevated mound platform and excavated ditch) receive zero weight in the regional trend calculation. The trend surface smoothly bridges underneath the mound, restoring accurate mound height upon subtraction without ringing moats.

---

## 3. Multi-Scale Difference of Gaussians (DoG) Formulation

DoG acts as an ideal spatial band-pass filter:
$$DoG(Z) = G_{\sigma_1}(Z) - G_{\sigma_2}(Z)$$
Where:
- $\sigma_1 = 2.0\text{ m}$: smooths high-frequency LiDAR point noise and vegetation chatter.
- $\sigma_2 = 10.0\text{ m}$: removes regional topographic slope.
Because both $G_{\sigma_1}$ and $G_{\sigma_2}$ are separable 1D Gaussian kernels, DoG can be evaluated in two passes with minimal GPU memory bandwidth ($< 1.0\text{ ms}$ on 1024²).
