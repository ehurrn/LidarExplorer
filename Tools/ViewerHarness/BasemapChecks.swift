//
//  BasemapChecks.swift
//  ViewerHarness
//
//  Basemap selection: the USGS tile services and Apple's own basemap, which
//  has no tile service at all.
//

import Foundation
import MapKit

@MainActor
func runBasemapChecks() async {
    print("\n=== Basemap selection ===")

    print("\n--- E1. choices cover every service ---")
    let services = BasemapChoice.allCases.compactMap(\.tileService)
    check("every USGS service is offered exactly once",
          Set(services).count == services.count && Set(services) == Set(TerrainBasemap.allCases),
          "\(services.count) of \(TerrainBasemap.allCases.count)")
    check("Apple's basemap is offered alongside them",
          BasemapChoice.allCases.count == TerrainBasemap.allCases.count + 1,
          "\(BasemapChoice.allCases.count)")
    check("the USGS choices keep their existing order",
          Array(BasemapChoice.allCases.prefix(TerrainBasemap.allCases.count)) ==
          TerrainBasemap.allCases.map(BasemapChoice.usgs))

    let ids = BasemapChoice.allCases.map(\.id)
    let names = BasemapChoice.allCases.map(\.displayName)
    check("ids are unique", Set(ids).count == ids.count, "\(ids)")
    check("display names are unique and non-empty",
          Set(names).count == names.count && !names.contains(where: \.isEmpty), "\(names)")

    print("\n--- E2. opacity is a property of having a tile layer ---")
    // The opacity slider works by setting a tile overlay renderer's alpha.
    // Apple draws its basemap itself and exposes no alpha for it, so the
    // control has nowhere to send the value and the settings sheet hides it.
    // Both the sheet and the map coordinator branch on this one predicate, so
    // asserting the equivalence is what keeps them from drifting apart.
    for choice in BasemapChoice.allCases {
        check("\(choice.id): opacity support matches having a tile service",
              choice.supportsOpacity == (choice.tileService != nil))
    }
    check("exactly the USGS choices support opacity",
          BasemapChoice.allCases.filter(\.supportsOpacity).count == TerrainBasemap.allCases.count)
    check("Apple imagery does not support opacity", !BasemapChoice.appleImagery.supportsOpacity)
    check("Apple imagery has no tile service", BasemapChoice.appleImagery.tileService == nil)

    print("\n--- E3. USGS services unchanged ---")
    for basemap in TerrainBasemap.allCases {
        let template = basemap.urlTemplate
        check("\(basemap.rawValue) is an https XYZ template",
              template.hasPrefix("https://") && template.contains("{z}")
              && template.contains("{x}") && template.contains("{y}"), template)
        check("\(basemap.rawValue) declares a plausible service depth",
              (1...21).contains(basemap.maximumZ), "\(basemap.maximumZ)")
    }

    print("\n--- E4. USGS overlay contract unchanged ---")
    for basemap in TerrainBasemap.allCases {
        let overlay = HillshadeTileOverlay(basemap: basemap)
        // Only shaded relief lets MapKit keep drawing its own map underneath;
        // the others are opaque and replace it.
        check("\(basemap.rawValue) replaces map content iff it is opaque",
              overlay.canReplaceMapContent == (basemap != .shadedRelief))
        // The overlay claims depth past the service so MapKit keeps asking and
        // loadTile can upscale from the deepest real tile instead of holing.
        check("\(basemap.rawValue) serves to z21 via overzoom", overlay.maximumZ == 21)
        check("\(basemap.rawValue) uses 256 px tiles",
              overlay.tileSize == CGSize(width: 256, height: 256))
        overlay.invalidate()
    }
}
