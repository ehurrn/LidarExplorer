//
//  TileActivityLog.swift
//  LidarExplorer
//
//  In-app record of tile fetches, for diagnosis on device.
//

import Foundation
import Observation
import SwiftUI
import os

/// One tile load, as it happened.
///
/// `Sendable` because it is produced inside the provider actor and consumed
/// on the main actor.
public nonisolated struct TileEvent: Sendable {
    public enum Outcome: String, Sendable {
        case fetched      // came off the network
        case cached       // already had the derivatives
        case cancelled    // superseded by map pan/zoom
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
    @ObservationIgnored
    private let recordingLock = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Set false to stop recording; the provider then does no extra work.
    public var isRecording = false {
        didSet {
            let active = isRecording
            recordingLock.withLock { $0 = active }
        }
    }

    /// Thread-safe check usable by background actors without hopping to MainActor.
    public nonisolated var isRecordingActive: Bool {
        recordingLock.withLock { $0 }
    }

    private var nextID = 0
    private let limit = 300

    public private(set) var fetchedCount = 0
    public private(set) var cachedCount = 0
    public private(set) var cancelledCount = 0
    public private(set) var failedCount = 0
    public private(set) var totalBytes = 0
    private var totalFetchDuration: TimeInterval = 0

    public init() {}

    public func record(_ event: TileEvent) {
        guard isRecording else { return }
        nextID += 1
        entries.insert(Entry(id: nextID, event: event, receivedAt: Date()), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }

        switch event.outcome {
        case .fetched:
            fetchedCount += 1
            totalFetchDuration += event.duration
        case .cached:
            cachedCount += 1
        case .cancelled:
            cancelledCount += 1
        case .failed:
            failedCount += 1
        }
        if let bytes = event.byteCount {
            totalBytes += bytes
        }
    }

    public func clear() {
        entries.removeAll()
        fetchedCount = 0
        cachedCount = 0
        cancelledCount = 0
        failedCount = 0
        totalBytes = 0
        totalFetchDuration = 0
    }

    // MARK: - Summary

    /// Mean duration of network fetches only; cache hits would flatter it.
    public var averageFetchSeconds: Double? {
        guard fetchedCount > 0 else { return nil }
        return totalFetchDuration / Double(fetchedCount)
    }
}
