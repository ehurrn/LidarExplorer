//
//  DynamicLidarOverlay.swift
//  LidarExplorer
//
//  Created by Eric Herren on 12/12/25.
//


import MapKit

class DynamicLidarOverlay: MKTileOverlay {
    
    let baseUrl = "https://elevation.nationalmap.gov/arcgis/rest/services/3DEPElevation/ImageServer/exportImage"
    
    // Standard caching is opaque. We override loadTile to force our custom logic.
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        
        // 1. Generate a unique filename for this tile (e.g., "15-1200-3040.png")
        let tileKey = "\(path.z)-\(path.x)-\(path.y).png"
        
        // 2. CHECK DISK (Fast Path)
        if let cachedData = TileCacheManager.shared.getCachedTile(key: tileKey) {
            result(cachedData, nil)
            return
        }
        
        // 3. DOWNLOAD (Slow Path)
        // Reconstruct the URL using our math
        guard let url = constructURL(for: path) else { return }
        
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if let data = data {
                // Save to disk for next time
                TileCacheManager.shared.saveTile(key: tileKey, data: data)
                result(data, nil)
            } else {
                result(nil, error)
            }
        }
        task.resume()
    }
    
    // Moved the URL construction logic to a helper so we can call it manually
    private func constructURL(for path: MKTileOverlayPath) -> URL? {
        let bbox = tilePathToBBox(x: path.x, y: path.y, z: path.z)
        let rule = "{\"rasterFunction\":\"Hillshade Gray\"}"
        
        var components = URLComponents(string: baseUrl)!
        components.queryItems = [
            URLQueryItem(name: "bbox", value: bbox),
            URLQueryItem(name: "bboxSR", value: "3857"),
            URLQueryItem(name: "size", value: "512,512"),
            URLQueryItem(name: "imageSR", value: "3857"),
            URLQueryItem(name: "format", value: "png"),
            URLQueryItem(name: "f", value: "image"),
            URLQueryItem(name: "renderingRule", value: rule)
        ]
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