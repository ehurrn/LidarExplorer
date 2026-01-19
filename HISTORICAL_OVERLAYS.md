# Historical Context Overlays Implementation

This document describes the Historical Context Overlays feature that was added to the LidarExplorer app.

## Overview

The Historical Context Overlays feature adds visual layers to the map showing historical sites, territories, and trails across the United States. Users can toggle these overlays on and off to explore different aspects of American history.

## Features Implemented

### 1. Native American Territories
- **Cherokee Nation**: Southeastern US (pre-1838)
- **Lakota Territory**: Great Plains including the Black Hills (pre-1868)
- **Dinétah (Navajo Homeland)**: Four Corners region (1400s-Present)
- **Haudenosaunee Territory**: Iroquois Confederacy in New York (1100s-1779)

Displayed as semi-transparent colored polygons on the map.

### 2. Civil War Sites
- Gettysburg Battlefield (PA)
- Appomattox Court House (VA)
- Fort Sumter (SC)
- Antietam Battlefield (MD)
- Vicksburg Battlefield (MS)
- Shiloh Battlefield (TN)

Displayed as red map pins with flag icons.

### 3. Historical Trails
- **Oregon Trail**: Independence, MO to Portland, OR (1841-1869)
- **Santa Fe Trail**: Independence, MO to Santa Fe, NM (1821-1880)
- **Trail of Tears**: Cherokee removal route (1838-1839)
- **California Trail**: Route to Sacramento during Gold Rush (1841-1869)

Displayed as dashed orange lines following the historical routes.

### 4. Archaeological Sites
- Mesa Verde (CO) - Ancestral Puebloan cliff dwellings
- Cahokia Mounds (IL) - Largest pre-Columbian settlement
- Chaco Canyon (NM) - Major ceremonial center
- Poverty Point (LA) - Ancient earthworks
- Serpent Mound (OH) - Prehistoric effigy mound
- Hopewell Culture Site (OH) - Trade network center
- Taos Pueblo (NM) - Continuously inhabited for 1,000+ years

Displayed as blue map pins with column icons.

## Files Added

### Models
- **HistoricalOverlay.swift**: Data models for territories, trails, and sites
  - `HistoricalTerritory`: Polygon areas for territories
  - `HistoricalTrail`: Polyline paths for trails
  - `HistoricalSite`: Point locations for sites
  - Custom overlay classes for MapKit integration

### Services
- **HistoricalOverlayService.swift**: Data provider with sample historical data
  - Methods to retrieve territories, trails, and sites
  - Comprehensive sample data covering major US historical locations

### Updates to Existing Files
- **ContentViewModel.swift**: Added state management for overlay toggles and data
- **ContentView.swift**: Added UI controls in the layer menu for toggling overlays
- **USGSMapView.swift**: Added rendering logic for overlays and annotations

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

## Notes for Developers

To add more historical data:

1. Open `HistoricalOverlayService.swift`
2. Add new entries to the appropriate method:
   - `getNativeAmericanTerritories()`
   - `getCivilWarSites()`
   - `getHistoricalTrails()`
   - `getArchaeologicalSites()`
3. Use the existing data as templates for the correct format
4. Coordinates should follow the geographic boundaries or paths accurately

The service will automatically load the new data when the app starts.
