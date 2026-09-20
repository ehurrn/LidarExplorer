//
//  SoilDataAccessClient.swift
//  LidarExplorer
//
//  USDA Soil Data Access (SSURGO) map-unit polygons for an area, cached on disk.
//

import Foundation
import os

public actor SoilDataAccessClient {

    public static let shared = SoilDataAccessClient()
    public nonisolated static let defaultEndpoint = URL(string: "https://sdmdataaccess.sc.egov.usda.gov/Tabular/post.rest")!
    private nonisolated static let cellDegrees = 0.01

    private let transport: HTTPTransport
    private let directory: URL
    private let endpoint: URL
    private var memory: [String: SoilSurvey] = [:]
    private var inFlight: [String: Task<SoilSurvey?, Never>] = [:]

    public init(transport: HTTPTransport? = nil, directory: URL? = nil, endpoint: URL = SoilDataAccessClient.defaultEndpoint) {
        let patient = URLSessionConfiguration.default
        patient.timeoutIntervalForRequest = 90
        patient.timeoutIntervalForResource = 120
        self.transport = transport ?? HTTPTransport(session: URLSession(configuration: patient))
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? caches.appendingPathComponent("SSURGO", isDirectory: true)
        self.endpoint = endpoint
    }

    /// Map-unit polygons intersecting `region`'s 0.01° cell: memory, then disk, then SDA.
    /// A region with a NaN or infinite bound gets `nil` without touching any of them.
    public func survey(covering region: GeoRegion) async -> SoilSurvey? {
        let cell = Self.queryCell(for: region)
        let key = Self.cacheKey(cell)
        guard key != "invalid_cell" else { return nil }
        if let cached = memory[key] { return cached }
        if let running = inFlight[key] { return await running.value }
        let task = Task { [transport, directory, endpoint] in
            await Self.load(cell: cell, key: key, transport: transport, directory: directory, endpoint: endpoint)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result { memory[key] = result }
        return result
    }

    nonisolated static func queryCell(for region: GeoRegion) -> GeoRegion {
        let s = cellDegrees
        return GeoRegion(
            minLatitude: (region.minLatitude / s).rounded(.down) * s, maxLatitude: (region.maxLatitude / s).rounded(.up) * s,
            minLongitude: (region.minLongitude / s).rounded(.down) * s, maxLongitude: (region.maxLongitude / s).rounded(.up) * s
        )
    }

    /// The cache key for `cell`, or `"invalid_cell"` when a bound is NaN or infinite (`Int(_:)` would trap).
    nonisolated static func cacheKey(_ cell: GeoRegion) -> String {
        guard cell.minLatitude.isFinite, cell.maxLatitude.isFinite,
              cell.minLongitude.isFinite, cell.maxLongitude.isFinite else {
            return "invalid_cell"
        }
        let parts = [cell.minLatitude, cell.minLongitude, cell.maxLatitude, cell.maxLongitude].map { Int(($0 * 100).rounded()) }
        return "ssurgo_" + parts.map(String.init).joined(separator: "_")
    }

    /// The indexed intersection helper keeps this sub-second; a direct geometry scan times out.
    nonisolated static func query(for cell: GeoRegion) -> String {
        let ring = [
            (cell.minLongitude, cell.minLatitude), (cell.maxLongitude, cell.minLatitude),
            (cell.maxLongitude, cell.maxLatitude), (cell.minLongitude, cell.maxLatitude), (cell.minLongitude, cell.minLatitude),
        ].map { "\($0.0) \($0.1)" }.joined(separator: ", ")
        return "SELECT P.mukey, M.muname, A.drclassdcd, A.hydclprs, P.mupolygongeo.STAsText() AS wkt "
            + "FROM mupolygon AS P INNER JOIN mapunit AS M ON M.mukey = P.mukey "
            + "LEFT OUTER JOIN muaggatt AS A ON A.mukey = P.mukey "
            + "WHERE P.mupolygonkey IN (SELECT * FROM SDA_Get_Mupolygonkey_from_intersection_with_WktWgs84('POLYGON((\(ring)))'))"
    }

    /// Parses `JSON+COLUMNNAME` (`{"Table": [[names], [values…]]}`, all values strings; `{}` when empty).
    nonisolated static func parse(_ data: Data) -> SoilSurvey? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let table = root["Table"] as? [[Any]], let header = table.first as? [String] else {
            return root.isEmpty ? SoilSurvey(polygons: []) : nil
        }
        guard let mukey = header.firstIndex(of: "mukey"), let muname = header.firstIndex(of: "muname"),
              let drainage = header.firstIndex(of: "drclassdcd"), let hydric = header.firstIndex(of: "hydclprs"),
              let wkt = header.firstIndex(of: "wkt")
        else { return nil }
        let polygons = table.dropFirst().compactMap { row -> SoilPolygon? in
            guard row.count == header.count, let text = row[wkt] as? String, let parts = WKTPolygonParser.polygons(text) else { return nil }
            let unit = SoilMapUnit(mukey: "\(row[mukey])", name: row[muname] as? String ?? "",
                                   drainageClass: row[drainage] as? String,
                                   hydricPercent: (row[hydric] as? String).flatMap { Int($0) })
            return SoilPolygon(unit: unit, parts: parts)
        }
        return SoilSurvey(polygons: polygons)
    }

    private nonisolated static func load(
        cell: GeoRegion, key: String, transport: HTTPTransport, directory: URL, endpoint: URL
    ) async -> SoilSurvey? {
        let file = directory.appendingPathComponent(key + ".json")
        if let data = try? Data(contentsOf: file), let survey = parse(data) { return survey }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query(for: cell), "format": "JSON+COLUMNNAME"])
        switch await transport.data(for: request) {
        case .failure(let error):
            Log.network.error("SDA query failed: \(error.description, privacy: .public)")
            return nil
        case .success(let data):
            guard let survey = parse(data) else { return nil }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return survey
        }
    }
}
