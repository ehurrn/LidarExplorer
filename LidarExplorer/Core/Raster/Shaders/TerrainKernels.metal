//
//  TerrainKernels.metal
//  LidarExplorer
//
//  Compute kernels for terrain derivative and relief rasters.
//

#include <metal_stdlib>
using namespace metal;

/// Parameters shared by every terrain kernel.
struct TerrainUniforms {
    uint  width;
    uint  height;
    float cellSizeX;      // metres between columns
    float cellSizeY;      // metres between rows
    float zenithRadians;  // 90 - light altitude
    float lightAzimuth;   // radians, math convention
    uint  azimuthCount;   // number of directions for relief
};

/// Horn (1981) 3x3 slope and aspect.
///
/// Border cells and any cell whose neighbourhood contains a NaN void are
/// written as NaN so the host can refuse to score over a data gap.
kernel void horn_slope_aspect(
    device const float    *elevation [[buffer(0)]],
    device float          *slope     [[buffer(1)]],
    device float          *aspect    [[buffer(2)]],
    constant TerrainUniforms &u      [[buffer(3)]],
    uint2 gid                        [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) { return; }

    const uint index = gid.y * u.width + gid.x;

    // Borders have no complete 3x3 neighbourhood.
    if (gid.x == 0 || gid.y == 0 || gid.x + 1 >= u.width || gid.y + 1 >= u.height) {
        slope[index]  = NAN;
        aspect[index] = NAN;
        return;
    }

    const uint above = (gid.y - 1) * u.width + gid.x;
    const uint row   =  gid.y      * u.width + gid.x;
    const uint below = (gid.y + 1) * u.width + gid.x;

    const float a = elevation[above - 1], b = elevation[above], c = elevation[above + 1];
    const float d = elevation[row   - 1],                       f = elevation[row   + 1];
    const float g = elevation[below - 1], h = elevation[below], i = elevation[below + 1];

    if (isnan(a) || isnan(b) || isnan(c) || isnan(d) ||
        isnan(f) || isnan(g) || isnan(h) || isnan(i)) {
        slope[index]  = NAN;
        aspect[index] = NAN;
        return;
    }

    const float dzdx = ((c + 2.0f * f + i) - (a + 2.0f * d + g)) / (8.0f * u.cellSizeX);
    const float dzdy = ((g + 2.0f * h + i) - (a + 2.0f * b + c)) / (8.0f * u.cellSizeY);

    slope[index] = atan(sqrt(dzdx * dzdx + dzdy * dzdy)) * (180.0f / M_PI_F);

    float deg = atan2(dzdy, -dzdx) * (180.0f / M_PI_F);
    deg = 90.0f - deg;
    if (deg <    0.0f) { deg += 360.0f; }
    if (deg >= 360.0f) { deg -= 360.0f; }
    aspect[index] = deg;
}

/// Lambertian hillshade from precomputed slope and aspect.
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

    const float value = cos(u.zenithRadians) * cos(slopeRad)
                      + sin(u.zenithRadians) * sin(slopeRad)
                      * cos(u.lightAzimuth - aspectRad);
    out[index] = clamp(value, 0.0f, 1.0f);
}

/// Multi-directional relief.
///
/// Computes the per-cell standard deviation of hillshades taken from
/// `azimuthCount` evenly spaced bearings. High spread marks terrain with
/// directional structure — the signature of linear earthworks that vanish
/// under a single illumination angle.
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
    const float cosZ = cos(u.zenithRadians);
    const float sinZ = sin(u.zenithRadians);

    // Hoist constant terms across all illumination bearings
    const float baseCos = cosZ * cos(slopeRad);
    const float baseSin = sinZ * sin(slopeRad);

    const uint  n    = max(u.azimuthCount, 1u);
    const float step = (2.0f * M_PI_F) / float(n);

    float sum = 0.0f;
    float sumSq = 0.0f;
    for (uint k = 0; k < n; ++k) {
        const float azimuth = float(k) * step;
        const float v = clamp(baseCos + baseSin * cos(azimuth - aspectRad), 0.0f, 1.0f);
        sum   += v;
        sumSq += v * v;
    }

    const float mean = sum / float(n);
    out[index] = sqrt(max(sumSq / float(n) - mean * mean, 0.0f));
}
