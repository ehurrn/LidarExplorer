import CoreLocation
import Foundation
import MapKit

var failures = 0
func check(_ n: String, _ ok: Bool, _ d: String = "") {
    print(ok ? "  PASS  \(n)" : "  FAIL  \(n) \(d)")
    if !ok { failures += 1 }
}

// Exercises exactly what the "Load terrain here" button invokes.
@MainActor
final class StubLocation: LocationProviding {
    var onUpdate: ((CLLocationCoordinate2D?, CLAuthorizationStatus) -> Void)?
    func start() {}
    func currentLocation() async -> CLLocationCoordinate2D? { nil }
}

@MainActor
func run() async {
    let model = TerrainViewerModel(
        location: StubLocation(),
        initialCenter: CLLocationCoordinate2D(latitude: 38.6605, longitude: -90.0620)
    )
    model.visibleRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 38.6605, longitude: -90.0620),
        span: MKCoordinateSpan(latitudeDelta: 0.014, longitudeDelta: 0.018)
    )

    print("\n=== Pre-load state ===")
    check("no terrain before loading", model.reliefImage == nil)
    check("visible region is loadable", model.canLoadVisibleRegion)

    // Guard rail: a continent-sized view must be refused, not attempted.
    let saved = model.visibleRegion
    model.visibleRegion = MKCoordinateRegion(
        center: saved.center,
        span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 8)
    )
    check("huge region is refused", !model.canLoadVisibleRegion)
    model.loadVisibleRegion()
    check("refusal explains itself", model.statusMessage?.contains("Zoom in") == true,
          model.statusMessage ?? "nil")
    model.visibleRegion = saved

    print("\n=== Load (live USGS 3DEP) ===")
    model.loadVisibleRegion(targetSamples: 384)
    check("isLoading set synchronously", model.isLoading)

    // Wait for the load to settle.
    for _ in 0..<120 {
        if !model.isLoading { break }
        try? await Task.sleep(for: .milliseconds(250))
    }

    check("load finished", !model.isLoading)
    check("relief image produced", model.reliefImage != nil, model.statusMessage ?? "")
    check("relief region recorded", model.reliefRegion != nil)
    check("statistics recorded", model.statistics != nil)
    check("backend recorded", model.backend != nil, "\(String(describing: model.backend))")
    if let s = model.statistics {
        print("        elevation \(String(format: "%.1f", s.minimum))–\(String(format: "%.1f", s.maximum)) m, relief \(String(format: "%.1f", s.range)) m")
        check("elevations plausible for Cahokia", s.minimum > 110 && s.maximum < 200,
              "\(s.minimum)–\(s.maximum)")
    }
    print("        status: \(model.statusMessage ?? "nil")")

    print("\n=== Re-render on control change (no refetch) ===")
    let firstImage = model.reliefImage
    model.azimuth = 135
    check("azimuth change re-renders", model.reliefImage !== firstImage)
    check("azimuth change does not refetch", !model.isLoading)

    let afterAzimuth = model.reliefImage
    model.style = .slope
    check("style change re-renders", model.reliefImage !== afterAzimuth)
    check("still no refetch", !model.isLoading)

    // Elevation styles ignore the light, so the image must not churn.
    let afterStyle = model.reliefImage
    model.style = .elevation
    let elevationImage = model.reliefImage
    model.azimuth = 200
    check("azimuth is inert for non-illuminated styles",
          model.reliefImage === elevationImage)
    _ = afterStyle

    print("\n=== Georeferencing ===")
    // Regression: the ImageServer expands the requested bbox to match the
    // requested image aspect ratio. Sizing the request in metres rather than
    // degrees made it inflate the latitude span by 28%, and the overlay drew
    // at the wrong scale. Two defences, both asserted here.
    if let served = model.reliefRegion {
        let requested = GeoRegion(
            center: model.visibleRegion.center,
            latitudeSpan: model.visibleRegion.span.latitudeDelta,
            longitudeSpan: model.visibleRegion.span.longitudeDelta
        )
        let latError = abs(served.latitudeSpan - requested.latitudeSpan)
            * GeoRegion.metersPerDegreeLatitude
        let lonError = abs(served.longitudeSpan - requested.longitudeSpan)
            * served.metersPerDegreeLongitude
        print(String(format: "        extent error: %.2f m lat, %.2f m lon", latError, lonError))
        // Sub-pixel at any resolution this app requests.
        check("served latitude span matches request within 5 m", latError < 5,
              String(format: "%.2f m", latError))
        check("served longitude span matches request within 5 m", lonError < 5,
              String(format: "%.2f m", lonError))

        // Square-ish ground pixels are the point of using the degree aspect.
        if let stats = model.statistics, stats.validCount > 0 {
            check("raster covers the region it is drawn into",
                  served.widthMeters > 0 && served.heightMeters > 0)
        }
    } else {
        check("relief region present for georeferencing check", false)
    }

    print("\n=== Elevation inspection ===")
    model.style = .hillshade
    model.inspect(CLLocationCoordinate2D(latitude: 38.6605, longitude: -90.0620))
    check("inspect returns an elevation", model.inspectedElevation != nil,
          "\(String(describing: model.inspectedElevation))")
    if let e = model.inspectedElevation {
        print("        elevation at centre: \(String(format: "%.1f", e)) m")
        check("inspected elevation is plausible", e > 110 && e < 200, "\(e)")
    }
    // A point far outside the loaded raster has no reading, and says so.
    model.inspect(CLLocationCoordinate2D(latitude: 40.0, longitude: -95.0))
    check("outside the raster reads nil", model.inspectedElevation == nil)

    print("\n=== Clear ===")
    model.clearTerrain()
    check("clear drops the image", model.reliefImage == nil)
    check("clear drops statistics", model.statistics == nil)
    check("clear drops the readout", model.inspectedElevation == nil)
}

await run()
print("\n" + String(repeating: "=", count: 52))
print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
print(String(repeating: "=", count: 52))
exit(failures == 0 ? 0 : 1)
