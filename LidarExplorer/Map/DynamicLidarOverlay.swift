//
//  DynamicLidarOverlay.swift
//  LidarExplorer
//
//  Created by Eric Herren on 1/10/26.
//

import MapKit

// 1. DATA SOURCE CONFIGURATION
enum LidarSource: String, CaseIterable, Identifiable {
    case usgsHillshade = "Hillshade Gray"
    case usgsMultidirectional = "Hillshade Multidirectional"
    case usgsTinted = "Hillshade Elevation Tinted"
    case usgsSlope = "Slope Map"
    case usgsAspect = "Aspect Map"
    case usgsContour = "Contour 25"
    
    var id: String { self.rawValue }
    
    var displayName: String {
        switch self {
        case .usgsHillshade: return "Standard Hillshade"
        case .usgsMultidirectional: return "Multi-Directional (Best)"
        case .usgsTinted: return "Elevation Tinted"
        case .usgsSlope: return "Slope Map"
        case .usgsAspect: return "Aspect Map"
        case .usgsContour: return "Contours (25ft)"
        }
    }
    
    var urlTemplate: String {
        return "https://elevation.nationalmap.gov/arcgis/rest/services/3DEPElevation/ImageServer/exportImage"
    }
    
    var params: [String: String] {
        return ["renderingRule": "{\"rasterFunction\":\"\(self.rawValue)\"}"]
    }
}

class DynamicLidarOverlay: MKTileOverlay {
    
    // Default to Multi-Directional
    var currentSource: LidarSource = .usgsMultidirectional
    
    // CUSTOM SESSION: "Polite" Configuration
    // 1. Increases concurrency slightly
    // 2. Fails fast (6s) so we can retry quickly
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 6
        config.httpAdditionalHeaders = ["User-Agent": "LidarExplorer/1.0 (com.example.lidarexplorer)"]
        return URLSession(configuration: config)
    }()
    
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        
        // UNIQUE KEY: Includes source name to prevent caching wrong layer
        let tileKey = "\(currentSource.id)-\(path.z)-\(path.x)-\(path.y).png"
        
        // 1. FAST PATH: Check Disk
        if let cachedData = TileCacheManager.shared.getCachedTile(key: tileKey) {
            result(cachedData, nil)
            return
        }
        
        // 2. NETWORK PATH: Construct URL
        guard let url = constructURL(for: path) else {
            result(nil, nil)
            return
        }
        
        // 3. SMART RETRY FETCH
        fetchTile(url: url, attempts: 3) { [weak self] data, error in
            guard let self = self else { return }
            
            if let data = data {
                // Save to disk on background thread
                DispatchQueue.global(qos: .background).async {
                    TileCacheManager.shared.saveTile(key: tileKey, data: data)
                }
                result(data, nil)
            } else {
                result(nil, error)
            }
        }
    }
    
    private func fetchTile(url: URL, attempts: Int, completion: @escaping (Data?, Error?) -> Void) {
        let task = session.dataTask(with: url) { [weak self] data, response, error in
            
            if let data = data, let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                completion(data, nil)
                return
            }
            
            // Retry logic: Don't retry 404s
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let is404 = (statusCode == 404)
            
            if attempts > 1 && !is404 {
                // Short backoff delay
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    self?.fetchTile(url: url, attempts: attempts - 1, completion: completion)
                }
            } else {
                print("Failed: \(url.absoluteString) (Status: \(statusCode))")
                completion(nil, error)
            }
        }
        task.resume()
    }
    
    private func constructURL(for path: MKTileOverlayPath) -> URL? {
        let bbox = tilePathToBBox(x: path.x, y: path.y, z: path.z)
        
        var components = URLComponents(string: currentSource.urlTemplate)!
        var queryItems = [URLQueryItem]()
        
        for (key, value) in currentSource.params {
            queryItems.append(URLQueryItem(name: key, value: value))
        }
        
        queryItems.append(URLQueryItem(name: "bbox", value: bbox))
        
        // OPTIMIZATION: Request 1024x1024 pixels.
        // Since we are setting tile size to 512pt (in MapView), we need 1024px for Retina quality.
        // This reduces HTTP request count by 4x.
        queryItems.append(URLQueryItem(name: "size", value: "1024,1024"))
        
        queryItems.append(URLQueryItem(name: "bboxSR", value: "3857"))
        queryItems.append(URLQueryItem(name: "imageSR", value: "3857"))
        
        // FIX: png32 enables transparency (removes cyan artifacts)
        queryItems.append(URLQueryItem(name: "format", value: "png32"))
        queryItems.append(URLQueryItem(name: "f", value: "image"))
        
        components.queryItems = queryItems
        return components.url
    }
    
    private func tilePathToBBox(x: Int, y: Int, z: Int) -> String {
        let max = 20037508.34
        let res = (max * 2) / pow(2.0, Double(z))
        let minX = (Double(x) * res) - max
        let maxY = max - (Double(y) * res)
        let maxX = minX + res
        let minY = maxY - res
        return String(format: "%.4f,%.4f,%.4f,%.4f", minX, minY, maxX, maxY)
    }
}
