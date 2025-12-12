//
//  TileCacheManager.swift
//  LidarExplorer
//
//  Created by Eric Herren on 12/12/25.
//


import Foundation
import Combine // Required for @Published and ObservableObject

class TileCacheManager: ObservableObject {
    static let shared = TileCacheManager()
    
    // Configurable Settings
    // We update UserDefaults whenever this value changes
    @Published var maxCacheSizeGB: Double {
        didSet {
            UserDefaults.standard.set(maxCacheSizeGB, forKey: "maxCacheSizeGB")
        }
    }
    
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    
    init() {
        // 1. Setup the Cache Directory Path (Calculate locally first)
        let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let targetDir = urls[0].appendingPathComponent("LidarTiles")
        
        // 2. Load the Cache Size Preference (Calculate locally first)
        let savedSize = UserDefaults.standard.double(forKey: "maxCacheSizeGB")
        let targetSize = (savedSize == 0) ? 2.0 : savedSize // Default to 2GB if not set
        
        // 3. Assign properties (Now 'self' is fully initialized)
        self.cacheDirectory = targetDir
        self.maxCacheSizeGB = targetSize
        
        // 4. Create the folder on disk if it doesn't exist
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    // --- Public API ---
    
    func getCachedTile(key: String) -> Data? {
        let fileURL = cacheDirectory.appendingPathComponent(key)
        return try? Data(contentsOf: fileURL)
    }
    
    func saveTile(key: String, data: Data) {
        let fileURL = cacheDirectory.appendingPathComponent(key)
        do {
            try data.write(to: fileURL)
        } catch {
            print("Failed to save tile: \(error.localizedDescription)")
        }
    }
    
    func clearCache() {
        // Delete the folder and recreate it empty
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    func getCurrentUsage() -> String {
        guard let size = directorySize() else { return "0 MB" }
        let mb = Double(size) / 1024 / 1024
        if mb > 1024 {
            return String(format: "%.2f GB", mb / 1024)
        } else {
            return String(format: "%.0f MB", mb)
        }
    }
    
    // --- Maintenance ---
    
    // Checks if we are over the limit. If so, wipes the cache.
    // (A production app might delete only the oldest files, but this is safer for now)
    func enforceLimit() {
        guard let currentSize = directorySize() else { return }
        let limitBytes = Int64(maxCacheSizeGB * 1024 * 1024 * 1024)
        
        if currentSize > limitBytes {
            print("Cache limit reached (\(getCurrentUsage())). Purging...")
            clearCache()
        }
    }
    
    // Helper to calculate total folder size
    private func directorySize() -> Int64? {
        guard let files = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        var size: Int64 = 0
        for file in files {
            size += (try? (file.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0)) ?? 0
        }
        return size
    }
}