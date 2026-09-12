//
//  TerrainKernels.metal
//  LidarExplorer
//
//  Compute kernels for terrain derivative and relief rasters.
//

#include <metal_stdlib>
using namespace metal;

struct TerrainUniforms {
    uint  width;
    uint  height;
    float cellSizeX;      // metres between columns
    float cellSizeY;      // metres between rows
    float zenithRadians;  // 90 - light altitude
    float lightAzimuth;   // radians, math convention
    uint  azimuthCount;   // number of directions for relief
    float inv8CellX;      // 1.0f / (8.0f * cellSizeX)
    float inv8CellY;      // 1.0f / (8.0f * cellSizeY)
    float cosZenith;      // cos(zenithRadians)
    float sinZenith;      // sin(zenithRadians)
};

kernel void horn_slope_aspect(
    device const float    *elevation [[buffer(0)]],
    device float          *slope     [[buffer(1)]],
    device float          *aspect    [[buffer(2)]],
    constant TerrainUniforms &u      [[buffer(3)]],
    uint2 gid                        [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) { return; }
    const uint index = gid.y * u.width + gid.x;

    if (gid.x == 0 || gid.y == 0 || gid.x + 1 >= u.width || gid.y + 1 >= u.height) {
        slope[index]  = NAN;
        aspect[index] = NAN;
        return;
    }

    const uint above = (gid.y - 1) * u.width + gid.x;
    const uint row   =  gid.y      * u.width + gid.x;
    const uint below = (gid.y + 1) * u.width + gid.x;

    const float a = elevation[above - 1], b = elevation[above], c = elevation[above + 1];
    const float d = elevation[row   - 1], e = elevation[row],    f = elevation[row   + 1];
    const float g = elevation[below - 1], h = elevation[below], i = elevation[below + 1];

    if (isnan(e) || isnan(a) || isnan(b) || isnan(c) || isnan(d) ||
        isnan(f) || isnan(g) || isnan(h) || isnan(i)) {
        slope[index]  = NAN;
        aspect[index] = NAN;
        return;
    }

    const float invX = (u.inv8CellX != 0.0f) ? u.inv8CellX : (1.0f / (8.0f * u.cellSizeX));
    const float invY = (u.inv8CellY != 0.0f) ? u.inv8CellY : (1.0f / (8.0f * u.cellSizeY));

    const float dzdx = ((c + 2.0f * f + i) - (a + 2.0f * d + g)) * invX;
    const float dzdy = ((g + 2.0f * h + i) - (a + 2.0f * b + c)) * invY;

    slope[index] = atan(sqrt(dzdx * dzdx + dzdy * dzdy)) * (180.0f / M_PI_F);

    float deg = 0.0f;
    if (dzdx != 0.0f || dzdy != 0.0f) {
        deg = 90.0f - atan2(dzdy, -dzdx) * (180.0f / M_PI_F);
        if (deg < 0.0f) { deg += 360.0f; }
        if (deg >= 360.0f) { deg -= 360.0f; }
    }
    aspect[index] = deg;
}

kernel void hillshade(
    device const float    *slope  [[buffer(0)]],
    device const float    *aspect [[buffer(1)]],
    device float          *out    [[buffer(2)]],
    constant TerrainUniforms &u   [[buffer(3)]],
    uint2 gid                     [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) { return; }
    const uint index = gid.y * u.width + gid.x;

    const float s = slope[index];
    const float a = aspect[index];
    if (isnan(s) || isnan(a)) { out[index] = NAN; return; }

    const float slopeRad  = s * (M_PI_F / 180.0f);
    const float aspectRad = a * (M_PI_F / 180.0f);

    const float cosZ = (u.cosZenith != 0.0f || u.sinZenith != 0.0f) ? u.cosZenith : cos(u.zenithRadians);
    const float sinZ = (u.cosZenith != 0.0f || u.sinZenith != 0.0f) ? u.sinZenith : sin(u.zenithRadians);

    const float value = cosZ * cos(slopeRad)
                      + sinZ * sin(slopeRad)
                      * cos(u.lightAzimuth - aspectRad);
    out[index] = clamp(value, 0.0f, 1.0f);
}

kernel void multidirectional_relief(
    device const float    *slope  [[buffer(0)]],
    device const float    *aspect [[buffer(1)]],
    device float          *out    [[buffer(2)]],
    constant TerrainUniforms &u   [[buffer(3)]],
    uint2 gid                     [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) { return; }
    const uint index = gid.y * u.width + gid.x;
    const float s = slope[index];
    const float a = aspect[index];

    if (isnan(s) || isnan(a)) { out[index] = NAN; return; }

    const float slopeRad  = s * (M_PI_F / 180.0f);
    const float aspectRad = a * (M_PI_F / 180.0f);
    const float cosZ = (u.cosZenith != 0.0f || u.sinZenith != 0.0f) ? u.cosZenith : cos(u.zenithRadians);
    const float sinZ = (u.cosZenith != 0.0f || u.sinZenith != 0.0f) ? u.sinZenith : sin(u.zenithRadians);

    const float baseCos = cosZ * cos(slopeRad);
    const float baseSin = sinZ * sin(slopeRad);

    if (u.azimuthCount == 4u) {
        float sinA, cosA;
        sinA = sincos(aspectRad, cosA);
        const float C = baseSin * cosA;
        const float S = baseSin * sinA;

        const float v0 = clamp(baseCos + C, 0.0f, 1.0f);
        const float v1 = clamp(baseCos + S, 0.0f, 1.0f);
        const float v2 = clamp(baseCos - C, 0.0f, 1.0f);
        const float v3 = clamp(baseCos - S, 0.0f, 1.0f);

        const float sum = v0 + v1 + v2 + v3;
        const float sumSq = v0 * v0 + v1 * v1 + v2 * v2 + v3 * v3;
        const float mean = sum * 0.25f;
        out[index] = sqrt(max(sumSq * 0.25f - mean * mean, 0.0f));
    } else {
        const uint  n    = max(u.azimuthCount, 1u);
        const float invN = 1.0f / float(n);
        const float step = (2.0f * M_PI_F) * invN;

        float sum = 0.0f;
        float sumSq = 0.0f;
        for (uint k = 0; k < n; ++k) {
            const float azimuth = float(k) * step;
            const float v = clamp(baseCos + baseSin * cos(azimuth - aspectRad), 0.0f, 1.0f);
            sum   += v;
            sumSq += v * v;
        }
        const float mean = sum * invN;
        out[index] = sqrt(max(sumSq * invN - mean * mean, 0.0f));
    }
}

kernel void horn_derivatives_and_relief(
    device const float    *elevation [[buffer(0)]],
    device float          *slope     [[buffer(1)]],
    device float          *aspect    [[buffer(2)]],
    device float          *relief    [[buffer(3)]],
    device float          *normalX   [[buffer(4)]],
    device float          *normalY   [[buffer(5)]],
    device float          *normalZ   [[buffer(6)]],
    constant TerrainUniforms &u      [[buffer(7)]],
    uint2 gid                        [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) { return; }
    const uint index = gid.y * u.width + gid.x;

    if (gid.x == 0 || gid.y == 0 || gid.x + 1 >= u.width || gid.y + 1 >= u.height) {
        slope[index]   = NAN;
        aspect[index]  = NAN;
        relief[index]  = NAN;
        normalX[index] = NAN;
        normalY[index] = NAN;
        normalZ[index] = NAN;
        return;
    }

    const uint above = (gid.y - 1) * u.width + gid.x;
    const uint row   =  gid.y      * u.width + gid.x;
    const uint below = (gid.y + 1) * u.width + gid.x;

    const float a = elevation[above - 1], b = elevation[above], c = elevation[above + 1];
    const float d = elevation[row   - 1], e = elevation[row],    f = elevation[row   + 1];
    const float g = elevation[below - 1], h = elevation[below], i = elevation[below + 1];

    if (isnan(e) || isnan(a) || isnan(b) || isnan(c) || isnan(d) ||
        isnan(f) || isnan(g) || isnan(h) || isnan(i)) {
        slope[index]   = NAN;
        aspect[index]  = NAN;
        relief[index]  = NAN;
        normalX[index] = NAN;
        normalY[index] = NAN;
        normalZ[index] = NAN;
        return;
    }

    const float invX = (u.inv8CellX != 0.0f) ? u.inv8CellX : (1.0f / (8.0f * u.cellSizeX));
    const float invY = (u.inv8CellY != 0.0f) ? u.inv8CellY : (1.0f / (8.0f * u.cellSizeY));

    const float dzdx = ((c + 2.0f * f + i) - (a + 2.0f * d + g)) * invX;
    const float dzdy = ((g + 2.0f * h + i) - (a + 2.0f * b + c)) * invY;

    const float riseSq = dzdx * dzdx + dzdy * dzdy;
    const float rise = sqrt(riseSq);
    const float slopeRad = atan(rise);
    slope[index] = slopeRad * (180.0f / M_PI_F);

    float aspectDeg = 0.0f;
    float aspectRad = 0.0f;
    if (dzdx != 0.0f || dzdy != 0.0f) {
        const float mathAngle = atan2(dzdy, -dzdx);
        aspectDeg = 90.0f - mathAngle * (180.0f / M_PI_F);
        if (aspectDeg < 0.0f) { aspectDeg += 360.0f; }
        if (aspectDeg >= 360.0f) { aspectDeg -= 360.0f; }
        aspectRad = aspectDeg * (M_PI_F / 180.0f);
    }
    aspect[index] = aspectDeg;

    // Direct unit normal vector computation (Horn surface normal)
    const float invNorm = rsqrt(riseSq + 1.0f);
    const float nx = -dzdx * invNorm;
    const float ny = dzdy * invNorm;
    const float nz = invNorm;

    normalX[index] = nx;
    normalY[index] = ny;
    normalZ[index] = nz;

    const float cosZ = (u.cosZenith != 0.0f || u.sinZenith != 0.0f) ? u.cosZenith : cos(u.zenithRadians);
    const float sinZ = (u.cosZenith != 0.0f || u.sinZenith != 0.0f) ? u.sinZenith : sin(u.zenithRadians);

    if (u.azimuthCount == 4u) {
        const float baseCos = cosZ * nz;
        const float C = sinZ * ny;
        const float S = sinZ * (-nx);

        const float v0 = clamp(baseCos + C, 0.0f, 1.0f);
        const float v1 = clamp(baseCos + S, 0.0f, 1.0f);
        const float v2 = clamp(baseCos - C, 0.0f, 1.0f);
        const float v3 = clamp(baseCos - S, 0.0f, 1.0f);

        const float sum = v0 + v1 + v2 + v3;
        const float sumSq = v0 * v0 + v1 * v1 + v2 * v2 + v3 * v3;
        const float mean = sum * 0.25f;
        relief[index] = sqrt(max(sumSq * 0.25f - mean * mean, 0.0f));
    } else {
        const float baseCos = cosZ * cos(slopeRad);
        const float baseSin = sinZ * sin(slopeRad);

        const uint  n    = max(u.azimuthCount, 1u);
        const float invN = 1.0f / float(n);
        const float step = (2.0f * M_PI_F) * invN;

        float sum = 0.0f;
        float sumSq = 0.0f;
        for (uint k = 0; k < n; ++k) {
            const float azimuth = float(k) * step;
            const float v = clamp(baseCos + baseSin * cos(azimuth - aspectRad), 0.0f, 1.0f);
            sum   += v;
            sumSq += v * v;
        }
        const float mean = sum * invN;
        relief[index] = sqrt(max(sumSq * invN - mean * mean, 0.0f));
    }
}

// MARK: - Topographic openness & Red Relief Image Map (RRIM)

struct OpennessUniforms {
    uint  width;
    uint  height;
    float cellSizeX;
    float cellSizeY;
    int   searchRadiusCells; // typical: 15 cells
};

/// Positive and negative topographic openness (Yokoyama et al. 2002): the mean,
/// over 8 radial directions, of how far the local horizon sits above (positive)
/// or below (negative) the horizontal plane through this cell.
///
/// A direction that runs off the grid (or finds only voids) before completing
/// even one step contributes as if the terrain there were flat rather than the
/// degenerate zenith/nadir extreme -- otherwise every border cell would report
/// an openness far outside the algorithm's normal ~0-90 degree range, purely
/// as an artefact of the raster's edge rather than any real terrain feature.
kernel void compute_topographic_openness(
    device const float          *elevation [[buffer(0)]],
    device float                *posOpen   [[buffer(1)]],
    device float                *negOpen   [[buffer(2)]],
    constant OpennessUniforms   &u         [[buffer(3)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) { return; }
    const uint idx = gid.y * u.width + gid.x;
    const float z0 = elevation[idx];
    if (isnan(z0)) {
        posOpen[idx] = NAN;
        negOpen[idx] = NAN;
        return;
    }

    const int R = max(u.searchRadiusCells, 1);
    const float radStep = (2.0f * M_PI_F) / 8.0f;
    float sumPhi = 0.0f;
    float sumPsi = 0.0f;

    for (int dir = 0; dir < 8; ++dir) {
        const float angle = float(dir) * radStep;
        const float cosA = cos(angle);
        const float sinA = sin(angle);
        // Sentinel is "flat" (angle 0), not the +/-90 degree extreme: a ray
        // that never samples any valid terrain should read as unobstructed,
        // not as maximally open or maximally closed.
        float maxZenithAngle = 0.0f;
        float minNadirAngle  = 0.0f;

        for (int r = 1; r <= R; ++r) {
            const int sx = int(gid.x) + int(round(float(r) * sinA));
            const int sy = int(gid.y) - int(round(float(r) * cosA));

            if (sx < 0 || sx >= int(u.width) || sy < 0 || sy >= int(u.height)) { break; }
            const float z = elevation[sy * u.width + sx];
            if (isnan(z)) { continue; }

            const float dist = sqrt(pow(float(sx - int(gid.x)) * u.cellSizeX, 2.0f) +
                                    pow(float(sy - int(gid.y)) * u.cellSizeY, 2.0f));
            if (dist <= 0.0f) { continue; }

            const float elevDiff = z - z0;
            const float angleElev = atan2(elevDiff, dist);
            maxZenithAngle = max(maxZenithAngle, angleElev);
            minNadirAngle  = min(minNadirAngle, angleElev);
        }

        sumPhi += (M_PI_F * 0.5f - maxZenithAngle);
        sumPsi += (M_PI_F * 0.5f + minNadirAngle);
    }

    posOpen[idx] = (sumPhi * 0.125f) * (180.0f / M_PI_F);
    negOpen[idx] = (sumPsi * 0.125f) * (180.0f / M_PI_F);
}

/// Composites slope and differential openness into a Red Relief Image Map:
/// ridges and steep faces read red, concave/convex terrain reads as light/dark
/// grey independent of any light source, so the map stays legible under any
/// display gamma or ambient light.
kernel void rrim_composite_to_texture(
    device const float              *slopeDegrees [[buffer(0)]],
    device const float              *posOpen      [[buffer(1)]],
    device const float              *negOpen      [[buffer(2)]],
    constant uint2                  &dims         [[buffer(3)]],
    texture2d<float, access::write>  outTexture   [[texture(0)]],
    uint2 gid                                     [[thread_position_in_grid]])
{
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }
    const uint idx = gid.y * dims.x + gid.x;
    const float slope = slopeDegrees[idx];
    const float po = posOpen[idx];
    const float no = negOpen[idx];

    if (isnan(slope) || isnan(po) || isnan(no)) {
        outTexture.write(float4(0.0f), gid);
        return;
    }

    // Red channel: slope steepness, normalised over [0, 50] degrees.
    // Grey/luminance: differential openness ((positive - negative) / 2),
    // normalised over a +/-20 degree window centred on "flat".
    const float red = clamp(slope / 50.0f, 0.0f, 1.0f);
    const float diffOpen = (po - no) * 0.5f;
    const float lum = clamp((diffOpen + 20.0f) / 40.0f, 0.0f, 1.0f);

    const float3 col = mix(float3(lum), float3(red, 0.0f, 0.0f), red * 0.7f);
    outTexture.write(float4(col, 1.0f), gid);
}

// MARK: - Radial viewshed raymarching

struct ViewshedUniforms {
    uint  width;
    uint  height;
    uint2 observerGrid;
    float observerEyeAltitude; // ground elevation at the observer + eye height
    float cellSizeX;
    float cellSizeY;
    float maxRadiusMeters;
};

/// Per-target-cell line-of-sight raymarch: for every cell within
/// `maxRadiusMeters`, walks the grid cells between it and the observer and
/// compares each intervening cell's elevation angle (as seen from the
/// observer's eye) against the target's own -- if anything in between rises
/// above that line of sight, the target is occluded.
///
/// One thread per target cell, each independently raymarching back to the
/// observer: `O(width * height * radius)` work, the standard cost of a naive
/// radial viewshed. `maxRadiusMeters` is what keeps that bounded.
kernel void compute_viewshed_raymarch(
    device const float          *elevation  [[buffer(0)]],
    device uint8_t              *visibility [[buffer(1)]], // 1 = visible, 0 = occluded
    constant ViewshedUniforms   &u          [[buffer(2)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) { return; }
    const uint targetIdx = gid.y * u.width + gid.x;

    if (gid.x == u.observerGrid.x && gid.y == u.observerGrid.y) {
        visibility[targetIdx] = 1;
        return;
    }

    const float targetElev = elevation[targetIdx];
    if (isnan(targetElev)) {
        visibility[targetIdx] = 0;
        return;
    }

    const float dxM = float(int(gid.x) - int(u.observerGrid.x)) * u.cellSizeX;
    const float dyM = float(int(gid.y) - int(u.observerGrid.y)) * u.cellSizeY;
    const float totalDist = sqrt(dxM * dxM + dyM * dyM);

    if (totalDist > u.maxRadiusMeters) {
        visibility[targetIdx] = 0;
        return;
    }

    const float targetTangent = (targetElev - u.observerEyeAltitude) / totalDist;
    const int stepCount = max(abs(int(gid.x) - int(u.observerGrid.x)), abs(int(gid.y) - int(u.observerGrid.y)));
    const float invSteps = 1.0f / float(stepCount);

    for (int step = 1; step < stepCount; ++step) {
        const float f = float(step) * invSteps;
        // Clamped, not just rounded: a convex combination of two in-bounds
        // grid coordinates cannot land outside them mathematically, but nudging
        // that guarantee onto a floating-point round is a correctness bet this
        // kernel does not need to make when an out-of-bounds index would read
        // outside the buffer.
        const uint sx = uint(clamp(round(mix(float(u.observerGrid.x), float(gid.x), f)), 0.0f, float(u.width - 1)));
        const uint sy = uint(clamp(round(mix(float(u.observerGrid.y), float(gid.y), f)), 0.0f, float(u.height - 1)));

        const float sampleElev = elevation[sy * u.width + sx];
        if (isnan(sampleElev)) { continue; }

        const float stepDist = f * totalDist;
        const float sampleTangent = (sampleElev - u.observerEyeAltitude) / stepDist;

        if (sampleTangent >= targetTangent) {
            visibility[targetIdx] = 0;
            return;
        }
    }

    visibility[targetIdx] = 1;
}

// MARK: - Fused surface-to-display

/// Everything a display tile needs that is not the elevation raster itself.
///
/// The padded dimensions describe the buffer; the destination dimensions and
/// `margin` describe the tile actually being drawn. Keeping both here is what
/// lets the skirt stay in the buffer instead of being memcpy'd away first —
/// each thread simply reads from `gid + margin`.
struct RenderUniforms {
    uint  paddedWidth;
    uint  paddedHeight;
    uint  destWidth;
    uint  destHeight;
    uint  margin;
    uint  style;            // 0 hillshade, 1 multiDirectional, 2 slope, 3 elevation
    uint  azimuthCount;
    float inv8CellX;        // 1 / (8 * metres per column)
    float inv8CellY;        // 1 / (8 * metres per row)
    float cellSizeX;        // metres per column
    float cellSizeY;        // metres per row
    float cosZenith;
    float sinZenith;
    float lightAzimuth;     // radians, math convention
    float contourInterval;  // metres; <= 0 disables contours
    float rangeMin;         // value mapped to palette texel 0
    float rangeMax;         // value mapped to palette texel 255
    uint  indexMultiplier;  // every Nth contour is a bolder index line (0 or 1 disables)
    float indexContourWidth; // screen-space width multiplier for index lines
};

constant uint kStyleHillshade       = 0u;
constant uint kStyleMultiDirectional = 1u;
constant uint kStyleSlope           = 2u;
constant uint kStyleElevation       = 3u;

/// One-pass elevation raster to displayable RGBA.
///
/// Replaces the download-then-loop path: derivatives, the style's scalar,
/// the colour lookup, the contour overlay and the premultiplied byte write
/// all happen while the samples are still in registers. The 3x3 Horn window
/// reads across the skirt, so the destination tile carries no dead border and
/// nothing has to be cropped on the CPU first.
kernel void terrain_surface_to_texture(
    device const float               *elevation      [[buffer(0)]],
    constant RenderUniforms          &u              [[buffer(1)]],
    texture1d<float, access::sample>  paletteTexture [[texture(0)]],
    texture2d<float, access::write>   outTexture     [[texture(1)]],
    uint2 gid                                        [[thread_position_in_grid]])
{
    if (gid.x >= u.destWidth || gid.y >= u.destHeight) { return; }

    constexpr sampler paletteSampler(coord::normalized, filter::linear, address::clamp_to_edge);

    const uint2 samplePos = gid + uint2(u.margin, u.margin);
    if (samplePos.x == 0u || samplePos.y == 0u ||
        samplePos.x + 1u >= u.paddedWidth || samplePos.y + 1u >= u.paddedHeight) {
        outTexture.write(float4(0.0f), gid);
        return;
    }

    const uint above = (samplePos.y - 1u) * u.paddedWidth + samplePos.x;
    const uint row   =  samplePos.y       * u.paddedWidth + samplePos.x;
    const uint below = (samplePos.y + 1u) * u.paddedWidth + samplePos.x;

    const float a = elevation[above - 1], b = elevation[above], c = elevation[above + 1];
    const float d = elevation[row   - 1], e = elevation[row],   f = elevation[row   + 1];
    const float g = elevation[below - 1], h = elevation[below], i = elevation[below + 1];

    if (isnan(e) || isnan(a) || isnan(b) || isnan(c) || isnan(d) ||
        isnan(f) || isnan(g) || isnan(h) || isnan(i)) {
        outTexture.write(float4(0.0f), gid);
        return;
    }

    // Horn's 3x3 gradients, in metres of rise per metre of run.
    const float dzdx = ((c + 2.0f * f + i) - (a + 2.0f * d + g)) * u.inv8CellX;
    const float dzdy = ((g + 2.0f * h + i) - (a + 2.0f * b + c)) * u.inv8CellY;

    const float riseSq   = dzdx * dzdx + dzdy * dzdy;
    const float invNorm  = rsqrt(riseSq + 1.0f);
    const float3 N       = float3(-dzdx, dzdy, 1.0f) * invNorm;   // unit surface normal
    const float slopeRad = atan(sqrt(riseSq));

    float value = 0.0f;
    switch (u.style) {
        case kStyleHillshade: {
            // Lambertian: dot(N, L) with L built from the light's azimuth and
            // altitude. Equivalent to the slope/aspect trigonometry it
            // replaces, without reconstructing the angles.
            float sinAz, cosAz;
            sinAz = sincos(u.lightAzimuth, cosAz);
            const float3 L = float3(u.sinZenith * sinAz, u.sinZenith * cosAz, u.cosZenith);
            value = clamp(dot(N, L), 0.0f, 1.0f);
            break;
        }
        case kStyleMultiDirectional: {
            // Per-cell spread across the illumination directions. The
            // four-direction case collapses to two signed terms because the
            // azimuths are axis-aligned.
            if (u.azimuthCount == 4u) {
                const float baseCos = u.cosZenith * N.z;
                const float C = u.sinZenith * N.y;
                const float S = u.sinZenith * (-N.x);
                const float v0 = clamp(baseCos + C, 0.0f, 1.0f);
                const float v1 = clamp(baseCos + S, 0.0f, 1.0f);
                const float v2 = clamp(baseCos - C, 0.0f, 1.0f);
                const float v3 = clamp(baseCos - S, 0.0f, 1.0f);
                const float sum = v0 + v1 + v2 + v3;
                const float sumSq = v0 * v0 + v1 * v1 + v2 * v2 + v3 * v3;
                const float mean = sum * 0.25f;
                value = sqrt(max(sumSq * 0.25f - mean * mean, 0.0f));
            } else {
                float aspectRad = 0.0f;
                if (dzdx != 0.0f || dzdy != 0.0f) {
                    float deg = 90.0f - atan2(dzdy, -dzdx) * (180.0f / M_PI_F);
                    if (deg < 0.0f) { deg += 360.0f; }
                    if (deg >= 360.0f) { deg -= 360.0f; }
                    aspectRad = deg * (M_PI_F / 180.0f);
                }
                const float baseCos = u.cosZenith * cos(slopeRad);
                const float baseSin = u.sinZenith * sin(slopeRad);
                const uint  n    = max(u.azimuthCount, 1u);
                const float invN = 1.0f / float(n);
                const float step = (2.0f * M_PI_F) * invN;
                float sum = 0.0f;
                float sumSq = 0.0f;
                for (uint k = 0; k < n; ++k) {
                    const float v = clamp(
                        baseCos + baseSin * cos(float(k) * step - aspectRad), 0.0f, 1.0f);
                    sum   += v;
                    sumSq += v * v;
                }
                const float mean = sum * invN;
                value = sqrt(max(sumSq * invN - mean * mean, 0.0f));
            }
            break;
        }
        case kStyleSlope:
            value = slopeRad * (180.0f / M_PI_F);
            break;
        case kStyleElevation:
        default:
            value = e;
            break;
    }

    const float span = max(u.rangeMax - u.rangeMin, 0.001f);
    const float t    = clamp((value - u.rangeMin) / span, 0.0f, 1.0f);

    // The palette carries straight (non-premultiplied) colour and alpha; the
    // texture is consumed as premultipliedLast, so premultiply on the way out.
    float4 straight = paletteTexture.sample(paletteSampler, t);

    if (u.contourInterval > 0.0f && straight.a > 0.0f) {
        // Distance to the nearest regular contour, in metres.
        float modVal = fmod(e, u.contourInterval);
        if (modVal < 0.0f) { modVal += u.contourInterval; }
        const float dist = min(modVal, u.contourInterval - modVal);

        // Index contours (cartographic convention: every Nth line drawn
        // bolder) sit at multiples of indexInterval, a subset of the regular
        // lines. A cell is "on" the index line only when the nearest index
        // line and the nearest regular line are the same line, i.e. their
        // distances agree, not merely both being small.
        const uint indexMultiplier = max(u.indexMultiplier, 1u);
        const float indexInterval = u.contourInterval * float(indexMultiplier);
        float indexModVal = fmod(e, indexInterval);
        if (indexModVal < 0.0f) { indexModVal += indexInterval; }
        const float indexDist = min(indexModVal, indexInterval - indexModVal);
        const bool isIndex = indexMultiplier > 1u && abs(indexDist - dist) < 0.01f;

        // Convert the gradient from metres per metre to metres per *pixel*, so
        // the line stays a constant width on screen however coarse the raster
        // is. The floor keeps flat ground from flooding with ink.
        const float2 perPixel = float2(dzdx * u.cellSizeX, dzdy * u.cellSizeY);
        const float grad = max(length(perPixel), 0.5f);
        const float targetWidth = isIndex ? (1.2f * max(u.indexContourWidth, 1.0f)) : 1.2f;
        float lineWeight = smoothstep(targetWidth, 0.0f, dist / grad);

        // Steepness dampening: on a near-vertical face, `grad` (elevation
        // change per pixel) can exceed the contour interval many times over,
        // so every pixel sits "near" some contour crossing and the naive line
        // test above would paint the whole cliff solid. Fade contour ink out
        // once more than one interval's worth of relief falls inside a single
        // pixel -- the standard cartographic practice of dropping contours on
        // cliffs rather than smearing them.
        const float linesPerPixel = grad / u.contourInterval;
        const float densityDamp = 1.0f - smoothstep(1.0f, 4.0f, linesPerPixel);
        lineWeight *= densityDamp;

        const float4 contourInk = isIndex ? float4(0.08f, 0.06f, 0.04f, 0.95f)
                                          : float4(0.14f, 0.12f, 0.10f, 0.75f);
        straight = mix(straight, contourInk, lineWeight);
    }

    outTexture.write(float4(straight.rgb * straight.a, straight.a), gid);
}

// MARK: - Micro-topography engine
//
// Every kernel below reads elevation as an R32Float texture. On Apple GPUs that
// texture is a linear view over the very buffer the COG decoder or the mapped
// cache file already wrote, so binding it moves no samples; on the Simulator it
// is a private texture filled by a GPU blit. Display products are RGBA8Unorm
// views over shared buffers a CGImage wraps without a copy.
//
// Voids are NaN everywhere (normalize_nodata makes them so) and every
// neighbourhood operation skips them rather than averaging them in.
//
// "Display" passes dispatch over a destination window of a padded source:
// thread `gid` reads source texel `gid + origin`, so a tile's analysis skirt
// never has to be cropped on the CPU.

constant float kRadiansToDegrees = 180.0f / M_PI_F;

inline float mt_read(texture2d<float, access::read> t, int x, int y) {
    return t.read(uint2(x, y)).r;
}

/// Horn's 3x3 gradient in metres of rise per metre of run, x toward east and
/// n toward north (row 0 is the northern edge). False when the window leaves
/// the raster or touches a void.
inline bool mt_horn_gradient(texture2d<float, access::read> t, int x, int y,
                             uint w, uint h, float inv8CellX, float inv8CellY,
                             thread float &dzdx, thread float &dzdn)
{
    if (x < 1 || y < 1 || x + 1 >= int(w) || y + 1 >= int(h)) { return false; }
    const float a = mt_read(t, x - 1, y - 1), b = mt_read(t, x, y - 1), c = mt_read(t, x + 1, y - 1);
    const float d = mt_read(t, x - 1, y),     e = mt_read(t, x, y),     f = mt_read(t, x + 1, y);
    const float g = mt_read(t, x - 1, y + 1), k = mt_read(t, x, y + 1), i = mt_read(t, x + 1, y + 1);
    if (isnan(a) || isnan(b) || isnan(c) || isnan(d) || isnan(e) ||
        isnan(f) || isnan(g) || isnan(k) || isnan(i)) { return false; }
    dzdx = ((c + 2.0f * f + i) - (a + 2.0f * d + g)) * inv8CellX;
    dzdn = ((a + 2.0f * b + c) - (g + 2.0f * k + i)) * inv8CellY;
    return true;
}

/// Void-aware bilinear read at fractional texel coordinates. NaN outside the
/// raster or when any of the four neighbours is a void: blending across a gap
/// would fabricate terrain that is not there.
inline float mt_bilinear(texture2d<float, access::read> t, float x, float y, uint w, uint h) {
    if (!(x >= 0.0f) || !(y >= 0.0f) || x > float(w - 1) || y > float(h - 1)) { return NAN; }
    const int x0 = int(floor(x));
    const int y0 = int(floor(y));
    const int x1 = min(x0 + 1, int(w) - 1);
    const int y1 = min(y0 + 1, int(h) - 1);
    const float v00 = mt_read(t, x0, y0), v10 = mt_read(t, x1, y0);
    const float v01 = mt_read(t, x0, y1), v11 = mt_read(t, x1, y1);
    if (isnan(v00) || isnan(v10) || isnan(v01) || isnan(v11)) { return NAN; }
    const float fx = x - float(x0);
    const float fy = y - float(y0);
    return mix(mix(v00, v10, fx), mix(v01, v11, fx), fy);
}

// MARK: Nodata normalisation

struct NoDataUniforms {
    uint  width;
    uint  height;
    float noDataValue;
    uint  hasNoDataValue;
    float validMinimum;   // below this is a sentinel (-999999, -3.4e38), not terrain
    float validMaximum;
};

/// Preparatory pass: rewrites every sentinel, infinity and out-of-range value
/// to NaN in place, so no later kernel needs to know what a given source used
/// for "no data".
kernel void normalize_nodata(
    texture2d<float, access::read_write> elevation [[texture(0)]],
    constant NoDataUniforms              &u        [[buffer(0)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) { return; }
    const float z = elevation.read(gid).r;
    const bool isVoid = !isfinite(z)
        || z < u.validMinimum || z > u.validMaximum
        || (u.hasNoDataValue != 0u && z == u.noDataValue);
    if (isVoid) { elevation.write(float4(NAN), gid); }
}

// MARK: A. Local Relief Model

struct GaussianPassUniforms {
    uint  width;
    uint  height;
    int   radius;               // taps either side along this pass's axis
    float referenceElevation;   // subtracted before summing, for Float32 precision
};

/// LRM pass 1: horizontal Gaussian, as a normalised convolution.
///
/// R carries the weighted sum of (z - reference) and G the total weight of the
/// taps that held data. Voids and off-grid taps drop out of both, and because
/// the Gaussian is separable, the vertical pass summing both channels and
/// dividing once is exactly the 2D normalised convolution -- a gap or the
/// raster edge cannot drag the trend surface toward zero.
kernel void lrm_gaussian_horizontal(
    texture2d<float, access::read>  inElevation [[texture(0)]],
    texture2d<float, access::write> outSums     [[texture(1)]],
    constant GaussianPassUniforms   &u          [[buffer(0)]],
    constant float                  *weights    [[buffer(1)]],   // weights[|offset|], radius + 1 entries
    uint2 gid                                   [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) { return; }
    const int x0 = int(gid.x);
    const int lo = max(x0 - u.radius, 0);
    const int hi = min(x0 + u.radius, int(u.width) - 1);
    float sum = 0.0f;
    float weight = 0.0f;
    for (int x = lo; x <= hi; ++x) {
        const float z = inElevation.read(uint2(x, gid.y)).r;
        if (isnan(z)) { continue; }
        const float w = weights[abs(x - x0)];
        sum += w * (z - u.referenceElevation);
        weight += w;
    }
    outSums.write(float4(sum, weight, 0.0f, 0.0f), gid);
}

/// LRM pass 2: vertical Gaussian over pass 1's sums, producing the low-pass
/// trend surface (relative to `referenceElevation`), or NaN with no support.
kernel void lrm_gaussian_vertical(
    texture2d<float, access::read>  inSums     [[texture(0)]],
    texture2d<float, access::write> outLowpass [[texture(1)]],
    constant GaussianPassUniforms   &u         [[buffer(0)]],
    constant float                  *weights   [[buffer(1)]],
    uint2 gid                                  [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) { return; }
    const int y0 = int(gid.y);
    const int lo = max(y0 - u.radius, 0);
    const int hi = min(y0 + u.radius, int(u.height) - 1);
    float numerator = 0.0f;
    float denominator = 0.0f;
    for (int y = lo; y <= hi; ++y) {
        const float4 s = inSums.read(uint2(gid.x, y));
        const float w = weights[abs(y - y0)];
        numerator += w * s.r;
        denominator += w * s.g;
    }
    outLowpass.write(float4(denominator > 0.0f ? numerator / denominator : NAN), gid);
}

struct LocalReliefUniforms {
    uint  destWidth;
    uint  destHeight;
    uint  originX;
    uint  originY;
    float referenceElevation;
    float scaleMeters;   // |dh| at which the display saturates
    uint  colorMode;     // 0 signed greyscale, 1 diverging
};

/// LRM pass 3: residual `dh = raw - lowpass`, in metres, plus its display.
///
/// Mounds and embankments read bright, ditches and borrow pits dark, and flat
/// ground exactly mid-grey (128, 128, 128) in both colour modes.
kernel void lrm_residual_to_texture(
    texture2d<float, access::read>  inElevation [[texture(0)]],
    texture2d<float, access::read>  inLowpass   [[texture(1)]],
    texture2d<float, access::write> outResidual [[texture(2)]],
    texture2d<float, access::write> outDisplay  [[texture(3)]],
    constant LocalReliefUniforms    &u          [[buffer(0)]],
    uint2 gid                                   [[thread_position_in_grid]])
{
    if (gid.x >= u.destWidth || gid.y >= u.destHeight) { return; }
    const uint2 src = gid + uint2(u.originX, u.originY);
    const float z = inElevation.read(src).r;
    const float low = inLowpass.read(src).r;
    if (isnan(z) || isnan(low)) {
        outResidual.write(float4(NAN), gid);
        outDisplay.write(float4(0.0f), gid);
        return;
    }
    const float dh = (z - u.referenceElevation) - low;
    outResidual.write(float4(dh), gid);

    const float t = clamp(dh / max(u.scaleMeters, 0.001f), -1.0f, 1.0f);
    float3 rgb;
    if (u.colorMode == 1u) {
        const float3 negative = float3(0.129f, 0.400f, 0.674f);
        const float3 positive = float3(0.698f, 0.094f, 0.168f);
        rgb = t < 0.0f ? mix(float3(0.5f), negative, -t) : mix(float3(0.5f), positive, t);
    } else {
        rgb = float3(0.5f + 0.5f * t);
    }
    outDisplay.write(float4(rgb, 1.0f), gid);
}

// MARK: Ray tables (openness, sky-view)

/// One sample of a precomputed radial ray: a cell offset and the reciprocal of
/// its ground distance. Built once per (rays, radius, cell size) on the CPU and
/// shared with the CPU reference, so the two paths visit identical samples and
/// no `sqrt` or `atan` runs per sample on the GPU.
struct RayStep {
    int   dx;
    int   dy;
    float invDistance;
};

// MARK: B. Red Relief Image Map

struct RRIMUniforms {
    uint  width;
    uint  height;
    uint  destWidth;
    uint  destHeight;
    uint  originX;
    uint  originY;
    uint  rayCount;
    uint  stepsPerRay;
    int   maxReach;                // largest |dx| or |dy| in the table
    float inv8CellX;
    float inv8CellY;
    float slopeMultiplier;
    float slopeSaturationDegrees;  // slope reaching full red at multiplier 1
    float opennessRangeDegrees;    // |I| reaching full white / black
};

/// Red Relief Image Map (Chiba et al. 2008) in one pass.
///
/// Slope from Horn's 3x3 drives red saturation. Positive openness
/// `Phi = mean(90 - beta)` and negative openness `Psi = mean(90 - delta)` over
/// `rayCount` azimuths, with `beta` / `delta` the steepest angle up / down to
/// any sample within the radius, give differential openness
/// `I = (Phi - Psi) / 2`, which drives brightness: convex ground bright,
/// enclosed ground dark, flat ground (I = 0) mid-grey.
///
/// A ray that finds no valid sample reads as flat (angle 0), so the raster
/// edge is not mistaken for a pit or a summit.
kernel void compute_rrim(
    texture2d<float, access::read>  inElevation             [[texture(0)]],
    texture2d<float, access::write> outRRIM                 [[texture(1)]],
    texture2d<float, access::write> outDifferentialOpenness [[texture(2)]],
    constant RRIMUniforms           &u                      [[buffer(0)]],
    constant RayStep                *rays                   [[buffer(1)]],
    uint2 gid                                               [[thread_position_in_grid]])
{
    if (gid.x >= u.destWidth || gid.y >= u.destHeight) { return; }
    const int cx = int(gid.x + u.originX);
    const int cy = int(gid.y + u.originY);
    const float z0 = mt_read(inElevation, cx, cy);
    float dzdx = 0.0f, dzdn = 0.0f;
    if (isnan(z0) || !mt_horn_gradient(inElevation, cx, cy, u.width, u.height,
                                       u.inv8CellX, u.inv8CellY, dzdx, dzdn)) {
        outRRIM.write(float4(0.0f), gid);
        outDifferentialOpenness.write(float4(NAN), gid);
        return;
    }
    const float slopeDegrees = atan(sqrt(dzdx * dzdx + dzdn * dzdn)) * kRadiansToDegrees;

    const bool interior = cx >= u.maxReach && cy >= u.maxReach
        && cx + u.maxReach < int(u.width) && cy + u.maxReach < int(u.height);
    const uint n = max(u.rayCount, 1u);
    float sumPhi = 0.0f;
    float sumPsi = 0.0f;
    for (uint r = 0; r < n; ++r) {
        float maxUp = -FLT_MAX;
        float maxDown = -FLT_MAX;
        const uint base = r * u.stepsPerRay;
        for (uint s = 0; s < u.stepsPerRay; ++s) {
            const RayStep step = rays[base + s];
            const int sx = cx + step.dx;
            const int sy = cy + step.dy;
            // A straight ray that leaves the raster never re-enters it.
            if (!interior && (sx < 0 || sy < 0 || sx >= int(u.width) || sy >= int(u.height))) { break; }
            const float z = mt_read(inElevation, sx, sy);
            if (isnan(z)) { continue; }
            const float tangent = (z - z0) * step.invDistance;
            maxUp = max(maxUp, tangent);
            maxDown = max(maxDown, -tangent);
        }
        const float beta = maxUp > -FLT_MAX ? atan(maxUp) : 0.0f;
        const float delta = maxDown > -FLT_MAX ? atan(maxDown) : 0.0f;
        sumPhi += M_PI_2_F - beta;
        sumPsi += M_PI_2_F - delta;
    }
    const float phi = sumPhi / float(n) * kRadiansToDegrees;
    const float psi = sumPsi / float(n) * kRadiansToDegrees;
    const float differential = (phi - psi) * 0.5f;
    outDifferentialOpenness.write(float4(differential), gid);

    const float saturation = saturate(slopeDegrees / max(u.slopeSaturationDegrees, 0.001f) * u.slopeMultiplier);
    const float value = saturate(0.5f + 0.5f * differential / max(u.opennessRangeDegrees, 0.001f));
    outRRIM.write(float4(value, value * (1.0f - saturation), value * (1.0f - saturation), 1.0f), gid);
}

// MARK: C. Sky-View Factor

struct SkyViewUniforms {
    uint  width;
    uint  height;
    uint  destWidth;
    uint  destHeight;
    uint  originX;
    uint  originY;
    uint  rayCount;
    uint  stepsPerRay;
    int   maxReach;
    float displayMinimum;   // SVF mapped to black; 1.0 maps to white
};

/// Sky-view factor (Zaksek et al. 2011): `1 - mean(sin(gamma))`, `gamma` the
/// horizon angle along each azimuth, clamped at the horizontal -- ground below
/// the cell hides no sky. 1 on open flat ground, lower in ditches, sunken
/// trails and against platform edges.
kernel void compute_svf(
    texture2d<float, access::read>  inElevation [[texture(0)]],
    texture2d<float, access::write> outSkyView  [[texture(1)]],
    texture2d<float, access::write> outDisplay  [[texture(2)]],
    constant SkyViewUniforms        &u          [[buffer(0)]],
    constant RayStep                *rays       [[buffer(1)]],
    uint2 gid                                   [[thread_position_in_grid]])
{
    if (gid.x >= u.destWidth || gid.y >= u.destHeight) { return; }
    const int cx = int(gid.x + u.originX);
    const int cy = int(gid.y + u.originY);
    const float z0 = mt_read(inElevation, cx, cy);
    if (isnan(z0)) {
        outSkyView.write(float4(NAN), gid);
        outDisplay.write(float4(0.0f), gid);
        return;
    }
    const bool interior = cx >= u.maxReach && cy >= u.maxReach
        && cx + u.maxReach < int(u.width) && cy + u.maxReach < int(u.height);
    const uint n = max(u.rayCount, 1u);
    float sumSin = 0.0f;
    for (uint r = 0; r < n; ++r) {
        float maxTangent = 0.0f;
        const uint base = r * u.stepsPerRay;
        for (uint s = 0; s < u.stepsPerRay; ++s) {
            const RayStep step = rays[base + s];
            const int sx = cx + step.dx;
            const int sy = cy + step.dy;
            if (!interior && (sx < 0 || sy < 0 || sx >= int(u.width) || sy >= int(u.height))) { break; }
            const float z = mt_read(inElevation, sx, sy);
            if (isnan(z)) { continue; }
            maxTangent = max(maxTangent, (z - z0) * step.invDistance);
        }
        // sin(atan(t)) without the atan.
        sumSin += maxTangent * rsqrt(1.0f + maxTangent * maxTangent);
    }
    const float svf = 1.0f - sumSin / float(n);
    outSkyView.write(float4(svf), gid);
    const float v = saturate((svf - u.displayMinimum) / max(1.0f - u.displayMinimum, 0.001f));
    outDisplay.write(float4(v, v, v, 1.0f), gid);
}

// MARK: D. Dynamic grazing-angle raking light

struct RakingLightUniforms {
    uint  width;
    uint  height;
    uint  destWidth;
    uint  destHeight;
    uint  originX;
    uint  originY;
    float inv8CellX;
    float inv8CellY;
    float sunAzimuth;    // radians clockwise from north
    float sunAltitude;   // radians above the horizon
    float zFactor;       // vertical exaggeration
    float ambient;
};

/// Analytical Lambertian hillshade built for grazing light.
///
/// `N = normalize(-dz/dx * zFactor, -dz/dy * zFactor, 1)` (x east, y north),
/// `L = (cos(alt) sin(az), cos(alt) cos(az), sin(alt))`, and
/// `I = ambient + (1 - ambient) * max(0, N . L)` -- the ambient floor keeps a
/// pit facing away from a 5 degree sun from clipping to pure black.
kernel void dynamic_raking_hillshade(
    texture2d<float, access::read>  inElevation  [[texture(0)]],
    texture2d<float, access::write> outIntensity [[texture(1)]],
    texture2d<float, access::write> outDisplay   [[texture(2)]],
    constant RakingLightUniforms    &u           [[buffer(0)]],
    uint2 gid                                    [[thread_position_in_grid]])
{
    if (gid.x >= u.destWidth || gid.y >= u.destHeight) { return; }
    const int cx = int(gid.x + u.originX);
    const int cy = int(gid.y + u.originY);
    float dzdx = 0.0f, dzdn = 0.0f;
    if (!mt_horn_gradient(inElevation, cx, cy, u.width, u.height, u.inv8CellX, u.inv8CellY, dzdx, dzdn)) {
        outIntensity.write(float4(NAN), gid);
        outDisplay.write(float4(0.0f), gid);
        return;
    }
    const float3 N = normalize(float3(-dzdx * u.zFactor, -dzdn * u.zFactor, 1.0f));
    const float cosAlt = cos(u.sunAltitude);
    const float3 L = float3(cosAlt * sin(u.sunAzimuth), cosAlt * cos(u.sunAzimuth), sin(u.sunAltitude));
    const float intensity = u.ambient + (1.0f - u.ambient) * max(0.0f, dot(N, L));
    outIntensity.write(float4(intensity), gid);
    outDisplay.write(float4(intensity, intensity, intensity, 1.0f), gid);
}

// MARK: F. Relative Elevation Model

/// One thalweg vertex, in the raster's metric frame (x east from column 0,
/// y south from row 0), carrying the water-surface elevation there.
struct ThalwegVertex {
    float x;
    float y;
    float waterSurface;
    float padding;
};

struct RelativeElevationUniforms {
    uint  width;
    uint  height;
    uint  destWidth;
    uint  destHeight;
    uint  originX;
    uint  originY;
    uint  vertexCount;
    uint  mode;            // 0 thalweg polyline, 1 water-surface raster
    float cellSizeX;
    float cellSizeY;
    float idwPower;
    float rangeMinimum;    // h_rel at palette texel 0
    float rangeMaximum;    // h_rel at palette texel 255
    float bandMeters;      // <= 0 disables banding
};

/// Water-surface elevation under point `p` interpolated from a thalweg
/// polyline: inverse-distance weighting over each segment's nearest point,
/// with that point's elevation interpolated along the segment. One vertex is
/// a flat water plane.
inline float mt_thalweg_surface(float2 p, constant ThalwegVertex *v, uint count,
                                float power, float minimumDistance)
{
    if (count == 0u) { return NAN; }
    if (count == 1u) { return v[0].waterSurface; }
    float numerator = 0.0f;
    float denominator = 0.0f;
    for (uint k = 0; k + 1u < count; ++k) {
        const float2 a = float2(v[k].x, v[k].y);
        const float2 b = float2(v[k + 1u].x, v[k + 1u].y);
        const float2 ab = b - a;
        const float lengthSq = dot(ab, ab);
        const float t = lengthSq > 0.0f ? saturate(dot(p - a, ab) / lengthSq) : 0.0f;
        const float d = max(distance(p, a + t * ab), minimumDistance);
        const float w = pow(d, -power);
        numerator += w * mix(v[k].waterSurface, v[k + 1u].waterSurface, t);
        denominator += w;
    }
    return numerator / denominator;
}

/// Detrends the DEM against the river: `h_rel = h - h_stream`, then maps it
/// through a banded hypsometric palette in which active levees (+2..+5 m)
/// separate cleanly from clay plugs and paleochannel swales (<= 0 m).
kernel void detrend_river_elevation(
    texture2d<float, access::read>   inElevation  [[texture(0)]],
    texture2d<float, access::read>   waterSurface [[texture(1)]],   // mode 1; any texture otherwise
    texture1d<float, access::sample> palette      [[texture(2)]],
    texture2d<float, access::write>  outRelative  [[texture(3)]],
    texture2d<float, access::write>  outDisplay   [[texture(4)]],
    constant RelativeElevationUniforms &u         [[buffer(0)]],
    constant ThalwegVertex           *thalweg     [[buffer(1)]],
    uint2 gid                                     [[thread_position_in_grid]])
{
    if (gid.x >= u.destWidth || gid.y >= u.destHeight) { return; }
    constexpr sampler paletteSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    const uint2 src = gid + uint2(u.originX, u.originY);
    const float z = inElevation.read(src).r;
    float stream = NAN;
    if (u.mode == 1u) {
        stream = waterSurface.read(src).r;
    } else {
        const float2 p = float2(float(src.x) * u.cellSizeX, float(src.y) * u.cellSizeY);
        stream = mt_thalweg_surface(p, thalweg, u.vertexCount, u.idwPower,
                                    max(min(u.cellSizeX, u.cellSizeY), 0.001f));
    }
    if (isnan(z) || isnan(stream)) {
        outRelative.write(float4(NAN), gid);
        outDisplay.write(float4(0.0f), gid);
        return;
    }
    const float relative = z - stream;
    outRelative.write(float4(relative), gid);

    const float shown = u.bandMeters > 0.0f
        ? (floor(relative / u.bandMeters) + 0.5f) * u.bandMeters
        : relative;
    const float span = max(u.rangeMaximum - u.rangeMinimum, 0.001f);
    const float t = saturate((shown - u.rangeMinimum) / span);
    const float4 c = palette.sample(paletteSampler, t);
    outDisplay.write(float4(c.rgb * c.a, c.a), gid);
}

// MARK: G. Habitation potential (slope and living-floor anomaly mask)

struct HabitationSeedUniforms {
    uint  width;
    uint  height;
    float inv8CellX;
    float inv8CellY;
    float steepSlopeMinimumDegrees;
};

/// Habitation pass 1: Horn slope for every cell, and a jump-flood seed (the
/// cell's own coordinate) wherever the slope is at least the steep threshold.
kernel void habitation_slope_seed(
    texture2d<float, access::read>  inElevation [[texture(0)]],
    texture2d<float, access::write> outSlope    [[texture(1)]],
    texture2d<float, access::write> outSeeds    [[texture(2)]],
    constant HabitationSeedUniforms &u          [[buffer(0)]],
    uint2 gid                                   [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) { return; }
    float dzdx = 0.0f, dzdn = 0.0f;
    if (!mt_horn_gradient(inElevation, int(gid.x), int(gid.y), u.width, u.height,
                          u.inv8CellX, u.inv8CellY, dzdx, dzdn)) {
        outSlope.write(float4(NAN), gid);
        outSeeds.write(float4(-1.0f, -1.0f, 0.0f, 0.0f), gid);
        return;
    }
    const float slope = atan(sqrt(dzdx * dzdx + dzdn * dzdn)) * kRadiansToDegrees;
    outSlope.write(float4(slope), gid);
    const bool steep = slope >= u.steepSlopeMinimumDegrees;
    outSeeds.write(steep ? float4(float(gid.x), float(gid.y), 0.0f, 0.0f)
                         : float4(-1.0f, -1.0f, 0.0f, 0.0f), gid);
}

struct JumpFloodUniforms {
    uint  width;
    uint  height;
    int   step;
    float cellSizeX;
    float cellSizeY;
};

/// Habitation pass 2 (repeated): one jump-flooding step. Each cell adopts
/// whichever seed, among its own and those of the eight cells `step` away, is
/// nearest in ground metres. Run at halving steps (then 2, 1 again), this
/// converges on the nearest steep cell to every cell in O(log radius) passes.
kernel void habitation_jump_flood(
    texture2d<float, access::read>  inSeeds  [[texture(0)]],
    texture2d<float, access::write> outSeeds [[texture(1)]],
    constant JumpFloodUniforms      &u       [[buffer(0)]],
    uint2 gid                                [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) { return; }
    const float2 here = float2(gid);
    float2 best = inSeeds.read(gid).rg;
    float bestDistanceSq = FLT_MAX;
    if (best.x >= 0.0f) {
        const float2 d = (best - here) * float2(u.cellSizeX, u.cellSizeY);
        bestDistanceSq = dot(d, d);
    }
    for (int oy = -1; oy <= 1; ++oy) {
        for (int ox = -1; ox <= 1; ++ox) {
            if (ox == 0 && oy == 0) { continue; }
            const int nx = int(gid.x) + ox * u.step;
            const int ny = int(gid.y) + oy * u.step;
            if (nx < 0 || ny < 0 || nx >= int(u.width) || ny >= int(u.height)) { continue; }
            const float2 seed = inSeeds.read(uint2(nx, ny)).rg;
            if (seed.x < 0.0f) { continue; }
            const float2 d = (seed - here) * float2(u.cellSizeX, u.cellSizeY);
            const float distanceSq = dot(d, d);
            if (distanceSq < bestDistanceSq) {
                bestDistanceSq = distanceSq;
                best = seed;
            }
        }
    }
    outSeeds.write(float4(best, 0.0f, 0.0f), gid);
}

struct HabitationUniforms {
    uint  width;
    uint  height;
    uint  destWidth;
    uint  destHeight;
    uint  originX;
    uint  originY;
    float cellSizeX;
    float cellSizeY;
    float flatSlopeMaximumDegrees;
    float radiusMeters;
    float highlightRed;
    float highlightGreen;
    float highlightBlue;
    float highlightAlpha;
};

/// Habitation pass 3: the mask. A cell qualifies when it is itself nearly flat
/// (slope <= 4 degrees) and the nearest steep cell (slope >= 25 degrees) lies
/// within the neighbourhood radius -- which is exactly "the maximum slope in a
/// 30 m disk is at least 25 degrees": isolated benches, confluence spurs and
/// bluff-edge fingers ringed by steep ground.
kernel void evaluate_habitation_potential(
    texture2d<float, access::read>  inSlope    [[texture(0)]],
    texture2d<float, access::read>  inSeeds    [[texture(1)]],
    texture2d<float, access::write> outMask    [[texture(2)]],
    texture2d<float, access::write> outDisplay [[texture(3)]],
    constant HabitationUniforms     &u         [[buffer(0)]],
    uint2 gid                                  [[thread_position_in_grid]])
{
    if (gid.x >= u.destWidth || gid.y >= u.destHeight) { return; }
    const uint2 src = gid + uint2(u.originX, u.originY);
    const float slope = inSlope.read(src).r;
    const float2 seed = inSeeds.read(src).rg;
    bool qualifies = !isnan(slope) && slope <= u.flatSlopeMaximumDegrees && seed.x >= 0.0f;
    if (qualifies) {
        const float2 d = (seed - float2(src)) * float2(u.cellSizeX, u.cellSizeY);
        qualifies = dot(d, d) <= u.radiusMeters * u.radiusMeters;
    }
    outMask.write(float4(qualifies ? 1.0f : 0.0f), gid);
    const float a = qualifies ? u.highlightAlpha : 0.0f;
    outDisplay.write(float4(float3(u.highlightRed, u.highlightGreen, u.highlightBlue) * a, a), gid);
}

// MARK: Viewshed (radial sweep)

struct ViewshedSweepUniforms {
    uint  width;
    uint  height;
    uint  angularSteps;
    uint  radialSteps;
    float observerX;       // fractional column
    float observerY;       // fractional row
    float eyeElevation;    // ground + eye height
    float cellSizeX;
    float cellSizeY;
    float stepMeters;
};

/// Viewshed pass 1: one thread per azimuth (720 by default) marches outward
/// from the observer, keeping the running maximum sightline tangent. Entry `k`
/// of the ray's row is the horizon over samples 1...k: the angle a target
/// beyond sample k must exceed to be seen. Rows are disjoint, so the threads
/// never share a write.
kernel void viewshed_radial_sweep(
    texture2d<float, access::read> inElevation [[texture(0)]],
    device float                   *horizon    [[buffer(0)]],   // angularSteps * radialSteps
    constant ViewshedSweepUniforms &u          [[buffer(1)]],
    uint ray                                   [[thread_position_in_grid]])
{
    if (ray >= u.angularSteps) { return; }
    const float theta = float(ray) * (2.0f * M_PI_F) / float(u.angularSteps);
    // Columns grow east, rows grow south.
    const float cellsPerStepX = sin(theta) * u.stepMeters / u.cellSizeX;
    const float cellsPerStepY = -cos(theta) * u.stepMeters / u.cellSizeY;
    const uint base = ray * u.radialSteps;
    float maxTangent = -FLT_MAX;
    bool offGrid = false;
    for (uint k = 0; k < u.radialSteps; ++k) {
        horizon[base + k] = maxTangent;
        if (offGrid) { continue; }
        const float sampleIndex = float(k + 1u);
        const float x = u.observerX + cellsPerStepX * sampleIndex;
        const float y = u.observerY + cellsPerStepY * sampleIndex;
        if (x < 0.0f || y < 0.0f || x > float(u.width - 1u) || y > float(u.height - 1u)) {
            offGrid = true;
            continue;
        }
        const float z = mt_bilinear(inElevation, x, y, u.width, u.height);
        if (isnan(z)) { continue; }
        maxTangent = max(maxTangent, (z - u.eyeElevation) / (sampleIndex * u.stepMeters));
    }
}

struct ViewshedMaskUniforms {
    uint  width;
    uint  height;
    uint  angularSteps;
    uint  radialSteps;
    float observerX;
    float observerY;
    float eyeElevation;
    float targetHeight;
    float cellSizeX;
    float cellSizeY;
    float stepMeters;
    float maxRadiusMeters;
    float highlightRed;
    float highlightGreen;
    float highlightBlue;
    float highlightAlpha;
};

/// Viewshed pass 2: every cell within the radius looks up the horizon of its
/// nearest azimuth at the last sample at least half a step nearer than itself,
/// and is visible when its target point (`z + targetHeight`) sits above it.
/// The table lookup is what keeps the far field gap-free: at 5 km, 720 rays are
/// 44 m apart, but every cell still gets an answer.
kernel void compute_viewshed(
    texture2d<float, access::read>  inElevation [[texture(0)]],
    constant float                  *horizon    [[buffer(0)]],
    texture2d<float, access::write> outMask     [[texture(1)]],
    texture2d<float, access::write> outDisplay  [[texture(2)]],
    constant ViewshedMaskUniforms   &u          [[buffer(1)]],
    uint2 gid                                   [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) { return; }
    const float eastMeters = (float(gid.x) - u.observerX) * u.cellSizeX;
    // North offset written as observer minus cell, never as a negation: on the
    // observer's own row the difference is exactly +0, whereas negating a
    // south offset yields -0, and with fast math enabled `atan2(y, -0)`
    // resolves to the opposite half-plane -- which swapped due east and due
    // west on that row.
    const float northMeters = (u.observerY - float(gid.y)) * u.cellSizeY;
    const float d = sqrt(eastMeters * eastMeters + northMeters * northMeters);

    bool visible = false;
    if (d <= u.maxRadiusMeters) {
        if (d < 0.5f * u.stepMeters) {
            visible = true;
        } else {
            const float z = inElevation.read(gid).r;
            if (!isnan(z)) {
                float azimuth = abs(northMeters) < 1e-6f
                    ? (eastMeters > 0.0f ? M_PI_2_F : 1.5f * M_PI_F)
                    : atan2(eastMeters, northMeters);
                if (azimuth < 0.0f) { azimuth += 2.0f * M_PI_F; }
                const uint ray = uint(round(azimuth / (2.0f * M_PI_F) * float(u.angularSteps))) % u.angularSteps;
                const int k = int(floor(d / u.stepMeters - 0.5f));
                const float horizonTangent = k >= 0
                    ? horizon[ray * u.radialSteps + uint(min(k, int(u.radialSteps) - 1))]
                    : -FLT_MAX;
                visible = (z + u.targetHeight - u.eyeElevation) / d > horizonTangent;
            }
        }
    }
    outMask.write(float4(visible ? 1.0f : 0.0f), gid);
    const float a = visible ? u.highlightAlpha : 0.0f;
    outDisplay.write(float4(float3(u.highlightRed, u.highlightGreen, u.highlightBlue) * a, a), gid);
}

// MARK: E + 4. Composite render pass (procedural micro-contours)

struct CompositeVertexOut {
    float4 position [[position]];
    float2 uv;
};

/// A single triangle covering the render target; uv (0,0) is the top-left
/// (northern, western) corner so texel rows keep raster order.
vertex CompositeVertexOut terrain_composite_vertex(uint vid [[vertex_id]]) {
    const float2 p = float2(float((vid << 1) & 2u), float(vid & 2u));
    CompositeVertexOut out;
    out.position = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
    out.uv = float2(p.x, 1.0f - p.y);
    return out;
}

struct CompositeUniforms {
    uint  elevationWidth;
    uint  elevationHeight;
    uint  originX;              // destination window within the elevation texture
    uint  originY;
    uint  destWidth;
    uint  destHeight;
    float contourInterval;      // metres; <= 0 disables contours
    float indexInterval;        // metres; <= 0 disables index contours
    float habitationOpacity;    // 0 disables the mask overlay
    float skyViewStrength;      // 0 disables sky-view modulation
};

/// Composites the analysis layers at display resolution: the shaded base, the
/// sky-view factor as ambient occlusion, the habitation mask, and index plus
/// intermediate contours drawn procedurally with screen-space derivatives.
///
/// `fwidth` keeps every line one pixel wide at any zoom. It is evaluated in
/// uniform control flow (a derivative inside a per-pixel branch is undefined),
/// and a density fade drops ink where contours would be closer than about a
/// pixel apart -- without it, a steep bank at 0.25 m intervals floods solid.
fragment float4 terrain_composite_fragment(
    CompositeVertexOut               in             [[stage_in]],
    texture2d<float, access::sample> baseLayer      [[texture(0)]],
    texture2d<float, access::read>   elevation      [[texture(1)]],
    texture2d<float, access::sample> habitationMask [[texture(2)]],
    texture2d<float, access::read>   skyView        [[texture(3)]],
    constant CompositeUniforms       &u             [[buffer(0)]])
{
    constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    float4 color = baseLayer.sample(linearSampler, in.uv);

    const float2 dest = float2(u.destWidth, u.destHeight);
    const float2 destTexel = clamp(in.uv * dest - 0.5f, float2(0.0f), dest - 1.0f);

    // Sky-view as ambient occlusion.
    const float svf = mt_bilinear(skyView, destTexel.x, destTexel.y, skyView.get_width(), skyView.get_height());
    const float occlusion = isnan(svf) ? 1.0f : svf;
    color.rgb *= mix(1.0f, occlusion, saturate(u.skyViewStrength));

    // Habitation mask, premultiplied over.
    const float4 mask = habitationMask.sample(linearSampler, in.uv) * saturate(u.habitationOpacity);
    color = mask + color * (1.0f - mask.a);

    // Micro-contours.
    const float2 texel = float2(u.originX, u.originY) + destTexel;
    const float z = mt_bilinear(elevation, texel.x, texel.y, u.elevationWidth, u.elevationHeight);
    const float contourOn = u.contourInterval > 0.0f ? 1.0f : 0.0f;
    const float indexOn = u.indexInterval > 0.0f ? 1.0f : 0.0f;
    const float zc = z / max(u.contourInterval, 0.001f);
    const float zi = z / max(u.indexInterval, 0.001f);
    const float fwLine = fwidth(zc);
    const float fwIndex = fwidth(zi);

    float lineAlpha = 0.0f;
    float indexAlpha = 0.0f;
    if (isfinite(zc) && isfinite(fwLine) && fwLine > 0.0f) {
        const float lineDist = abs(fract(zc - 0.5f) - 0.5f) / fwLine;
        lineAlpha = (1.0f - saturate(lineDist)) * (1.0f - smoothstep(0.35f, 0.9f, fwLine)) * contourOn;
    }
    if (isfinite(zi) && isfinite(fwIndex) && fwIndex > 0.0f) {
        const float indexDist = abs(fract(zi - 0.5f) - 0.5f) / fwIndex;
        indexAlpha = (1.0f - saturate(indexDist)) * (1.0f - smoothstep(0.35f, 0.9f, fwIndex)) * indexOn;
    }
    const float4 contourColor = mix(float4(0.3f, 0.3f, 0.3f, lineAlpha * 0.6f),
                                    float4(0.1f, 0.1f, 0.1f, indexAlpha * 0.9f),
                                    saturate(indexAlpha));
    color.rgb = mix(color.rgb, contourColor.rgb * color.a, contourColor.a);
    return color;
}
