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
    private var approximateDiskBytes: Int64 = 0

    public init(directory: URL? = nil) {
        let fm = FileManager.default
        if let directory {
            self.cacheDirectory = directory
        } else {
            let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? fm.temporaryDirectory
            self.cacheDirectory = base.appendingPathComponent("TerrainTiles", isDirectory: true)
        }
        try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        self.approximateDiskBytes = Self.computeUsage(directory: cacheDirectory, fileManager: fm)
    }

    private func fileURL(forKey key: String) -> URL {
        // Sanitize to alphanumeric, dots, underscores, and hyphens to protect against invalid path chars
        let safeChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let sanitized = key.unicodeScalars.map { safeChars.contains($0) ? Character($0) : "_" }
        let truncated = String(sanitized.prefix(200))
        return cacheDirectory.appendingPathComponent("\(truncated).cache")
    }

    public func read(forKey key: String) -> Data? {
        let url = fileURL(forKey: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Update modification date for LRU ordering
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    public func write(_ data: Data, forKey key: String) {
        let url = fileURL(forKey: key)
        do {
            try data.write(to: url, options: .atomic)
            approximateDiskBytes += Int64(data.count)
            if approximateDiskBytes > maxDiskBytes {
                pruneIfNeeded()
            }
        } catch {
            // Best-effort write
        }
    }

    public func totalDiskUsage() -> Int64 {
        let total = Self.computeUsage(directory: cacheDirectory, fileManager: fileManager)
        approximateDiskBytes = total
        return total
    }

    private static func computeUsage(directory: URL, fileManager: FileManager) -> Int64 {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
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
        approximateDiskBytes = 0
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

        approximateDiskBytes = totalUsage
        guard totalUsage > maxDiskBytes else { return }

        // Evict oldest files first
        entries.sort { $0.modDate < $1.modDate }

        for entry in entries {
            guard totalUsage > targetDiskBytes else { break }
            do {
                try fileManager.removeItem(at: entry.url)
                totalUsage -= entry.size
            } catch {
                // Ignore failure, don't decrement usage
            }
        }
        approximateDiskBytes = totalUsage
    }
}
