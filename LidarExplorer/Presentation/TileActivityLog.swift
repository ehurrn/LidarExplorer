//
//  TileActivityLog.swift
//  LidarExplorer
//
//  In-app record of tile fetches, for diagnosis on device.
//

import Foundation
import Observation
import SwiftUI

/// One tile load, as it happened.
///
/// `Sendable` because it is produced inside the provider actor and consumed
/// on the main actor.
public nonisolated struct TileEvent: Sendable {
    public enum Outcome: String, Sendable {
        case fetched      // came off the network
        case cached       // already had the derivatives
        case failed       // no data for this tile
    }

    public let z: Int
    public let x: Int
    public let y: Int
    /// Which elevation source served it.
    public let source: String
    public let outcome: Outcome
    public let duration: TimeInterval
    /// Ground sample distance of the delivered raster, in metres.
    public let resolution: Double?
    public let byteCount: Int?
    public let backend: RasterCompute.Backend?

    public init(
        z: Int, x: Int, y: Int, source: String, outcome: Outcome,
        duration: TimeInterval, resolution: Double? = nil,
        byteCount: Int? = nil, backend: RasterCompute.Backend? = nil
    ) {
        self.z = z; self.x = x; self.y = y
        self.source = source
        self.outcome = outcome
        self.duration = duration
        self.resolution = resolution
        self.byteCount = byteCount
        self.backend = backend
    }
}

/// A bounded, observable record of recent tile activity.
///
/// Kept in memory only, and only while the debug panel is switched on — this
/// is a diagnostic aid, not telemetry, and nothing here leaves the device.
@MainActor
@Observable
public final class TileActivityLog {

    public struct Entry: Identifiable, Sendable {
        public let id: Int
        public let event: TileEvent
        public let receivedAt: Date
    }

    /// Newest first.
    public private(set) var entries: [Entry] = []
    /// Set false to stop recording; the provider then does no extra work.
    public var isRecording = false

    private var nextID = 0
    private let limit = 300

    public init() {}

    public func record(_ event: TileEvent) {
        guard isRecording else { return }
        nextID += 1
        entries.insert(Entry(id: nextID, event: event, receivedAt: Date()), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    public func clear() {
        entries.removeAll()
    }

    // MARK: - Summary

    public var fetchedCount: Int { entries.filter { $0.event.outcome == .fetched }.count }
    public var cachedCount: Int { entries.filter { $0.event.outcome == .cached }.count }
    public var failedCount: Int { entries.filter { $0.event.outcome == .failed }.count }

    /// Mean duration of network fetches only; cache hits would flatter it.
    public var averageFetchSeconds: Double? {
        let fetches = entries.filter { $0.event.outcome == .fetched }
        guard !fetches.isEmpty else { return nil }
        return fetches.reduce(0) { $0 + $1.event.duration } / Double(fetches.count)
    }

    public var totalBytes: Int {
        entries.compactMap(\.event.byteCount).reduce(0, +)
    }
}
