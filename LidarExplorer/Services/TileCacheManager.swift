//
//  TileCacheManager.swift
//  LidarExplorer
//
//  Created by Eric Herren on 1/10/26.
//

import Foundation
import Combine
import OSLog

// By converting this to a global actor, we gain several benefits:
// 1. Automatic thread safety: The actor serializes access to its properties.
// 2. Clearer concurrency: All interactions with the cache must now use `await`.
actor TileCacheManager {
    static let shared = TileCacheManager()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LidarExplorer", category: "TileCacheManager")

    // We manage this value within the actor and publish changes manually.
    private(set) var maxCacheSizeGB: Double {
        didSet {
            UserDefaults.standard.set(maxCacheSizeGB, forKey: "maxCacheSizeGB")
            // Manually send the updated value to any observers.
            settingsChangedSubject.send()
        }
    }
    
    // Combine publisher for SwiftUI views to observe changes.
    let settingsChangedSubject = PassthroughSubject<Void, Never>()
    
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let memoryCache = NSCache<NSString, NSData>()
    
    // --- Phase 1: Disk Batching & Optimization Properties ---
    private var pendingWrites: [String: Data] = [:]
    private var writeTask: Task<Void, Never>?
    
    // Counter to trigger pruning less frequently.
    private var saveCounter = 0
    private let pruneFrequency = 50 // Prune check every 50 *batch* saves.
    
    private init() {
        let urls = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        let targetDir = urls[0].appendingPathComponent("LidarTiles")
        
        let savedSize = UserDefaults.standard.double(forKey: "maxCacheSizeGB")
        let targetSize = (savedSize == 0) ? 2.0 : savedSize
        
        self.cacheDirectory = targetDir
        self.maxCacheSizeGB = targetSize
        
        // --- Phase 1 Updates: Explicit Memory Limits ---
        // 1. Limit by Count: Prevent holding too many small objects.
        self.memoryCache.countLimit = 100
        // 2. Limit by Cost: Reduced to 50 MB (safe buffer for standard iPhones).
        self.memoryCache.totalCostLimit = 50 * 1024 * 1024
        
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    // MARK: - Public API
    
    func getCachedTile(key: String) -> Data? {
        // 1. Check RAM first (L1 Cache).
        if let cachedData = memoryCache.object(forKey: key as NSString) {
            return cachedData as Data
        }
        
        // 1.5 Check Pending Writes (L1.5 Cache)
        // If the data is waiting to be written to disk, it's still "in memory" here.
        if let pendingData = pendingWrites[key] {
            return pendingData
        }
        
        // 2. Fallback to Disk (L2 Cache).
        let fileURL = cacheDirectory.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        // If found on disk, populate RAM for subsequent requests.
        memoryCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        
        return data
    }
    
    func saveTile(key: String, data: Data) {
        // 1. Save to RAM immediately.
        memoryCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        
        // 2. Queue for disk write (Batching).
        // This stores the data in a temporary dictionary instead of writing immediately.
        pendingWrites[key] = data
        
        // 3. Debounce the write operation.
        // We cancel the previous timer and start a new one.
        // The disk write will only happen 2 seconds after the *last* save request.
        writeTask?.cancel()
        writeTask = Task {
            try? await Task.sleep(nanoseconds: 2 * 1_000_000_000) // 2 seconds
            self.flushPendingWrites()
        }
    }
    
    func clearCache() {
        // Cancel any pending writes so we don't re-write data we just deleted.
        writeTask?.cancel()
        pendingWrites.removeAll()
        memoryCache.removeAllObjects()
        
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    func getCurrentUsage() -> String {
        guard let size = calculateDirectorySize() else { return "0 MB" }
        let mb = Double(size) / 1024 / 1024
        if mb > 1024 {
            return String(format: "%.2f GB", mb / 1024)
        } else {
            return String(format: "%.0f MB", mb)
        }
    }
    
    // This nonisolated method allows synchronous calls from the main thread (SwiftUI).
    nonisolated func updateMaxCacheSize(to newSize: Double) {
        Task {
            await self.setMaxCacheSize(to: newSize)
        }
    }
    
    private func setMaxCacheSize(to newSize: Double) {
        self.maxCacheSizeGB = newSize
        // After changing the limit, immediately trigger a pruning check.
        Task {
            self.pruneCache()
        }
    }
    
    // MARK: - Internal Batch Processing
    
    private func flushPendingWrites() {
        guard !pendingWrites.isEmpty else { return }
        
        let writesToPerform = pendingWrites
        pendingWrites.removeAll()
        
        // Perform file I/O
        for (key, data) in writesToPerform {
            let fileURL = cacheDirectory.appendingPathComponent(key)
            do {
                try data.write(to: fileURL)
            } catch {
                logger.error("Error writing tile \(key): \(error.localizedDescription)")
            }
        }
        
        // Trigger maintenance check *after* the batch write completes.
        saveCounter += 1
        if saveCounter >= pruneFrequency {
            saveCounter = 0
            Task {
                self.pruneCache()
            }
        }
    }
    
    // MARK: - Cache Maintenance
    
    func pruneCache() {
        let limitBytes = Int64(maxCacheSizeGB * 1024 * 1024 * 1024)
        // Target 90% of the limit to provide a buffer.
        let targetBytes = Int64(Double(limitBytes) * 0.9)

        let resourceKeys: [URLResourceKey] = [.totalFileSizeKey, .contentModificationDateKey]
        guard let directoryEnumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: resourceKeys,
            options: .skipsHiddenFiles
        ) else { return }

        var files = (directoryEnumerator.allObjects).compactMap { item -> (url: URL, size: Int64, date: Date)? in
            guard let url = item as? URL,
                  let resources = try? url.resourceValues(forKeys: Set(resourceKeys)),
                  let fileSize = resources.totalFileSize,
                  let modDate = resources.contentModificationDate else {
                return nil
            }
            return (url, Int64(fileSize), modDate)
        }
        
        var currentSize = files.reduce(0) { $0 + $1.size }
        if currentSize <= limitBytes { return }
        
        // LRU Strategy: Sort by date (oldest first)
        files.sort { $0.date < $1.date }

        for file in files {
            if currentSize <= targetBytes { break }
            if (try? fileManager.removeItem(at: file.url)) != nil {
                currentSize -= file.size
            }
        }
    }
    
    private func calculateDirectorySize() -> Int64? {
        let resourceKeys: [URLResourceKey] = [.fileSizeKey]
        guard let files = try? fileManager.contentsOfDirectory(at: self.cacheDirectory, includingPropertiesForKeys: resourceKeys) else { return nil }
        
        return files.reduce(Int64(0)) { size, url in
            let fileSize = try? url.resourceValues(forKeys: Set(resourceKeys)).fileSize
            return size + Int64(fileSize ?? 0)
        }
    }
}
