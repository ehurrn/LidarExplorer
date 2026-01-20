# USGS Analysis Feature Review
**Date**: 2026-01-20
**Reviewer**: Claude Code
**Focus**: Modern vs. Historical Feature Differentiation

## Executive Summary

The USGS point data analysis feature successfully fetches and processes elevation data from the USGS Elevation Point Query Service. However, it has a **critical flaw**: the detection algorithms do not distinguish between modern and historical features, leading to high false positive rates.

## Current Implementation

### Data Source
- **API**: USGS Elevation Point Query Service (EPQS)
- **Endpoint**: `https://epqs.nationalmap.gov/v1/json`
- **Resolution**: Up to 50x50 grid points with bilinear interpolation
- **Data Quality**: Correctly fetches elevation data in meters (WGS84)

### Detection Algorithms

| Algorithm | Purpose | Threshold | Status |
|-----------|---------|-----------|--------|
| Mound Detection | Identifies elevated features | ≥0.5m height | ⚠️ Too sensitive |
| Linear Features | Detects ridges/paths | ≥0.3 gradient | ⚠️ No modern filtering |
| Circular Patterns | Finds ring structures | 0.6 uniformity | ⚠️ Detects tanks |
| Terrace Detection | Identifies flat platforms | <0.8 variance | ⚠️ Detects modern |

## Critical Finding: No Temporal Discrimination

### The Problem

**The system cannot distinguish modern features from historical ones.** All detection is based purely on topographic signatures without temporal or contextual analysis.

### False Positive Examples

| Modern Feature | Detected As | Why |
|----------------|-------------|-----|
| Modern building | Mound / Building Foundation | Elevated platform detected |
| Paved road | Linear Feature / Road Trace | Ridge pattern detected |
| Water tower | Circular Pattern | Perfect circle detected |
| Retention pond | Circular Pattern / Fortification | Circular depression detected |
| Retaining wall | Linear Feature | Linear elevation change |
| Modern terrace | Agricultural Terrace | Flat platform detected |
| Construction site | Earthwork | Elevation changes detected |
| Storm drain | Linear Feature | Linear depression |
| Parking lot | Terrace | Flat elevated area |
| Radio tower foundation | Circular Pattern | Circular raised area |

### Missing Capabilities

1. **No geometric regularity analysis**
   - Modern features have perfect geometry (straight lines, perfect circles)
   - Historical features are more organic and irregular
   - No scoring penalty for "too perfect" shapes

2. **No contextual filtering**
   - Doesn't check proximity to modern infrastructure
   - No comparison with OpenStreetMap or modern feature databases
   - No buffer zones around known developments

3. **No surface texture analysis**
   - Can't distinguish construction materials
   - No vegetation coverage analysis
   - No erosion/weathering assessment

4. **No size-based filtering**
   - Modern features often have characteristic sizes
   - No minimum/maximum size enforcement based on feature type

5. **No temporal metadata**
   - USGS EPQS API can provide data timestamps
   - Not using `includeDate` parameter (line 184 in DEMDataService.swift)

## Algorithm-Specific Issues

### 1. Mound Detection (Lines 192-292)

**Issues:**
- Threshold lowered to 0.5m (line 245) - catches minor modern bumps
- No shape irregularity requirement (ancient mounds are organic, not geometric)
- No proximity filtering (doesn't exclude areas near modern development)
- Confidence based only on elevation change, not feature characteristics

**Example False Positives:**
- Speed bumps
- Landscaping berms
- Building foundations
- Fill dirt piles
- Septic mounds

**Recommended Changes:**
```swift
// Add geometric irregularity score
let geometricIrregularity = calculateShapeIrregularity(around: (i, j))
// Penalize perfect geometric shapes (likely modern)
if geometricIrregularity < 0.3 { confidenceScore *= 0.5 }

// Check proximity to modern features
if isNearModernInfrastructure(coordinate) { confidenceScore *= 0.3 }

// Increase minimum threshold
if elevationChange >= 1.0 {  // Back to 1.0m minimum
```

### 2. Linear Feature Detection (Lines 294-401)

**Issues:**
- No straightness/curvature analysis
- Modern roads are perfectly straight; ancient paths meander
- No width consistency checks
- Will flag modern utilities (pipes, cables causing ground disruption)

**Example False Positives:**
- Paved roads
- Sidewalks
- Fence lines
- Utility trenches
- Retaining walls
- Curbs

**Recommended Changes:**
```swift
// Calculate straightness (ancient paths curve, modern roads are straight)
let straightnessScore = calculateStraightness(cluster)
if straightnessScore > 0.9 { confidenceScore *= 0.4 } // Too straight = modern

// Check for parallel features (roads have curbs/shoulders)
let hasParallelFeatures = detectParallelFeatures(cluster)
if hasParallelFeatures { confidenceScore *= 0.3 }
```

### 3. Circular Pattern Detection (Lines 403-491)

**Issues:**
- No penalty for perfect circles (modern tanks are geometrically perfect)
- Doesn't distinguish between earthen mounds and concrete structures
- No size-based filtering

**Example False Positives:**
- Water towers
- Grain silos
- Above-ground pools
- Circular planters
- Traffic roundabouts
- Cell tower pads

**Recommended Changes:**
```swift
// Penalize perfect circularity (ancient features are irregular)
let circularityPerfection = calculateCircularityPerfection(points)
if circularityPerfection > 0.95 { confidenceScore *= 0.3 } // Too perfect = modern

// Check typical historical size ranges
if radius < 3.0 || radius > 100.0 { confidenceScore *= 0.5 } // Outside typical range
```

### 4. Terrace Detection (Lines 493-593)

**Issues:**
- Will detect modern agricultural terracing
- Modern terraces are more uniform and flat
- No check for regular spacing (modern terraces are evenly spaced)

**Example False Positives:**
- Modern agricultural terraces
- Building platforms
- Parking lot tiers
- Stadium seating
- Loading docks
- Retaining wall systems

**Recommended Changes:**
```swift
// Check for excessive flatness (modern terraces are TOO flat)
if variance < 0.2 { confidenceScore *= 0.4 } // Too perfect = modern

// Check for regular spacing patterns
let hasRegularSpacing = detectRegularSpacing(terraces)
if hasRegularSpacing { confidenceScore *= 0.3 } // Modern pattern
```

## Data Quality Issues

### 1. Not Using Temporal Data

File: `DEMDataService.swift:184`
```swift
let urlString = "https://epqs.nationalmap.gov/v1/json?x=\(lon)&y=\(lat)&units=Meters&wkid=4326&includeDate=false"
```

**Issue**: `includeDate=false` - missing temporal information
**Fix**: Set to `true` to get data collection timestamps

### 2. Resolution Limitations

File: `DEMDataService.swift:29`
```swift
let actualResolution = min(resolution, 50)
```

**Issue**: Clamped to 50x50 maximum
**Impact**: May miss small features or lose detail
**Consideration**: This is reasonable for API performance, but should be documented

### 3. No Data Validation

**Missing**:
- No check for data freshness
- No validation of elevation plausibility
- No outlier detection

## Recommendations

### Priority 1: Implement Modern Feature Filtering

1. **Add Geometric Regularity Analysis**
   - Calculate shape irregularity scores
   - Penalize perfect geometry (straight lines, perfect circles)
   - Favor organic, irregular shapes

2. **Add Contextual Awareness**
   - Integrate OpenStreetMap data for modern feature locations
   - Create buffer zones around known modern development
   - Check proximity to roads, buildings, utilities

3. **Implement Size-Based Filtering**
   - Define typical size ranges for each historical feature type
   - Penalize features outside expected ranges
   - Consider cultural context (e.g., Mississippian mounds 10-30m tall)

### Priority 2: Improve Detection Algorithms

1. **Mound Detection**
   - Restore threshold to 1.0m minimum
   - Add shape irregularity requirement
   - Implement proximity filtering

2. **Linear Features**
   - Add curvature analysis (penalize straight lines)
   - Check for parallel features (modern road characteristic)
   - Analyze width consistency

3. **Circular Patterns**
   - Penalize perfect circularity
   - Add size-range filtering
   - Check for concentric patterns (ring forts have multiple rings)

4. **Terraces**
   - Penalize excessive flatness
   - Check for regular spacing
   - Analyze edge characteristics (ancient terraces have weathered edges)

### Priority 3: Add New Detection Features

1. **Erosion/Weathering Analysis**
   - Historical features show erosion patterns
   - Modern features have sharp, defined edges

2. **Vegetation Pattern Analysis** (if data available)
   - Historical sites often have distinctive vegetation patterns
   - Modern features may have different vegetation

3. **Surface Texture Analysis**
   - Modern materials (concrete, asphalt) have different characteristics
   - Earth features have different texture patterns

### Priority 4: Enhance Data Quality

1. **Enable Temporal Data**
   - Set `includeDate=true` in EPQS requests
   - Use data timestamps for analysis

2. **Add Multi-Source Validation**
   - Cross-reference with archaeological databases
   - Integrate with National Register of Historic Places
   - Use multiple elevation data sources for validation

3. **Implement Quality Metrics**
   - Track detection success/failure rates
   - Monitor false positive rates
   - Add user feedback mechanism

## Implementation Plan

### Phase 1: Modern Feature Filtering (2-3 days)
- [ ] Implement geometric regularity scoring
- [ ] Add OpenStreetMap integration for context
- [ ] Create modern feature buffer zones
- [ ] Update confidence scoring to penalize modern characteristics

### Phase 2: Algorithm Tuning (1-2 days)
- [ ] Restore mound threshold to 1.0m
- [ ] Add curvature analysis to linear features
- [ ] Implement circularity perfection penalty
- [ ] Add terrace flatness penalty

### Phase 3: New Detection Features (2-3 days)
- [ ] Implement erosion/weathering analysis
- [ ] Add edge characteristic analysis
- [ ] Create size-range filters per feature type
- [ ] Add parallel feature detection

### Phase 4: Data Quality Improvements (1 day)
- [ ] Enable temporal data collection
- [ ] Add data validation checks
- [ ] Implement outlier detection
- [ ] Add quality metrics tracking

## Testing Strategy

### Test Cases Needed

1. **Known Historical Sites**
   - Cahokia Mounds (already in database)
   - Poverty Point (already in database)
   - Other verified archaeological sites

2. **Known Modern Features**
   - Urban areas with buildings
   - Modern highways
   - Water treatment facilities
   - Agricultural areas
   - Suburban developments

3. **Mixed Areas**
   - Rural areas with both modern and historical features
   - Historical sites near modern development
   - Agricultural areas with potential historical features

### Success Metrics

- **Precision**: % of detections that are actual historical features (target: >70%)
- **Recall**: % of known historical features detected (target: >60%)
- **False Positive Rate**: % of modern features incorrectly flagged (target: <20%)

## Conclusion

The USGS analysis feature has a solid foundation but requires significant improvements to distinguish modern from historical features. The current implementation will generate many false positives by detecting modern infrastructure as historical features.

**Immediate Action Required**: Implement modern feature filtering before the analysis feature is used for any serious archaeological work.

## References

- USGS Elevation Point Query Service: https://epqs.nationalmap.gov/
- USGS 3DEP Program: https://www.usgs.gov/3d-elevation-program
- OpenStreetMap API: https://wiki.openstreetmap.org/wiki/API
- National Register of Historic Places: https://www.nps.gov/subjects/nationalregister/

---
**Status**: Review Complete - Implementation Recommendations Provided
