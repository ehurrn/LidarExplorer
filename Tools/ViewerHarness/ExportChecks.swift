//
//  ExportChecks.swift
//  ViewerHarness
//
//  The viewer model's export flows: file names, analysis options, GeoTIFF and transect exports, and what
//  producing them must not do to the main actor.
//

import CoreLocation
import Foundation
import MapKit
import simd

@MainActor
func runExportChecks() async {
    print("\n=== Export wiring (model) ===")
    checkExportNamesAndOptions()
    await checkGeoTIFFExports()
    await checkTransectExports()
    await checkExportsStayOffTheMainActor()
}

/// Polls `condition` on the main actor until it holds or `seconds` pass.
@MainActor
private func wait(seconds: Double = 10, until condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

@MainActor
private func checkExportNamesAndOptions() {
    print("\n--- E1. names and analysis options ---")
    let zone = TimeZone(identifier: "UTC")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 14, minute: 15, second: 30))!
    let names = [
        ExportFileName.geoTIFF(.elevation, date: date, timeZone: zone),
        ExportFileName.geoTIFF(.analytical(.localRelief), date: date, timeZone: zone),
        ExportFileName.geoTIFF(.analytical(.skyView), date: date, timeZone: zone),
    ]
    check("GeoTIFF export names carry the content and a sortable timestamp",
          names == ["LidarExplorer_Elevation_20260920-141530.tif", "LidarExplorer_LRM_20260920-141530.tif",
                    "LidarExplorer_SVF_20260920-141530.tif"], "\(names)")
    let transectNames = [ExportFileName.transect(.csv, date: date, timeZone: zone),
                         ExportFileName.transect(.geoJSON, date: date, timeZone: zone)]
    check("transect export names carry the format's extension",
          transectNames == ["LidarExplorer_Transect_20260920-141530.csv", "LidarExplorer_Transect_20260920-141530.geojson"],
          "\(transectNames)")

    var settings = TerrainStyleSettings()
    settings.azimuthDegrees = 200
    settings.rakingAltitudeDegrees = 7
    settings.microTopographyOptions.lrmRadiusMeters = 33
    let raking = settings.analysisOptions(for: .rakingLight)
    let occlusion = settings.analysisOptions(for: .directionalOcclusion)
    let relief = settings.analysisOptions(for: .localRelief)
    check("analysis options take the dock's sun for the low-sun products and the tuned options for the rest",
          raking.sunAzimuthDegrees == 200 && raking.sunAltitudeDegrees == 7
            && occlusion.directionalOcclusionAzimuthDegrees == 200 && occlusion.directionalOcclusionAltitudeDegrees == 7
            && relief == settings.microTopographyOptions && raking.lrmRadiusMeters == 33 && occlusion.lrmRadiusMeters == 33,
          "raking \(raking.sunAzimuthDegrees)/\(raking.sunAltitudeDegrees), occlusion \(occlusion.directionalOcclusionAzimuthDegrees)/\(occlusion.directionalOcclusionAltitudeDegrees)")
}

@MainActor
private func checkGeoTIFFExports() async {
    print("\n--- E2. GeoTIFF exports ---")
    guard await MetalTerrainPipelineActor.shared.isAvailable() else {
        print("        (skipped: no Metal micro-topography pipeline)")
        return
    }
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    defer { try? FileManager.default.removeItem(at: scene.directory) }
    let model = TerrainViewerModel(terrainProvider: scene.provider)
    await scene.loadNeighbourhood()
    let tile = scene.region()
    model.visibleRegion = MKCoordinateRegion(
        center: tile.center, span: MKCoordinateSpan(latitudeDelta: tile.latitudeSpan, longitudeDelta: tile.longitudeSpan))

    // Which styles offer an analytical export: the micro-topography products, less the thalweg-bound REM.
    let offered = ReliefStyle.allCases.filter { style in
        model.style = style
        return model.analyticalExportStyle == style
    }
    let expected = ReliefStyle.allCases.filter { $0.microTopographyProduct != nil && $0 != .relativeElevation }
    check("an analytical export is offered for every micro-topography style except the relative elevation model",
          !expected.isEmpty && Set(offered) == Set(expected), "\(offered.map(\.dockLabel)) vs \(expected.map(\.dockLabel))")

    model.style = .localRelief
    var elevationURL: URL?, reliefURL: URL?
    do { elevationURL = try await model.exportCurrentGeoTIFF() } catch {}
    do { reliefURL = try await model.exportCurrentGeoTIFF(.analytical(.localRelief)) } catch {}
    defer { for url in [elevationURL, reliefURL] { url.map { try? FileManager.default.removeItem(at: $0) } } }
    func directory(_ url: URL?) -> TIFFDirectory? { (url.flatMap { try? Data(contentsOf: $0) }).flatMap { TIFFDirectory($0) } }
    let elevationFile = directory(elevationURL), reliefFile = directory(reliefURL)
    check("the elevation export is a 32-bit float GeoTIFF named for its content, whatever style is active",
          elevationURL?.lastPathComponent.hasPrefix("LidarExplorer_Elevation_") == true && elevationURL?.pathExtension == "tif"
            && elevationFile?.value(258) == 32 && elevationFile?.value(339) == 3 && (elevationFile?.value(256) ?? 0) > 30,
          "\(elevationURL?.lastPathComponent ?? "no file"), bits \(String(describing: elevationFile?.value(258)))")
    let region = GeoRegion(
        center: model.visibleRegion.center, latitudeSpan: model.visibleRegion.span.latitudeDelta,
        longitudeSpan: model.visibleRegion.span.longitudeDelta)
    let expectedRelief = await scene.provider.analyticalRaster(for: region, product: .localRelief)
    check("the analytical export is a 32-bit float GeoTIFF of the active product, named for it, at the product's own size",
          reliefURL?.lastPathComponent.hasPrefix("LidarExplorer_LRM_") == true && reliefURL?.pathExtension == "tif"
            && reliefFile?.value(258) == 32 && reliefFile?.value(339) == 3 && expectedRelief != nil
            && reliefFile?.value(256) == expectedRelief?.width && reliefFile?.value(257) == expectedRelief?.height,
          "\(reliefURL?.lastPathComponent ?? "no file"), \(String(describing: reliefFile?.value(256)))x\(String(describing: reliefFile?.value(257))) vs \(String(describing: expectedRelief?.width))")

    model.style = .relativeElevation
    var refusedRelativeElevation = false
    do { _ = try await model.exportCurrentGeoTIFF(.analytical(.relativeElevation)) }
    catch let error as TerrainExportError { refusedRelativeElevation = error == .analyticalUnavailable(.relativeElevation) }
    catch {}
    check("a relative elevation export is refused, since it needs a river thalweg this call cannot take",
          refusedRelativeElevation && model.analyticalExportStyle == nil)

    // Sharing: publish the file and present the sheet, or say why not.
    model.style = .localRelief
    await model.shareGeoTIFF(.analytical(.localRelief))
    let shared = model.exportURL
    defer { shared.map { try? FileManager.default.removeItem(at: $0) } }
    check("sharing an export publishes its file and presents the share sheet",
          model.showsExportSheet && shared.map { FileManager.default.fileExists(atPath: $0.path) } == true
            && model.exportErrorMessage == nil && !model.isPreparingExport)
    model.showsExportSheet = false
    model.style = .relativeElevation
    await model.shareGeoTIFF(.analytical(.relativeElevation))
    check("a refused export reports why instead of presenting a share sheet",
          !model.showsExportSheet && model.exportErrorMessage?.isEmpty == false && !model.isPreparingExport)
}

@MainActor
private func checkTransectExports() async {
    print("\n--- E3. transect exports ---")
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: -30)
    defer { try? FileManager.default.removeItem(at: scene.directory) }
    await scene.loadNeighbourhood()
    let model = TerrainViewerModel(terrainProvider: scene.provider)
    let tile = scene.region()
    let start = CLLocationCoordinate2D(latitude: tile.center.latitude, longitude: tile.minLongitude + 0.0001)
    let end = CLLocationCoordinate2D(latitude: tile.center.latitude, longitude: tile.maxLongitude - 0.0001)

    let canBefore = model.canExportTransect
    model.profileStart = start
    model.profileEnd = end
    model.generateProfile()
    let ready = await wait { model.activeTransectAnalysis != nil }
    guard ready, let analysis = model.activeTransectAnalysis else {
        check("a transect is analysed before it is exported", false, "no analysis within 10 s")
        return
    }
    let canAfter = model.canExportTransect
    model.isTransectDragging = true
    let canWhileDragging = model.canExportTransect
    model.isTransectDragging = false
    check("a finished transect can be exported, and nothing can before one exists or while one is being drawn",
          !canBefore && canAfter && !canWhileDragging, "before \(canBefore), after \(canAfter), dragging \(canWhileDragging)")

    var csvURL: URL?, geoJSONURL: URL?
    do { csvURL = try await model.exportActiveTransect(as: .csv) } catch {}
    do { geoJSONURL = try await model.exportActiveTransect(as: .geoJSON) } catch {}
    defer { for url in [csvURL, geoJSONURL] { url.map { try? FileManager.default.removeItem(at: $0) } } }
    let csv = csvURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    let records = csv.components(separatedBy: "\r\n")
    check("the CSV export is a file named for the transect: the profile's header and one row per sample",
          csvURL?.lastPathComponent.hasPrefix("LidarExplorer_Transect_") == true && csvURL?.pathExtension == "csv"
            && records.first == "distance_meters,elevation_meters,along_track_slope_degrees,curvature_rad_per_meter,latitude,longitude"
            && records.count == analysis.samples.count + 2, "\(records.count) records for \(analysis.samples.count) samples")

    // The frame the analysis was measured in travelled with it: the track must run from where the transect
    // started to where it ended, not from wherever the endpoints have moved to since.
    let root = (geoJSONURL.flatMap { try? Data(contentsOf: $0) }).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    let features = root?["features"] as? [[String: Any]] ?? []
    let profile = features.first { (($0["properties"] as? [String: Any])?["type"] as? String) == "transectProfile" }
    let track = (profile?["geometry"] as? [String: Any])?["coordinates"] as? [[Double]] ?? []
    let first = track.first ?? [], last = track.last ?? []
    let startsAtStart = first.count == 3 && abs(first[0] - start.longitude) < 2e-7 && abs(first[1] - start.latitude) < 2e-7
    let endsAtEnd = last.count == 3 && abs(last[0] - end.longitude) < 8e-6 && abs(last[1] - end.latitude) < 8e-6
    check("the GeoJSON export is a file whose track runs from the transect's start to its end",
          geoJSONURL?.pathExtension == "geojson" && root?["type"] as? String == "FeatureCollection" && startsAtStart && endsAtEnd,
          "first \(first), last \(last) for start \(start.longitude),\(start.latitude) end \(end.longitude),\(end.latitude)")

    // Nothing to export, or a transect still being drawn: refused, not written half-finished.
    let fresh = TerrainViewerModel(terrainProvider: scene.provider)
    var nothingRefused = false
    do { _ = try await fresh.exportActiveTransect(as: .csv) }
    catch let error as TerrainExportError { nothingRefused = error == .noTransect }
    catch {}
    model.isTransectDragging = true
    var draggingRefused = false
    do { _ = try await model.exportActiveTransect(as: .csv) }
    catch let error as TerrainExportError { draggingRefused = error == .transectInProgress }
    catch {}
    model.isTransectDragging = false
    check("no transect, or one still being drawn, is refused", nothingRefused && draggingRefused)

    await model.shareTransect(as: .geoJSON)
    let shared = model.exportURL
    defer { shared.map { try? FileManager.default.removeItem(at: $0) } }
    check("sharing a transect publishes its file and presents the share sheet",
          model.showsExportSheet && shared?.pathExtension == "geojson"
            && shared.map { FileManager.default.fileExists(atPath: $0.path) } == true
            && model.exportErrorMessage == nil && !model.isPreparingExport)
    await fresh.shareTransect(as: .csv)
    check("sharing with no transect reports why instead of presenting a share sheet",
          !fresh.showsExportSheet && fresh.exportErrorMessage?.isEmpty == false && !fresh.isPreparingExport)

    let hadFrame = model.activeTransectFrame != nil
    model.clearProfile()
    check("clearing the profile drops the transect and its frame together",
          hadFrame && model.activeTransectAnalysis == nil && model.activeTransectFrame == nil && !model.canExportTransect)
}

@MainActor
private func checkExportsStayOffTheMainActor() async {
    print("\n--- E4. exports leave the main actor free ---")
    // The longest transect the engine produces (about 20,000 samples), so formatting it takes real time.
    let big = makeGrid(width: 2100, height: 2100, gsd: 5.0, mounds: [(1000, 1000, 40, 80)])
    let field = GridElevationField(grid: big)
    let analysis = ElevationTransectEngine(field: field).analyze(from: SIMD2(100, 100), to: SIMD2(10_000, 100), stepDistance: 0.5)
    let model = TerrainViewerModel()
    model.activeTransectAnalysis = analysis
    model.activeTransectFrame = field

    var stalls: [String] = []
    var missing: [String] = []
    for format in TransectExportFormat.allCases {
        var finished = false
        var url: URL?
        let started = ContinuousClock.now
        Task {
            url = try? await model.exportActiveTransect(as: format)
            finished = true
        }
        // A main-actor ticker: if the export runs on the main actor, it cannot tick until the export is done.
        var previous = started
        var longestStall = 0.0
        while !finished {
            try? await Task.sleep(for: .milliseconds(2))
            let now = ContinuousClock.now
            longestStall = max(longestStall, milliseconds(now - previous))
            previous = now
        }
        let total = milliseconds(ContinuousClock.now - started)
        print(String(format: "        %@ of %d samples: %.0f ms, longest main-actor stall %.0f ms",
                     format.rawValue, analysis.samples.count, total, longestStall))
        if let url { try? FileManager.default.removeItem(at: url) } else { missing.append(format.rawValue) }
        // 40 ms is about five dropped frames at 120 Hz; off the main actor the ticker stalls for a few ms at most.
        if longestStall >= max(40, total * 0.5) { stalls.append("\(format.rawValue) \(Int(longestStall)) of \(Int(total)) ms") }
    }
    check("exporting a 20,000-sample transect does not stall the main actor, so profile scrubbing keeps running",
          missing.isEmpty && stalls.isEmpty, "no file for \(missing); stalled: \(stalls)")
}
