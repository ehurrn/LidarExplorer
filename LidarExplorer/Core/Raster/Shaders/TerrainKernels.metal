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
    constant TerrainUniforms &u      [[buffer(4)]],
    uint2 gid                        [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) { return; }
    const uint index = gid.y * u.width + gid.x;

    if (gid.x == 0 || gid.y == 0 || gid.x + 1 >= u.width || gid.y + 1 >= u.height) {
        slope[index]  = NAN;
        aspect[index] = NAN;
        relief[index] = NAN;
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
        relief[index] = NAN;
        return;
    }

    const float invX = (u.inv8CellX != 0.0f) ? u.inv8CellX : (1.0f / (8.0f * u.cellSizeX));
    const float invY = (u.inv8CellY != 0.0f) ? u.inv8CellY : (1.0f / (8.0f * u.cellSizeY));

    const float dzdx = ((c + 2.0f * f + i) - (a + 2.0f * d + g)) * invX;
    const float dzdy = ((g + 2.0f * h + i) - (a + 2.0f * b + c)) * invY;

    const float rise = sqrt(dzdx * dzdx + dzdy * dzdy);
    const float slopeRad = atan(rise);
    const float slopeDeg = slopeRad * (180.0f / M_PI_F);
    slope[index] = slopeDeg;

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

    const float cosZ = (u.cosZenith != 0.0f || u.sinZenith != 0.0f) ? u.cosZenith : cos(u.zenithRadians);
    const float sinZ = (u.cosZenith != 0.0f || u.sinZenith != 0.0f) ? u.sinZenith : sin(u.zenithRadians);

    if (u.azimuthCount == 4u) {
        const float invNorm = rsqrt(dzdx * dzdx + dzdy * dzdy + 1.0f);
        const float baseCos = cosZ * invNorm;
        const float C = sinZ * dzdy * invNorm;
        const float S = -sinZ * dzdx * invNorm;

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
