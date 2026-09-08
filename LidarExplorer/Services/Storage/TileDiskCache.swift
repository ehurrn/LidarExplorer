//
//  TileDiskCache.swift
//  LidarExplorer
//
//  Persistent on-disk cache for rendered terrain tiles with LRU eviction.
//

import Foundation

public actor TileDiskCache {
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let maxDiskBytes: Int64 = 500 * 1024 * 1024 // 500 MB max footprint
    private let targetDiskBytes: Int64 = 400 * 1024 * 1024 // Prune down to 400 MB

    public init() {
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        self.cacheDirectory = base.appendingPathComponent("TerrainTiles", isDirectory: true)
        try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private func fileURL(forKey key: String) -> URL {
        let safeKey = key
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return cacheDirectory.appendingPathComponent("\(safeKey).cache")
    }

    public func read(forKey key: String) -> Data? {
        let url = fileURL(forKey: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        // Update modification date for LRU ordering
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return try? Data(contentsOf: url)
    }

    public func write(_ data: Data, forKey key: String) {
        let url = fileURL(forKey: key)
        do {
            try data.write(to: url, options: .atomic)
            pruneIfNeeded()
        } catch {
            // Best-effort write
        }
    }

    public func totalDiskUsage() -> Int64 {
        guard let files = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for file in files {
            if let attrs = try? file.resourceValues(forKeys: [.fileSizeKey]),
               let size = attrs.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    public func clear() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }

    private func pruneIfNeeded() {
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        struct CachedFileInfo {
            let url: URL
            let size: Int64
            let modDate: Date
        }

        var entries: [CachedFileInfo] = []
        var totalUsage: Int64 = 0

        for url in fileURLs {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
               let size = values.fileSize {
                let s = Int64(size)
                let d = values.contentModificationDate ?? Date.distantPast
                entries.append(CachedFileInfo(url: url, size: s, modDate: d))
                totalUsage += s
            }
        }

        guard totalUsage > maxDiskBytes else { return }

        // Evict oldest files first
        entries.sort { $0.modDate < $1.modDate }

        for entry in entries {
            guard totalUsage > targetDiskBytes else { break }
            try? fileManager.removeItem(at: entry.url)
            totalUsage -= entry.size
        }
    }
}
