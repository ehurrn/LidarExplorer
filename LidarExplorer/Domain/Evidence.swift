//
//  Evidence.swift
//  LidarExplorer
//
//  Provenance-carrying measurements. Fabrication is unrepresentable.
//

import Foundation

/// Where a measurement came from.
public nonisolated enum DataSource: String, Sendable, Codable, CaseIterable {
    case usgs3DEP = "USGS 3DEP"
    case sentinel2 = "Copernicus Sentinel-2"
    case openStreetMap = "OpenStreetMap"
    case wikidata = "Wikidata"
    case bundledDataset = "Bundled dataset"
    case onDeviceAnalysis = "On-device analysis"
}

/// Why a measurement could not be obtained.
///
/// Every case is a fact about the world, not a value to substitute for one.
public nonisolated enum UnavailableReason: Sendable, Codable, Equatable {
    /// No credentials configured for the upstream service.
    case notConfigured(DataSource)
    /// The network call failed or timed out.
    case transportFailure(DataSource, description: String)
    /// The service answered, but the payload could not be decoded.
    case undecodable(DataSource, description: String)
    /// The service answered correctly and holds no data for this location.
    case noCoverage(DataSource)
    /// Data exists but fails a plausibility check, so it is not trusted.
    case implausible(DataSource, description: String)
    /// The device is offline and no cached value is available.
    case offline

    public var source: DataSource? {
        switch self {
        case .notConfigured(let s), .noCoverage(let s): s
        case .transportFailure(let s, _), .undecodable(let s, _), .implausible(let s, _): s
        case .offline: nil
        }
    }

    /// A short phrase suitable for display beneath a score.
    public var displayText: String {
        switch self {
        case .notConfigured(let s): "\(s.rawValue) not configured"
        case .transportFailure(let s, _): "\(s.rawValue) unreachable"
        case .undecodable(let s, _): "\(s.rawValue) response unreadable"
        case .noCoverage(let s): "No \(s.rawValue) coverage here"
        case .implausible(let s, _): "\(s.rawValue) data failed sanity check"
        case .offline: "Offline"
        }
    }
}

/// How a present measurement was obtained.
public nonisolated struct Provenance: Sendable, Codable, Equatable {
    public let source: DataSource
    /// When the underlying observation was made by the instrument or survey —
    /// not when this struct was constructed.
    ///
    /// The legacy implementation stamped `Date()` at construction for both
    /// real and fabricated data, which made the field actively misleading.
    /// `nil` means the upstream service did not report an acquisition date.
    public let acquired: Date?
    /// Set when the value was served from a local cache rather than the network.
    public let servedFromCacheAt: Date?

    public init(source: DataSource, acquired: Date? = nil, servedFromCacheAt: Date? = nil) {
        self.source = source
        self.acquired = acquired
        self.servedFromCacheAt = servedFromCacheAt
    }

    public var isCached: Bool { servedFromCacheAt != nil }
}

/// A value that either was genuinely observed, or was not.
///
/// ## Why this type exists
///
/// The predecessor to this code had a function that returned four hardcoded
/// reflectance constants inside the very same struct used for real satellite
/// pixels. Nothing downstream could tell them apart, so those constants cast a
/// full-confidence vote carrying half of the total validation weight — and
/// because credentials are optional, that was the *default* behaviour.
///
/// Making `Evidence` an enum removes the possibility structurally. There is
/// no way to produce an `.observed` case without naming a ``DataSource``, and
/// no way to read a value without acknowledging that `.unavailable` exists.
/// The compiler, not reviewer discipline, is what keeps fabricated data out.
public nonisolated enum Evidence<Value: Sendable>: Sendable {
    case observed(Value, Provenance)
    case unavailable(UnavailableReason)

    /// The value, if one was actually observed.
    public var value: Value? {
        if case .observed(let v, _) = self { return v }
        return nil
    }

    public var provenance: Provenance? {
        if case .observed(_, let p) = self { return p }
        return nil
    }

    public var unavailableReason: UnavailableReason? {
        if case .unavailable(let r) = self { return r }
        return nil
    }

    public var isObserved: Bool {
        if case .observed = self { return true }
        return false
    }

    public func map<T: Sendable>(_ transform: (Value) -> T) -> Evidence<T> {
        switch self {
        case .observed(let v, let p): .observed(transform(v), p)
        case .unavailable(let r): .unavailable(r)
        }
    }
}

extension Evidence: Equatable where Value: Equatable {}
