# Historical Overlay Data

This directory contains JSON files with historical data for the LidarExplorer app. The data is loaded at app startup and cached for performance.

## Data Files

- **native_american_territories.json** - Native American territorial boundaries
- **historical_trails.json** - Historic migration and trade routes
- **civil_war_sites.json** - American Civil War battlefields and significant locations
- **archaeological_sites.json** - Prehistoric and historic archaeological sites

## How to Add New Data

### Adding a Native American Territory

Edit `native_american_territories.json` and add a new entry:

```json
{
  "name": "Territory Name",
  "type": "nativeAmericanTerritory",
  "culturalGroup": "Cultural Group Name",
  "timePeriod": "Time Period (e.g., 1500s-1800s)",
  "description": "Detailed description of the territory",
  "coordinates": [
    {"latitude": 40.0, "longitude": -100.0},
    {"latitude": 41.0, "longitude": -99.0},
    {"latitude": 40.5, "longitude": -98.0}
  ]
}
```

**Notes:**
- Coordinates should form a polygon outlining the territory
- List coordinates in order (clockwise or counter-clockwise)
- At least 3 coordinates required

### Adding a Historical Trail

Edit `historical_trails.json` and add a new entry:

```json
{
  "name": "Trail Name",
  "timePeriod": "Time Period",
  "lengthMiles": 1000,
  "description": "Description of the trail and its historical significance",
  "coordinates": [
    {"latitude": 39.0, "longitude": -94.0},
    {"latitude": 40.0, "longitude": -96.0},
    {"latitude": 41.0, "longitude": -98.0}
  ]
}
```

**Notes:**
- Coordinates should follow the trail route in order
- `lengthMiles` is optional but recommended
- More coordinates = smoother trail line on map

### Adding a Civil War Site

Edit `civil_war_sites.json` and add a new entry:

```json
{
  "name": "Battle/Site Name",
  "type": "civilWarSite",
  "coordinate": {"latitude": 38.0, "longitude": -77.0},
  "timePeriod": "Date or date range",
  "significance": "Why this site was important",
  "dateEstablished": "Date (optional)",
  "description": "Detailed description of what happened here"
}
```

**Notes:**
- Use a single coordinate for the site location (center of battlefield/fort/etc.)
- `dateEstablished` can be null/omitted if not applicable

### Adding an Archaeological Site

Edit `archaeological_sites.json` and add a new entry:

```json
{
  "name": "Site Name",
  "type": "archaeologicalSite",
  "coordinate": {"latitude": 36.0, "longitude": -109.0},
  "timePeriod": "Time Period (e.g., 1000-1300 CE)",
  "significance": "Historical/archaeological significance",
  "dateEstablished": "When site was built/established",
  "description": "Description of the archaeological site"
}
```

## Data Validation

After editing JSON files:

1. **Validate JSON syntax** - Use a JSON validator to ensure proper formatting
2. **Check coordinates** - Verify latitude/longitude values are correct
3. **Test in app** - Run the app and toggle overlays to verify data loads correctly

The app will print loading statistics to the console:
```
📚 Loaded historical data:
   - X Native American territories
   - X historical trails
   - X Civil War sites
   - X archaeological sites
```

If you see `0` for any category, check the console for error messages.

## Common Errors

### "Could not find X.json in bundle"
- The JSON file is not included in the Xcode project
- Right-click the Resources folder in Xcode → Add Files
- Make sure "Copy items if needed" is checked
- Verify the file is in the app target

### "Error decoding X"
- JSON syntax error (missing comma, bracket, etc.)
- Use a JSON validator like jsonlint.com
- Check that all required fields are present

### Coordinates not visible on map
- Check latitude/longitude values are within valid ranges
  - Latitude: -90 to 90
  - Longitude: -180 to 180
- For US locations, longitude should be negative (west of prime meridian)

## Data Sources

When adding data, document your sources:
- National Park Service
- National Register of Historic Places
- State historical societies
- Archaeological surveys
- Academic publications

## Performance Considerations

The current implementation loads all data at startup and filters by viewport. This works well for:
- Up to ~100 territories
- Up to ~200 trails
- Up to ~500 sites per category

For larger datasets (1000+ items), consider implementing:
- Spatial indexing (R-tree or similar)
- Region-based JSON files (e.g., by state or region)
- Lazy loading based on zoom level

## Future Enhancements

Planned features for data loading:
- Remote JSON loading from a CDN/API
- Automatic updates when new data is published
- User-contributed sites (with moderation)
- Integration with NPS and other government databases
- Time-period filtering
- Multiple language support

## Questions?

For issues or questions about the data format, see:
- Main documentation: `/HISTORICAL_OVERLAYS.md`
- Code: `/Services/HistoricalOverlayService.swift`
- Data models: `/Models/HistoricalOverlay.swift`
