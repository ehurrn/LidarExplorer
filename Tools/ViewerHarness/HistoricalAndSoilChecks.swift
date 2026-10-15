import CoreGraphics
import CoreLocation
import Foundation
import ImageIO
import MapKit

extension CGAffineTransform {
    func applied(_ p: CGPoint) -> CGPoint { p.applying(self) }
}

@MainActor
func checkWorldFiles() {
    print("\n--- D1. world files & import ---")
    let mercator = WorldFile(text: "2.0\n0.0\n0.0\n-2.0\n-10025800.0\n4673300.0\n")
    check("a six-line world file parses", mercator != nil)
    if let w = mercator {
        let corner = w.mapPoint(column: 0, row: 0)
        let expected = MKMapPoint(GeoRegion.fromMercatorMeters(x: -10025800, y: 4673300))
        check("EPSG:3857 world files map pixel centres to Mercator", abs(corner.x - expected.x) < 1e-3 && abs(corner.y - expected.y) < 1e-3)
        check("metre-scale coefficients are read as Web Mercator", w.units == .webMercatorMeters)
    }
    let degrees = WorldFile(text: "0.0001\n0\n0\n-0.0001\n-90.07\n38.67")
    check("degree-scale coefficients are read as geographic", degrees?.units == .degrees)
    let rotated = WorldFile(text: "2\n0.5\n0.5\n-2\n-10025800\n4673300")
    check("rotation terms produce a non-axis-aligned transform", (rotated?.mapTransform(imageWidth: 100, imageHeight: 100).c ?? 0) != 0)
    check("fewer than six numbers is not a world file", WorldFile(text: "1\n2\n3") == nil)

    let candidates = [URL(fileURLWithPath: "/tmp/fisk_1944.jgw"), URL(fileURLWithPath: "/tmp/other.pgw")]
    check("world files pair with images by basename, case-insensitively",
          HistoricalMapImporter.worldFileURL(for: URL(fileURLWithPath: "/tmp/Fisk_1944.JPG"), among: candidates)?.lastPathComponent == "fisk_1944.jgw")

    let big = harnessTemporaryDirectory.appendingPathComponent("historical-\(UUID().uuidString).png")
    let context = CGContext(data: nil, width: 4096, height: 100, bitsPerComponent: 8, bytesPerRow: 4096 * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.6, green: 0.5, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 4096, height: 100))
    _ = writePNG(context.makeImage()!, to: big.path)
    if let w = mercator, let imported = try? HistoricalMapImporter.importMap(imageURL: big, worldFile: w, fallbackRegion: makeGrid(width: 2, height: 2, gsd: 1).region) {
        check("huge scans decode at most 2048 px on the long side", max(imported.image.width, imported.image.height) <= 2048, "\(imported.image.width)x\(imported.image.height)")
        let fullWidthEdge = w.mapTransform(imageWidth: 4096, imageHeight: 100).applied(CGPoint(x: 4096, y: 0))
        let decodedEdge = imported.imageToMap.applied(CGPoint(x: imported.image.width, y: 0))
        check("downsampling rescales the transform so edges stay put", abs(fullWidthEdge.x - decodedEdge.x) < 1e-3)
    } else {
        check("historical image imports", false)
    }
    try? FileManager.default.removeItem(at: big)
}

/// A scanned quadrangle's GeoTIFF places itself: the world file read from its own tags, degrees or Web Mercator,
/// the first pixel's centre named; another projection is refused rather than placed wrongly.
@MainActor
func checkEmbeddedGeoTIFFWorldFile() {
    print("\n--- D7. a historical map's embedded GeoTIFF georeferencing ---")
    func tiff(scale: [Double], tiepoint: [Double], keys: [Int]?) -> Data {
        var entries: [TIFFFixture.Entry] = [
            .long(256, [4]), .long(257, [4]), .short(258, [8]), .short(259, [1]), .short(262, [1]), .short(277, [1]),
            .long(322, [4]), .long(323, [4]),
            .double(33550, scale), .double(33922, tiepoint),
        ]
        if let keys { entries.append(.short(34735, keys)) }
        return Data(TIFFFixture.build([TIFFFixture.IFD(entries: entries, tiles: [[UInt8](repeating: 128, count: 16)])]))
    }
    // WGS 84 degrees, PixelIsArea: the tiepoint is the top-left corner, the world file names the centre.
    let degrees = WorldFile(geoTIFF: tiff(scale: [0.0001, 0.0002, 0], tiepoint: [0, 0, 0, -90.07, 38.67, 0],
                                          keys: [1, 1, 0, 3, 1024, 0, 1, 2, 1025, 0, 1, 1, 2048, 0, 1, 4326]))
    check("a WGS 84 GeoTIFF gives a degree world file with the first pixel's centre half a pixel in",
          degrees.map { $0.units == .degrees && abs($0.a - 0.0001) < 1e-12 && abs($0.e + 0.0002) < 1e-12 && $0.b == 0 && $0.d == 0
                         && abs($0.c - (-90.07 + 0.00005)) < 1e-9 && abs($0.f - (38.67 - 0.0001)) < 1e-9 } == true,
          "\(String(describing: degrees))")
    // Web Mercator, PixelIsPoint: the tiepoint already names the centre.
    let mercator = WorldFile(geoTIFF: tiff(scale: [2, 2, 0], tiepoint: [0, 0, 0, -10_025_000, 4_680_000, 0],
                                           keys: [1, 1, 0, 3, 1024, 0, 1, 1, 1025, 0, 1, 2, 3072, 0, 1, 3857]))
    check("a Web Mercator GeoTIFF gives a metre world file, the tiepoint taken as the pixel's centre",
          mercator.map { $0.units == .webMercatorMeters && $0.a == 2 && $0.e == -2 && $0.c == -10_025_000 && $0.f == 4_680_000 } == true,
          "\(String(describing: mercator))")
    let utm = WorldFile(geoTIFF: tiff(scale: [1, 1, 0], tiepoint: [0, 0, 0, 500_000, 4_280_000, 0],
                                      keys: [1, 1, 0, 2, 1024, 0, 1, 1, 3072, 0, 1, 32615]))
    check("a UTM GeoTIFF is refused rather than placed as metres of Web Mercator", utm == nil)
    check("a TIFF with no georeferencing tags, and a file that is no TIFF, give no world file",
          WorldFile(geoTIFF: Data(TIFFFixture.build([TIFFFixture.IFD(entries: [.long(256, [4]), .long(257, [4]), .long(322, [4]), .long(323, [4])],
                                                                      tiles: [[UInt8](repeating: 0, count: 16)])]))) == nil
            && WorldFile(geoTIFF: Data("PNG".utf8)) == nil)
}

@MainActor
func checkSoilModel() {
    print("\n--- D3. soil model ---")
    func unit(_ name: String, _ drainage: String?, _ hydric: Int?) -> SoilClass {
        SoilMapUnit(mukey: "1", name: name, drainageClass: drainage, hydricPercent: hydric).soilClass
    }
    check("Sharkey clay, very poorly drained → hydric clay",
          unit("Sharkey clay, 0 to 1 percent slopes, frequently flooded", "Very poorly drained", 95) == .hydricClay)
    check("Tunica silty clay at 80% hydric → hydric clay", unit("Tunica silty clay, 0 to 1 percent slopes", "Poorly drained", 80) == .hydricClay)
    check("Bosket very fine sandy loam, well drained → sandy levee",
          unit("Bosket very fine sandy loam, 1 to 3 percent slopes", "Well drained", 0) == .wellDrainedSandyLoam)
    check("Crevasse loamy sand, excessively drained → sandy levee", unit("Crevasse loamy sand", "Excessively drained", nil) == .wellDrainedSandyLoam)
    check("somewhat poorly drained silt loam → other", unit("Commerce silt loam, 0 to 1 percent slopes", "Somewhat poorly drained", 30) == .other)
    check("texture is the longest phrase before the comma", SoilClassifier.texture(inName: "Commerce silty clay loam, occasionally flooded") == "silty clay loam")

    let square = "POLYGON ((-90.1 38.6, -90.0 38.6, -90.0 38.7, -90.1 38.7, -90.1 38.6), (-90.06 38.64, -90.04 38.64, -90.04 38.66, -90.06 38.66, -90.06 38.64))"
    let parsed = WKTPolygonParser.polygons(square)
    check("WKT POLYGON parses its exterior and hole", parsed?.count == 1 && parsed?.first?.count == 2 && parsed?.first?.first?.count == 5)
    let multi = WKTPolygonParser.polygons("MULTIPOLYGON (((0 0, 1 0, 1 1, 0 0)), ((2 2, 3 2, 3 3, 2 2)))")
    check("WKT MULTIPOLYGON parses every part", multi?.count == 2)
    check("non-polygon WKT is rejected", WKTPolygonParser.polygons("POINT (1 2)") == nil)

    if let parts = parsed, let polygon = SoilPolygon(unit: SoilMapUnit(mukey: "9", name: "Sharkey clay", drainageClass: "Poorly drained", hydricPercent: 90), parts: parts) {
        check("a point in the ring is inside", polygon.contains(CLLocationCoordinate2D(latitude: 38.62, longitude: -90.08)))
        check("a point in the hole is outside", !polygon.contains(CLLocationCoordinate2D(latitude: 38.65, longitude: -90.05)))
        let survey = SoilSurvey(polygons: [polygon])
        check("the survey answers the map unit under a coordinate", survey.unit(at: CLLocationCoordinate2D(latitude: 38.62, longitude: -90.08))?.mukey == "9")
    }

    let geojson = """
    {"type":"FeatureCollection","features":[{"type":"Feature","properties":{"mukey":"123","muname":"Bosket fine sandy loam","drclassdcd":"Well drained","hydclprs":0},
     "geometry":{"type":"Polygon","coordinates":[[[-90.1,38.6],[-90.0,38.6],[-90.0,38.7],[-90.1,38.6]]]}}]}
    """
    let features = (try? SoilGeoJSON.polygons(from: Data(geojson.utf8))) ?? []
    check("GeoJSON features parse with their SSURGO attributes",
          features.count == 1 && features[0].unit.mukey == "123" && features[0].unit.soilClass == .wellDrainedSandyLoam)
}

@MainActor
func checkSoilDataAccessParsing() async {
    print("\n--- D4. Soil Data Access ---")
    let fixture = """
    {"Table":[["mukey","muname","drclassdcd","hydclprs","wkt"],
    ["198881","Darwin silty clay, 0 to 2 percent slopes, occasionally flooded, long duration","Poorly drained","90","POLYGON ((-90.0575 38.6585, -90.0601 38.6586, -90.0607 38.6601, -90.0575 38.6585))"],
    ["198883","Dupo silt loam, 0 to 2 percent slopes, occasionally flooded","Somewhat poorly drained","10","POLYGON ((-90.0471 38.6698, -90.0483 38.6702, -90.0489 38.6712, -90.0471 38.6698))"]]}
    """
    let survey = SoilDataAccessClient.parse(Data(fixture.utf8))
    check("SDA rows parse into classified polygons",
          survey?.polygons.map(\.unit.soilClass) == [.hydricClay, .other], "\(String(describing: survey?.polygons.map(\.unit.soilClass)))")
    check("string-typed hydric percentages are read", survey?.polygons.first?.unit.hydricPercent == 90)
    check("an empty SDA result is an empty survey, not a failure", SoilDataAccessClient.parse(Data("{}".utf8))?.polygons.isEmpty == true)
    let cell = SoilDataAccessClient.queryCell(for: GeoRegion(minLatitude: 38.659, maxLatitude: 38.662, minLongitude: -90.064, maxLongitude: -90.060))
    let query = SoilDataAccessClient.query(for: cell)
    check("queries use the indexed intersection helper", query.contains("SDA_Get_Mupolygonkey_from_intersection_with_WktWgs84"))
    check("queries snap to a 0.01 degree cell", abs(cell.minLatitude - 38.65) < 1e-9 && abs(cell.maxLongitude + 90.06) < 1e-9, "\(cell)")

    // Same contract as GeoRegion.cacheKey: Int(_:) traps on NaN and infinity, so a cell with
    // a non-finite bound has to get "invalid_cell" rather than take the process down. NaN goes
    // in the first argument because GeoRegion.init drops a NaN second argument (see the
    // GeoRegion.cacheKey checks in main.swift); each infinity makes exactly one bound non-finite.
    // The finite cell's key is its cached file's name on disk, so it must not change.
    let nonFiniteCells: [(name: String, cell: GeoRegion)] = [
        ("NaN latitude", GeoRegion(minLatitude: .nan, maxLatitude: 38.67,
                                   minLongitude: -90.07, maxLongitude: -90.06)),
        ("NaN longitude", GeoRegion(minLatitude: 38.65, maxLatitude: 38.67,
                                    minLongitude: .nan, maxLongitude: -90.06)),
        ("minLatitude -inf", GeoRegion(minLatitude: -.infinity, maxLatitude: 38.67,
                                       minLongitude: -90.07, maxLongitude: -90.06)),
        ("maxLatitude +inf", GeoRegion(minLatitude: 38.65, maxLatitude: .infinity,
                                       minLongitude: -90.07, maxLongitude: -90.06)),
        ("minLongitude -inf", GeoRegion(minLatitude: 38.65, maxLatitude: 38.67,
                                        minLongitude: -.infinity, maxLongitude: -90.06)),
        ("maxLongitude +inf", GeoRegion(minLatitude: 38.65, maxLatitude: 38.67,
                                        minLongitude: -90.07, maxLongitude: .infinity)),
    ]
    let notRefused = nonFiniteCells.filter { SoilDataAccessClient.cacheKey($0.cell) != "invalid_cell" }.map { $0.name }
    let finiteKey = SoilDataAccessClient.cacheKey(cell)
    check("cacheKey returns invalid_cell for a NaN or infinite bound and keeps a finite cell's key",
          notRefused.isEmpty && finiteKey == "ssurgo_3865_-9007_3867_-9006",
          "not refused: \(notRefused); finite key: \(finiteKey)")

    let directory = harnessTemporaryDirectory.appendingPathComponent("ssurgo-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? Data(fixture.utf8).write(to: directory.appendingPathComponent(SoilDataAccessClient.cacheKey(cell) + ".json"))
    let offline = SoilDataAccessClient(transport: HTTPTransport(session: URLSession(configuration: .ephemeral)), directory: directory,
                                       endpoint: URL(string: "https://invalid.invalid/post.rest")!)
    let cached = await offline.survey(covering: GeoRegion(minLatitude: 38.659, maxLatitude: 38.662, minLongitude: -90.064, maxLongitude: -90.060))
    check("a cached cell is served from disk without the network", cached?.polygons.count == 2)

    // survey(covering:) has to turn a non-finite region away before load(), which reads the disk
    // cache and, on a miss, posts an SDA query built from the non-finite cell and stores the reply
    // under the one shared invalid-cell key. Without the early return that request to
    // invalid.invalid would only fail and give nil as well, so a survey seeded at the invalid-cell
    // key is what lets this check fail: it is what a fall-through to load() serves.
    try? Data(fixture.utf8).write(to: directory.appendingPathComponent("invalid_cell.json"))
    let nonFiniteRegions: [(name: String, region: GeoRegion)] = [
        ("NaN latitude", GeoRegion(minLatitude: .nan, maxLatitude: 38.662,
                                   minLongitude: -90.064, maxLongitude: -90.060)),
        ("infinite latitude", GeoRegion(minLatitude: 38.659, maxLatitude: .infinity,
                                        minLongitude: -90.064, maxLongitude: -90.060)),
    ]
    var served: [String] = []
    for (name, region) in nonFiniteRegions {
        if await offline.survey(covering: region) != nil { served.append(name) }
    }
    check("survey(covering:) returns nil for a non-finite region instead of serving the invalid-cell key",
          served.isEmpty, "served a survey for: \(served)")
    try? FileManager.default.removeItem(at: directory)
}

@MainActor
func checkSoilOverlay() {
    print("\n--- D5. Hatched soil overlay ---")
    let ring = [
        SIMD2<Double>(-90.06, 38.65),
        SIMD2<Double>(-90.05, 38.65),
        SIMD2<Double>(-90.05, 38.66),
        SIMD2<Double>(-90.06, 38.66),
        SIMD2<Double>(-90.06, 38.65)
    ]
    guard let clay = SoilPolygon(unit: SoilMapUnit(mukey: "1", name: "Sharkey clay", drainageClass: "Poorly drained", hydricPercent: 95), parts: [[ring]]),
          let loam = SoilPolygon(unit: SoilMapUnit(mukey: "2", name: "Bosket sandy loam", drainageClass: "Well drained", hydricPercent: 5), parts: [[ring]]),
          let other = SoilPolygon(unit: SoilMapUnit(mukey: "3", name: "Silt loam", drainageClass: "Somewhat poorly drained", hydricPercent: 10), parts: [[ring]])
    else {
        check("Soil polygons instantiate", false)
        return
    }
    let survey = SoilSurvey(polygons: [clay, loam, other])
    let overlays = SoilOverlayFactory.overlays(from: survey)
    check("SoilOverlayFactory groups by class and omits other", overlays.count == 2)
    check("SoilOverlayFactory produces hydric clay overlay", overlays.contains { $0.soilClass == .hydricClay })
    check("SoilOverlayFactory produces sandy loam overlay", overlays.contains { $0.soilClass == .wellDrainedSandyLoam })
}

/// Two SDA map units, as D4 parses them.
private let soilFixture = """
{"Table":[["mukey","muname","drclassdcd","hydclprs","wkt"],
["198881","Darwin silty clay, 0 to 2 percent slopes, occasionally flooded, long duration","Poorly drained","90","POLYGON ((-90.0575 38.6585, -90.0601 38.6586, -90.0607 38.6601, -90.0575 38.6585))"],
["198883","Dupo silt loam, 0 to 2 percent slopes, occasionally flooded","Somewhat poorly drained","10","POLYGON ((-90.0471 38.6698, -90.0483 38.6702, -90.0489 38.6712, -90.0471 38.6698))"]]}
"""

/// The same two units as GeoJSON, as a user might import them.
private let soilGeoJSONFixture = """
{"type":"FeatureCollection","features":[
{"type":"Feature","properties":{"mukey":"198881","muname":"Darwin silty clay","drclassdcd":"Poorly drained","hydclprs":"90"},
 "geometry":{"type":"Polygon","coordinates":[[[-90.0575,38.6585],[-90.0601,38.6586],[-90.0607,38.6601],[-90.0575,38.6585]]]}},
{"type":"Feature","properties":{"mukey":"198883","muname":"Dupo silt loam","drclassdcd":"Somewhat poorly drained","hydclprs":"10"},
 "geometry":{"type":"Polygon","coordinates":[[[-90.0471,38.6698],[-90.0483,38.6702],[-90.0489,38.6712],[-90.0471,38.6698]]]}}]}
"""

@MainActor
private func settle(seconds: Double, until done: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
}

/// The model's soils: a fetch left behind by the map must not answer after the one the map settled on, an
/// imported survey is shown wherever the map goes until soils are switched off, and a file that is no soil
/// GeoJSON (or no map image) says so instead of nothing.
@MainActor
func checkSoilsInTheModel() async {
    print("\n--- D6. soils in the model ---")
    let directory = harnessTemporaryDirectory.appendingPathComponent("ssurgo-model-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let scene = makeSyntheticScene(moundOffsetFromSeamMeters: nil)
    defer { try? FileManager.default.removeItem(at: scene.directory) }
    let model = TerrainViewerModel(terrainProvider: scene.provider)

    // --- A fetch for the view the map left must not replace the one it settled on.
    // Cell B is cached on disk, answered at once; cell A is not, and the network answers it with a failure after the
    // transport's retries and backoff, later.
    let regionA = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 38.745, longitude: -90.145),
                                     span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.004))
    let regionB = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 38.6605, longitude: -90.062),
                                     span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.004))
    let cellB = SoilDataAccessClient.queryCell(for: GeoRegion(center: regionB.center, latitudeSpan: regionB.span.latitudeDelta, longitudeSpan: regionB.span.longitudeDelta))
    try? Data(soilFixture.utf8).write(to: directory.appendingPathComponent(SoilDataAccessClient.cacheKey(cellB) + ".json"))
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FailureURLProtocol.self]
    FailureURLProtocol.responseGenerator = { (nil, nil, URLError(.timedOut)) }
    let client = SoilDataAccessClient(transport: HTTPTransport(session: URLSession(configuration: config)), directory: directory,
                                      endpoint: URL(string: "https://sda.test/post.rest")!)
    model.soilClient = client
    model.visibleRegion = regionA
    model.showsSoils = true
    model.visibleRegion = regionB
    model.loadSoils()
    await settle(seconds: 1) { model.soilSurvey != nil }
    let landed = model.soilSurvey?.polygons.count
    // Long enough for the fetch of A to fail through its retries.
    try? await Task.sleep(for: .seconds(2.5))
    check("the soils of the view the map settled on stay once the fetch for the view it left comes back empty",
          landed == 2 && model.soilSurvey?.polygons.count == 2, "landed \(String(describing: landed)), now \(String(describing: model.soilSurvey?.polygons.count))")
    let versionBefore = model.soilVersion
    model.showsSoils = false
    check("switching soils off clears them", model.soilSurvey == nil && model.soilVersion == versionBefore + 1)

    // --- Imports: refused with a reason, kept wherever the map goes, cleared by the switch.
    let notGeoJSON = directory.appendingPathComponent("notes.json")
    try? Data("{\"hello\": 1}".utf8).write(to: notGeoJSON)
    model.importSoilGeoJSON(from: notGeoJSON)
    check("a file that is no soil GeoJSON is refused with a reason and shows nothing",
          model.soilImportMessage?.contains("not a soil GeoJSON") == true && model.soilSurvey == nil && !model.showsSoils,
          "\(String(describing: model.soilImportMessage))")
    let missing = directory.appendingPathComponent("missing.geojson")
    model.importSoilGeoJSON(from: missing)
    check("a file that cannot be opened says so", model.soilImportMessage?.contains("could not be opened") == true,
          "\(String(describing: model.soilImportMessage))")
    let geoJSON = directory.appendingPathComponent("soils.geojson")
    try? Data(soilGeoJSONFixture.utf8).write(to: geoJSON)
    model.importSoilGeoJSON(from: geoJSON)
    let imported = model.soilSurvey?.polygons.count == 2 && model.importedSoilSurvey != nil && model.showsSoils && model.soilImportMessage == nil
    // The map moves on to cell B, which the client would answer from disk: the imported survey stays.
    model.visibleRegion = regionB
    let importedVersion = model.soilVersion
    model.loadSoils()
    try? await Task.sleep(for: .milliseconds(300))
    check("an imported soil GeoJSON is shown, and stays as the map moves instead of giving way to a fetch",
          imported && model.soilVersion == importedVersion && model.importedSoilSurvey != nil
            && model.soilSurvey?.polygons.first?.unit.mukey == "198881",
          "imported \(imported), version \(importedVersion) -> \(model.soilVersion), \(String(describing: model.soilSurvey?.polygons.count))")
    model.showsSoils = false
    check("switching soils off lets the imported survey go, so the next switch on fetches again",
          model.importedSoilSurvey == nil && model.soilSurvey == nil)

    // --- Historical maps: no image among the files, or a file that is no image, say so.
    model.importHistoricalMaps(from: [notGeoJSON])
    check("a historical map import with no image among the files says so at once",
          model.historicalMapImportMessage?.contains("No map image") == true, "\(String(describing: model.historicalMapImportMessage))")
    let fakeImage = directory.appendingPathComponent("scan.png")
    try? Data("not a png".utf8).write(to: fakeImage)
    model.importHistoricalMaps(from: [fakeImage])
    await settle(seconds: 5) { model.historicalMapImportMessage != nil }
    check("a file named as an image that cannot be read as one is named in the message, and nothing is added",
          model.historicalMapImportMessage?.contains("scan.png could not be read") == true && model.historicalMaps.isEmpty,
          "\(String(describing: model.historicalMapImportMessage))")
}

@MainActor
func runHistoricalAndSoilChecks() async {
    print("\n=== Historical maps & SSURGO soils ===")
    checkWorldFiles()
    checkEmbeddedGeoTIFFWorldFile()
    checkSoilModel()
    await checkSoilDataAccessParsing()
    checkSoilOverlay()
    await checkSoilsInTheModel()
}



