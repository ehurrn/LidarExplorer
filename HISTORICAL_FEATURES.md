# Historical Site Discovery Feature

## Overview

This update adds powerful historical site detection capabilities to LidarExplorer, enabling users to identify and catalog locations of historical significance using LIDAR terrain analysis. This feature is designed for "treasure hunting but for history" - discovering hidden earthworks, building foundations, ancient roads, and other archaeological features that are invisible to the naked eye but revealed through elevation data.

## Key Features

### 1. Automated Feature Detection

The app now includes sophisticated algorithms that can detect:

- **Earthworks**: Large-scale terrain modifications
- **Mounds**: Burial mounds, ceremonial mounds, and other raised features
- **Linear Features**: Ancient roads, walls, defensive works, canals
- **Circular Patterns**: Fort structures, settlement patterns, crop circles
- **Building Foundations**: Remnants of historical structures
- **Terraces**: Agricultural terraces, defensive terraces
- **Road Traces**: Historical pathways and trade routes
- **Fortifications**: Defensive structures and enclosures
- **Settlement Patterns**: Clustering of features suggesting habitation

### 2. Detection Algorithms

#### Mound Detection
- Identifies local elevation maxima with significant height differences
- Analyzes 5x5 neighborhood patterns
- Configurable elevation change threshold (default: 1.0m)
- Estimates mound dimensions and area

#### Linear Feature Detection
- Uses gradient analysis to identify continuous slope changes
- Detects walls, roads, earthen embankments
- Groups aligned gradient patterns
- Configurable slope threshold (default: 5°)

#### Terrace Detection
- Identifies flat platforms with significant elevation changes at edges
- Analyzes variance in 10x10 meter areas
- Detects agricultural and defensive terracing
- Distinguishes natural plateaus from artificial construction

#### Circular Pattern Detection
- Framework for detecting circular enclosures (implementation extensible)
- Can be enhanced with Hough Circle Transform
- Useful for identifying forts, ceremonial sites, settlements

### 3. Confidence Scoring

Each detected feature is assigned a confidence level:

- **Confirmed** (100%): Manually verified or from known historical database
- **Very High** (90%+): Strong detection signals, clear patterns
- **High** (80-90%): Clear detection with good characteristics
- **Medium** (60-80%): Probable feature with some uncertainty
- **Low** (40-60%): Weak signal, requires verification
- **Very Low** (<40%): Marginal detection, likely noise

### 4. Known Historical Sites Database

The app includes a curated database of confirmed historical sites:

- **Cahokia Mounds** (Illinois): Largest pre-Columbian settlement north of Mexico
- **Poverty Point** (Louisiana): Massive earthwork complex from 1700-1100 BCE
- Additional sites can be added via the database

### 5. Interactive Features

#### Analysis Mode
- Toggle historical analysis on/off from the layer menu
- Real-time feature detection display
- Feature count indicator
- Analysis progress indicator

#### Feature Visualization
- Color-coded map annotations based on confidence level:
  - Green: Confirmed sites
  - Blue: Very high confidence
  - Teal: High confidence
  - Yellow: Medium confidence
  - Orange: Low confidence
  - Red: Very low confidence
- Circle overlays highlighting detected areas
- Clustered annotations for dense areas

#### Feature List View
- Searchable list of all detected features
- Filter by confidence level
- Sort by detection confidence
- Tap to navigate to feature on map
- Feature details including:
  - Type, location coordinates
  - Confidence level
  - Dimensions (length, width, height, diameter)
  - Detection date
  - Notes and metadata

#### Export Functionality
- Export all features to CSV format
- Includes coordinates, type, confidence, notes
- Share via system share sheet
- Compatible with GIS software and spreadsheets

### 6. Customizable Analysis Settings

```swift
struct AnalysisSettings {
    var enabled: Bool = false
    var minimumConfidence: DetectionConfidence = .medium
    var featureTypesFilter: Set<FeatureType>
    var analyzeInRealtime: Bool = false
    var highlightColor: String = "yellow"
    var highlightOpacity: Double = 0.6

    // Algorithm parameters
    var slopeThreshold: Double = 5.0          // degrees
    var elevationChangeThreshold: Double = 1.0 // meters
    var circularityThreshold: Double = 0.7     // 0-1
    var linearityThreshold: Double = 0.8       // 0-1
    var minimumFeatureSize: Double = 5.0       // meters
    var maximumFeatureSize: Double = 500.0     // meters
}
```

## Architecture

### New Files Added

#### Models
- **`Models/HistoricalFeature.swift`**: Core data models
  - `FeatureType`: Enum of feature classifications
  - `DetectionConfidence`: Confidence level system
  - `HistoricalFeature`: Main feature model
  - `FeatureDimensions`: Physical dimensions
  - `FeatureMetadata`: Notes, verification, cultural context
  - `AnalysisSettings`: Detection configuration

#### Services
- **`Services/HistoricalAnalysisEngine.swift`**: Analysis engine (Actor-based)
  - Feature detection algorithms
  - Elevation data analysis
  - Feature management (CRUD operations)
  - Persistence layer
  - CSV export functionality

#### Map Components
- **`Map/HistoricalFeatureAnnotation.swift`**: Map visualization
  - `HistoricalFeatureAnnotation`: Custom map annotations
  - `HistoricalFeatureAnnotationView`: Styled annotation views
  - `HistoricalFeatureClusterAnnotation`: Clustered annotations
  - `HistoricalFeatureCircle`: Circle overlays
  - `HistoricalFeatureCircleRenderer`: Custom circle rendering

#### Views
- **`Views/HistoricalFeaturesView.swift`**: Feature list UI
  - Search and filter interface
  - Feature list with detailed rows
  - Export view with share functionality
  - Preview support

### Modified Files

#### ViewModels
- **`ViewModels/ContentViewModel.swift`**: Added analysis state management
  - `analysisEnabled`: Toggle for analysis mode
  - `detectedFeatures`: Array of detected features
  - `showFeatureDetails`: Selected feature for navigation
  - `isAnalyzing`: Analysis progress indicator
  - Methods for feature loading, analysis, and export

#### Map
- **`Map/USGSMapView.swift`**: Extended map functionality
  - Support for feature annotations
  - Feature circle overlay rendering
  - Dynamic annotation updates
  - Annotation view delegation

#### Views
- **`Views/ContentView.swift`**: Enhanced UI
  - Analysis toggle in layer menu
  - Feature count display
  - Features list button with badge counter
  - Sheet presentation for features list
  - Feature detail navigation

## Usage Instructions

### For Users

1. **Enable Analysis Mode**
   - Open the layer menu (3D layers icon)
   - Toggle "Historical Analysis" on
   - The app will load known historical sites

2. **View Detected Features**
   - Features appear as colored pins on the map
   - Circle overlays highlight areas of interest
   - Pin colors indicate confidence level

3. **Browse Features List**
   - Tap the list icon (shows feature count badge)
   - Search by name or filter by confidence
   - Tap any feature to navigate to it on the map

4. **Export Discoveries**
   - Open features list
   - Tap the export icon (top right)
   - Share CSV with coordinates and details

### For Developers

#### Running Analysis

```swift
// Get current map region
let region = mapView.region

// Generate or fetch elevation data (DEM)
let elevationData: [[Double]] = fetchDEMData(for: region)

// Run analysis
let features = await HistoricalAnalysisEngine.shared.analyzeRegion(
    region: region,
    elevationData: elevationData
)
```

#### Customizing Detection

```swift
// Update analysis settings
var settings = AnalysisSettings()
settings.elevationChangeThreshold = 2.0  // Require 2m height difference
settings.slopeThreshold = 10.0            // Increase slope sensitivity
settings.minimumFeatureSize = 10.0        // Ignore features < 10m

await HistoricalAnalysisEngine.shared.updateSettings(settings)
```

#### Adding Known Sites

```swift
let newSite = HistoricalFeature(
    coordinate: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
    featureType: .settlement,
    confidence: .confirmed,
    metadata: FeatureMetadata(
        customName: "Colonial Settlement",
        historicalPeriod: "1650-1750 CE",
        culture: "Dutch Colonial",
        verified: true
    )
)

await HistoricalAnalysisEngine.shared.addFeature(newSite)
```

## Future Enhancements

### Planned Features

1. **Real DEM Integration**
   - Fetch actual elevation data from USGS 3DEP
   - High-resolution analysis (1m DEM)
   - Cache processed results

2. **Advanced Algorithms**
   - Machine learning-based detection
   - Multi-angle hillshade comparison
   - Texture analysis for vegetation patterns
   - Shadow analysis for subtle features

3. **Historical Context**
   - Native American territories overlay
   - Colonial settlement data
   - Civil War sites
   - Historical trail maps
   - Archaeological site registry integration

4. **Collaboration**
   - Share discoveries with community
   - Crowdsourced verification
   - Field report submission
   - Photo uploads

5. **Field Tools**
   - Offline mode for remote exploration
   - GPS waypoint navigation
   - Augmented reality feature overlay
   - Distance and bearing to features

6. **Enhanced Analysis**
   - Temporal analysis (compare historical imagery)
   - Spectral analysis (multispectral LIDAR)
   - Drainage pattern detection
   - Vegetation anomaly detection

## Technical Notes

### Performance Considerations

- Analysis runs asynchronously using Swift Concurrency (Actor model)
- Elevation data is processed in chunks to manage memory
- Results are cached using UserDefaults (can be migrated to Core Data)
- Map annotations use clustering for performance with many features

### Data Sources

Currently uses mock elevation data for demonstration. Production implementation should:

- Fetch DEM data from USGS 3DEP via REST API
- Use GDAL or similar for DEM processing
- Implement tile-based analysis for large areas
- Cache processed elevation tiles

### Accuracy and Limitations

- Detection algorithms are heuristic-based and may produce false positives
- Requires high-quality LIDAR data (1m resolution or better)
- Natural features (rock outcrops, erosion) can mimic human-made structures
- Ground-truthing recommended for all discoveries
- Legal and ethical considerations apply to archaeological sites

## Credits

- USGS 3DEP for LIDAR data
- Historical site data from National Park Service and state archaeological databases
- Detection algorithms inspired by archaeological remote sensing techniques

## License

This feature is part of LidarExplorer. Check main repository for licensing terms.

## Contributing

To add new detection algorithms or improve existing ones:

1. Extend `HistoricalAnalysisEngine` with new detection methods
2. Add corresponding `FeatureType` if needed
3. Update confidence scoring based on validation
4. Submit pull request with test cases

## Support

For questions, bug reports, or feature requests, please open an issue on the GitHub repository.

---

**Happy discovering! May you find the hidden history beneath our feet.**
