//
//  OfflineStorageBudget.swift
//  LidarExplorer
//
//  How much more the device can be asked to keep offline.
//
//  Offline downloads are the one thing the app stores that nothing prunes, so they need a ceiling that is not a
//  cache's: a budget for what the user has asked to keep, and a reserve of free space that a download may never
//  eat into, so that a large one cannot leave the device with no room for anything else.
//

import Foundation

public nonisolated enum OfflineStorageBudget {

    /// What the app will keep of downloaded elevation, in all: about 3,500 tiles at the 384 px an iPad Pro 13" asks for
    /// (0.61 MB each), about 2,000 at the 512 px of a 2x display (1.08 MB each).
    public static let elevationBudgetBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// What the app will keep of downloaded basemap tiles, in all: about 35,000 at 30 KB.
    public static let basemapBudgetBytes: Int64 = 1024 * 1024 * 1024

    /// Free space a download leaves alone.
    public static let freeSpaceReserveBytes: Int64 = 1024 * 1024 * 1024

    /// The most that may still be added: what is left of the `budget` after the `used` bytes already kept, and no
    /// more than the disk has free beyond `reserve`. Never negative, and safe for any inputs.
    public static func remaining(budget: Int64, used: Int64, freeDiskBytes: Int64, reserve: Int64) -> Int64 {
        // Non-negative operands make each subtraction below unable to overflow.
        let byBudget = max(budget, 0) - min(max(used, 0), max(budget, 0))
        let byDisk = max(freeDiskBytes, 0) - min(max(reserve, 0), max(freeDiskBytes, 0))
        return min(byBudget, byDisk)
    }

    /// Bytes free on the volume that holds `url` for something the user asked for, counting what the system
    /// would clear to make room; `nil` if the volume cannot say.
    public static func freeDiskBytes(near url: URL) -> Int64? {
        let probe = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}
