//
//  Log.swift
//  LidarExplorer
//
//  Structured os.Logger telemetry. One subsystem, discrete categories.
//

import OSLog

/// Central logging facade.
///
/// Every subsystem logs through a named category so Console.app and
/// `log stream --predicate` can filter by concern without string matching
/// on message bodies.
///
/// Marked `nonisolated` because logging must be callable from any isolation
/// domain — actors, detached compute tasks, and the main actor alike.
/// `Logger` is `Sendable`, so sharing these across domains is safe.
public nonisolated enum Log {

    /// Reverse-DNS subsystem identifier. Falls back to a literal when the
    /// bundle identifier is unavailable (unit-test hosts, previews).
    public static let subsystem: String =
        Bundle.main.bundleIdentifier ?? "com.detsom.LidarExplorer"

    /// Detection algorithms, scoring, and the analysis pipeline.
    public static let engine = Logger(subsystem: subsystem, category: "Engine")

    /// Metal pipeline construction, shader dispatch, and GPU fallbacks.
    public static let shader = Logger(subsystem: subsystem, category: "Shader")

    /// Coordinate math, elevation grids, tiling, and caching.
    public static let geospatial = Logger(subsystem: subsystem, category: "Geospatial")

    /// HTTP transport, authentication, retries, and decoding.
    public static let network = Logger(subsystem: subsystem, category: "Network")

    /// Multi-source corroboration and confidence scoring.
    public static let validation = Logger(subsystem: subsystem, category: "Validation")

    /// Files the app keeps for the user: the field notebook and its damaged-file handling.
    public static let storage = Logger(subsystem: subsystem, category: "Storage")

    /// SwiftUI state transitions and user-facing presentation.
    public static let ui = Logger(subsystem: subsystem, category: "UI")
}

/// Signposts for `Instruments` timing of the analysis pipeline.
public nonisolated enum Signpost {
    public static let analysis = OSSignposter(
        subsystem: Log.subsystem, category: "Analysis"
    )
    public static let raster = OSSignposter(
        subsystem: Log.subsystem, category: "Raster"
    )
}
