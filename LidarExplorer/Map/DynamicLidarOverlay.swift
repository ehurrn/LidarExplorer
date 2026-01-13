//
//  DynamicLidarOverlay.swift
//  LidarExplorer
//
//  Created by Eric Herren on 1/10/26.
//

import MapKit
import Foundation

// MKTileOverlayPath needs to be Hashable to be used as a Dictionary key.
extension MKTileOverlayPath: @retroactive Equatable {}
extension MKTileOverlayPath: @retroactive Hashable {
    public static func == (lhs: MKTileOverlayPath, rhs: MKTileOverlayPath) -> Bool {
        return lhs.x == rhs.x &&
        lhs.y == rhs.y &&
        lhs.z == rhs.z &&
        lhs.contentScaleFactor == rhs.contentScaleFactor
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
        hasher.combine(z)
        hasher.combine(contentScaleFactor)
    }
}

// Swift 6 FIX: Using an Int raw value gives us a synthesized, nonisolated Equatable conformance.
enum LidarSourceType: Int, Sendable {
    case staticTiles // Pre-rendered, fast, cached by USGS
    case dynamic     // Computed on-the-fly, slow, rate-limited
}

enum LidarSource: String, CaseIterable, Identifiable, Sendable {
    // We removed the heavy analytical layers (Slope, Aspect, Tinted) to prevent rate limiting.
    case usgsHillshade = "Hillshade Gray"
    case usgsMultidirectional = "Hillshade Multidirectional"
    
    var id: String { self.rawValue }
    
    // Explicitly nonisolated allows background thread access
    nonisolated var type: LidarSourceType {
        switch self {
        case .usgsHillshade:
            return .staticTiles
        case .usgsMultidirectional:
            return .dynamic
        }
    }
    
    var displayName: String {
        switch self {
        case .usgsHillshade: return "Standard Hillshade (Fast)"
        case .usgsMultidirectional: return "Multi-Directional (Best)"
        }
    }
    
    // CANNY FIX: Explicitly nonisolated so constructURL can read it from a background thread
    nonisolated static let staticTileTemplate = "https://basemap.nationalmap.gov/arcgis/rest/services/USGSShadedReliefOnly/MapServer/tile/{z}/{y}/{x}"
    
    // CANNY FIX: Explicitly nonisolated for background access
    nonisolated static let dynamicUrlTemplate: String = "https://elevation.nationalmap.gov/arcgis/rest/services/3DEPElevation/ImageServer/exportImage"
    
    // CANNY FIX: Explicitly nonisolated for background access
    nonisolated var params: [String: String] {
        return ["renderingRule": "{\"rasterFunction\":\"\(self.rawValue)\"}"]
    }
}

class DynamicLidarOverlay: MKTileOverlay {
    
    // This actor manages the dictionary of loading tasks to ensure thread safety
    private actor TaskManager {
        var loadingTasks = [MKTileOverlayPath: Task<Void, Never>]()
        
        func add(_ task: Task<Void, Never>, for path: MKTileOverlayPath) {
            loadingTasks[path] = task
        }
        
        func remove(for path: MKTileOverlayPath) {
            loadingTasks.removeValue(forKey: path)
        }
        
        func cancelAll() {
            let tasksToCancel = Array(loadingTasks.values)
            loadingTasks.removeAll()
            for task in tasksToCancel {
                task.cancel()
            }
        }
    }
    
    private let taskManager = TaskManager()
    private let sourceLock = NSLock()
    private var _currentSource: LidarSource
    
    var currentSource: LidarSource {
        get {
            sourceLock.lock()
            defer { sourceLock.unlock() }
            return _currentSource
        }
        set {
            sourceLock.lock()
            guard _currentSource != newValue else {
                sourceLock.unlock()
                return
            }
            _currentSource = newValue
            sourceLock.unlock()
            
            // Asynchronously cancel all tasks for the old source
            Task {
                await taskManager.cancelAll()
            }
        }
    }
    
    init(source: LidarSource) {
        self._currentSource = source
        // Initialize with the dynamic template as a fallback, but constructURL overrides this
        super.init(urlTemplate: LidarSource.dynamicUrlTemplate)
    }
    
    deinit {
        let manager = taskManager
        Task {
            await manager.cancelAll()
        }
    }
    
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": "LidarExplorer/1.0 (com.example.lidarexplorer)"]
        return URLSession(configuration: config)
    }()
    
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
            let sourceForTile = self.currentSource
            
            // FIX: Added '[weak self] in' so we can safely unwrap it below
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self else { return }
                
                do {
                    let data = try await self.getTileData(for: path, using: sourceForTile)
                    try Task.checkCancellation()
                    result(data, nil)
                    
                    // Hybrid Logic: Only prefetch for static tiles in the static range
                    if sourceForTile.type == .staticTiles && path.z <= 14 {
                        await self.prefetchNeighbors(for: path, using: sourceForTile)
                    }
                } catch {
                                if error is CancellationError {
                                    result(nil, nil)
                                } else {
                                    // DEBUG: Print error to the Xcode Console
                                    print("🔴 TILE FAILURE [z\(path.z) x\(path.x) y\(path.y)]: \(error.localizedDescription)")
                                    
                                    // Detailed error info (uncomment if needed):
                                    // print(error)
                                    
                                    result(nil, error)
                                }
                            }
                // Actor call requires await
                await self.taskManager.remove(for: path)
            }
            
            Task {
                await taskManager.add(task, for: path)
            }
        }
    
    private func getTileData(for path: MKTileOverlayPath, using source: LidarSource) async throws -> Data {
        let tileKey = "\(source.rawValue)-\(path.z)-\(path.x)-\(path.y).png"

        // 1. Check L1/L2 Cache
        if let cachedData = await TileCacheManager.shared.getCachedTile(key: tileKey) {
            return cachedData
        }

        // 2. Fetch from Network
        guard let url = constructURL(for: path, using: source) else {
            throw URLError(.badURL)
        }

        let data = try await fetchTileWithRetries(url: url)

        // Save to the cache actor
        await TileCacheManager.shared.saveTile(key: tileKey, data: data)

        return data
    }
    
    private func fetchTileWithRetries(url: URL, attempts: Int = 3) async throws -> Data {
        var lastError: Error?
        for attempt in 1...attempts {
            try Task.checkCancellation()
            
            do {
                let (data, response) = try await session.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw URLError(.cannotParseResponse)
                }

                if httpResponse.statusCode == 200 {
                    return data
                }

                if httpResponse.statusCode == 404 {
                    throw URLError(.fileDoesNotExist)
                }
                
                lastError = URLError(.badServerResponse)

            } catch {
                if error is CancellationError { throw error }
                lastError = error
            }

            if attempt < attempts {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        throw lastError ?? URLError(.unknown)
    }
    
    private nonisolated func constructURL(for path: MKTileOverlayPath, using source: LidarSource) -> URL? {
        // HYBRID LOGIC:
                // If it's the standard hillshade AND we are within the static tile range (Z0-16),
                // use the fast pre-rendered tiles.
                if source.type == .staticTiles && path.z <= 14 {
                    // Standard XYZ pattern: z, y, x
                    return URL(string: LidarSource.staticTileTemplate
                        .replacingOccurrences(of: "{z}", with: "\(path.z)")
                        .replacingOccurrences(of: "{y}", with: "\(path.y)")
                        .replacingOccurrences(of: "{x}", with: "\(path.x)")
                    )
                }
                
        // 2. THE FALLBACK (Dynamic Generation):
                // If we are here, it means either:
                // A) We are using Multidirectional (which is always dynamic), OR
                // B) We are using Standard Hillshade but are at Z17+ (Deep Zoom).
                //
                // In both cases, we construct a dynamic request. Since 'usgsHillshade' has
                // the raw value "Hillshade Gray", this correctly tells the server to render
                // the standard gray style on-the-fly.
                
                let bbox = tilePathToBBox(x: path.x, y: path.y, z: path.z)
                
                guard var components = URLComponents(string: LidarSource.dynamicUrlTemplate) else {
                    return nil
                }
                
                var queryItems = [URLQueryItem]()
                
                // This applies the correct raster function ("Hillshade Gray" or "Hillshade Multidirectional")
                for (key, value) in source.params {
                    queryItems.append(URLQueryItem(name: key, value: value))
                }
                
                // Dynamic requests need explicit bbox and sizing
                queryItems.append(contentsOf: [
                    URLQueryItem(name: "bbox", value: bbox),
                    URLQueryItem(name: "size", value: "1024,1024"),
                    URLQueryItem(name: "bboxSR", value: "3857"),
                    URLQueryItem(name: "imageSR", value: "3857"),
                    URLQueryItem(name: "format", value: "png32"),
                    URLQueryItem(name: "f", value: "image")
                ])
                
                components.queryItems = queryItems
                return components.url
            }
    
    private nonisolated func tilePathToBBox(x: Int, y: Int, z: Int) -> String {
        let max = 20037508.34
        let res = (max * 2) / Double(1 << z)
        let minX = (Double(x) * res) - max
        let maxY = max - (Double(y) * res)
        let maxX = minX + res
        let minY = maxY - res
        return String(format: "%.4f,%.4f,%.4f,%.4f", minX, minY, maxX, maxY)
    }
    
    private func prefetchNeighbors(for path: MKTileOverlayPath, using source: LidarSource) async {
        let neighbors = [
            (path.x + 1, path.y), (path.x - 1, path.y),
            (path.x, path.y + 1), (path.x, path.y - 1)
        ]
        
        await withTaskGroup(of: Void.self) { group in
            for (x, y) in neighbors {
                group.addTask(priority: .background) {
                    var neighborPath = path
                    neighborPath.x = x
                    neighborPath.y = y
                    
                    guard neighborPath.x >= 0, neighborPath.y >= 0 else { return }
                    
                    let tileKey = "\(source.rawValue)-\(neighborPath.z)-\(neighborPath.x)-\(neighborPath.y).png"
                    
                    if await TileCacheManager.shared.getCachedTile(key: tileKey) == nil,
                       let url = self.constructURL(for: neighborPath, using: source) {
                        
                        // Prefetching is best-effort; no retries needed
                        if let (data, response) = try? await self.session.data(from: url),
                           (response as? HTTPURLResponse)?.statusCode == 200 {
                            await TileCacheManager.shared.saveTile(key: tileKey, data: data)
                        }
                    }
                }
            }
        }
    }
}
