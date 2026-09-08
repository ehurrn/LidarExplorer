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
    private let maxDiskBytes: Int64
    private let targetDiskBytes: Int64

    /// Bytes on disk, or `nil` while the directory has never been measured.
    ///
    /// Measuring means a full `contentsOfDirectory` plus a stat per file —
    /// ~22 ms for a 12,000-file cache on a warm Mac SSD, and materially worse
    /// cold on device. `TerrainViewerModel` is `@MainActor` and builds
    /// `TerrainTileProvider` (and so this actor) from its `init`, so doing
    /// that walk here put it on the main thread during launch, scaling with
    /// however much the user had cached. The figure is only ever needed to
    /// decide *when* to prune, so the first write kicks the walk off to a
    /// background task and the counter carries it from there.
    private var knownDiskBytes: Int64?

    /// Guards against queueing a second directory walk while one is running.
    private var isMeasuring = false

    /// Last-access times for entries touched this session, keyed by file name.
    ///
    /// Reads used to stamp each file's modification date so `pruneIfNeeded`
    /// could order by recency. That is a synchronous metadata write on every
    /// cache hit, serialized through this actor behind every other tile fetch,
    /// and it measured at ~13 µs per read — about a fifth of the cost of a hit.
    /// Holding recency in memory is free and, within a session, strictly more
    /// accurate: it records reads, where a modification date mostly records
    /// writes. Entries absent here fall back to the file's modification date,
    /// which is all a fresh launch has anyway.
    private var recency: [String: Date] = [:]

    private var hitCount = 0
    private var missCount = 0

    /// Cap on `recency` so a long browsing session cannot grow it without
    /// bound. Evicting the oldest half costs nothing in eviction quality:
    /// those entries fall back to modification date, and they are the first
    /// candidates for disk eviction regardless.
    private let recencyLimit = 8192

    public init(
        directory: URL? = nil,
        maxDiskBytes: Int64 = 500 * 1024 * 1024,   // 500 MB max footprint
        targetDiskBytes: Int64 = 400 * 1024 * 1024 // Prune down to 400 MB
    ) {
        self.maxDiskBytes = maxDiskBytes
        self.targetDiskBytes = targetDiskBytes
        let fm = FileManager.default
        if let directory {
            self.cacheDirectory = directory
        } else {
            let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? fm.temporaryDirectory
            self.cacheDirectory = base.appendingPathComponent("TerrainTiles", isDirectory: true)
        }
        try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Characters allowed in a cache filename. Everything else becomes `_`.
    private nonisolated static let safeChars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    /// Longest filename stem produced from a key, in characters.
    private nonisolated static let maxNameLength = 200

    private nonisolated static func isSafeASCII(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"):
            return true
        default:
            return false
        }
    }

    /// Filename for a cache key.
    ///
    /// The keys the provider generates are built from a fixed template and are
    /// always filename-safe, but the general path rebuilds the name character
    /// by character through a `CharacterSet` — ~13 µs per call, another fifth
    /// of the cost of a cache hit, paid on reads and writes alike. A byte scan
    /// settles the common case without allocating; anything that actually
    /// needs rewriting still takes the original path, so the mapping (and its
    /// collisions) is unchanged.
    private nonisolated static func fileName(forKey key: String) -> String {
        var length = 0
        var safe = true
        for byte in key.utf8 {
            length += 1
            if !isSafeASCII(byte) {
                safe = false
                break
            }
        }
        // Every safe byte is ASCII, so a fully safe key has one character per
        // byte and the length check below is the same one the slow path makes.
        if safe && length <= maxNameLength {
            return key + ".cache"
        }
        let sanitized = key.unicodeScalars.map { safeChars.contains($0) ? Character($0) : "_" }
        return String(sanitized.prefix(maxNameLength)) + ".cache"
    }

    /// Records an access for eviction ordering, trimming the map when it grows
    /// past its cap.
    private func touch(_ name: String) {
        recency[name] = Date()
        guard recency.count > recencyLimit else { return }
        let survivors = recency.sorted { $0.value > $1.value }.prefix(recencyLimit / 2)
        recency = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
    }

    public func read(forKey key: String) -> Data? {
        let name = Self.fileName(forKey: key)
        let url = cacheDirectory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            missCount += 1
            return nil
        }
        hitCount += 1
        // First touch of this file this session: refresh the modification
        // date, which is the only recency signal that outlives the process.
        // Later reads update memory only, so a hot tile costs one metadata
        // write per session rather than one per hit.
        if recency[name] == nil {
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
        touch(name)
        return data
    }

    public func write(_ data: Data, forKey key: String) {
        let name = Self.fileName(forKey: key)
        do {
            try data.write(to: cacheDirectory.appendingPathComponent(name), options: .atomic)
            touch(name)
            guard let known = knownDiskBytes else {
                beginMeasurementIfNeeded()
                return
            }
            let projected = known + Int64(data.count)
            knownDiskBytes = projected
            if projected > maxDiskBytes {
                pruneIfNeeded()
            }
        } catch {
            // Best-effort write
        }
    }

    /// Measures the directory off-actor, then adopts the result.
    ///
    /// The walk has to happen somewhere: it is the only thing that can tell a
    /// fresh launch whether the previous session left the cache over its cap.
    /// Running it inline on the first write would stall this actor for ~25 ms
    /// in the middle of the opening burst of tile fetches, with every
    /// concurrent read queued behind it. Detached, it costs the tile path
    /// nothing but a brief hop to take the number.
    private func beginMeasurementIfNeeded() {
        guard !isMeasuring else { return }
        isMeasuring = true
        let directory = cacheDirectory
        Task.detached(priority: .utility) { [weak self] in
            let total = Self.computeUsage(directory: directory, fileManager: FileManager())
            await self?.adoptMeasurement(total)
        }
    }

    /// Takes an off-actor measurement and prunes if it puts us over the cap.
    ///
    /// Writes that land while the walk is in flight are not counted, so the
    /// figure can start a few hundred KB low against a 500 MB cap. The next
    /// prune re-measures and corrects it.
    private func adoptMeasurement(_ total: Int64?) {
        isMeasuring = false
        // A failed walk leaves the cache unmeasured, so the next write retries
        // rather than trusting a figure of zero.
        guard let total else { return }
        knownDiskBytes = total
        if total > maxDiskBytes {
            pruneIfNeeded()
        }
    }

    /// Hit/miss tallies for the disk tier, since launch.
    public nonisolated struct Statistics: Sendable {
        public let hits: Int
        public let misses: Int
        public var reads: Int { hits + misses }
        /// Fraction of reads served from disk; 0 when nothing has been read.
        public var hitRate: Double {
            reads == 0 ? 0 : Double(hits) / Double(reads)
        }
    }

    public func statistics() -> Statistics {
        Statistics(hits: hitCount, misses: missCount)
    }

    /// Measured bytes on disk, or `nil` if the directory has not been walked
    /// yet (or could not be read).
    public func measuredUsage() -> Int64? { knownDiskBytes }

    public func totalDiskUsage() -> Int64 {
        guard let total = Self.computeUsage(directory: cacheDirectory, fileManager: fileManager)
        else { return knownDiskBytes ?? 0 }
        knownDiskBytes = total
        return total
    }

    /// Total bytes in `directory`, or `nil` if it could not be enumerated.
    ///
    /// The distinction matters: reporting an unreadable directory as empty
    /// would pin the usage figure at zero and silently disable the size cap
    /// for the rest of the session.
    private nonisolated static func computeUsage(directory: URL, fileManager: FileManager) -> Int64? {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return nil }

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
        knownDiskBytes = 0
        recency.removeAll()
    }

    private func pruneIfNeeded() {
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        struct CachedFileInfo {
            let url: URL
            let name: String
            let size: Int64
            let lastUsed: Date
        }

        var entries: [CachedFileInfo] = []
        var totalUsage: Int64 = 0

        for url in fileURLs {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
               let size = values.fileSize {
                let s = Int64(size)
                let name = url.lastPathComponent
                // In-session accesses win; anything untouched this launch is
                // ordered by modification date, as before.
                let used = recency[name] ?? values.contentModificationDate ?? Date.distantPast
                entries.append(CachedFileInfo(url: url, name: name, size: s, lastUsed: used))
                totalUsage += s
            }
        }

        knownDiskBytes = totalUsage
        guard totalUsage > maxDiskBytes else { return }

        // Evict least recently used first
        entries.sort { $0.lastUsed < $1.lastUsed }

        for entry in entries {
            guard totalUsage > targetDiskBytes else { break }
            do {
                try fileManager.removeItem(at: entry.url)
                totalUsage -= entry.size
                recency.removeValue(forKey: entry.name)
            } catch {
                // Ignore failure, don't decrement usage
            }
        }
        knownDiskBytes = totalUsage
    }
}
