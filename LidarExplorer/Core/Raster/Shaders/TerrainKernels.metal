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
kernel void compute_viewshed(
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
