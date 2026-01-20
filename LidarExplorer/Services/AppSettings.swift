//
//  AppSettings.swift
//  LidarExplorer
//
//  Type-safe wrapper for UserDefaults access
//

import Foundation

/// Type-safe wrapper for application settings stored in UserDefaults
enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Settings Keys

    enum Key: String {
        case maxCacheSizeGB
        case startLocationName
        case detectedHistoricalFeatures
    }

    // MARK: - Typed Access Methods

    static func double(for key: Key, default defaultValue: Double = 0.0) -> Double {
        let value = defaults.double(forKey: key.rawValue)
        return value == 0.0 ? defaultValue : value
    }

    static func set(_ value: Double, for key: Key) {
        defaults.set(value, forKey: key)
    }

    static func string(for key: Key, default defaultValue: String? = nil) -> String? {
        return defaults.string(forKey: key.rawValue) ?? defaultValue
    }

    static func set(_ value: String?, for key: Key) {
        defaults.set(value, forKey: key)
    }

    static func data(for key: Key) -> Data? {
        return defaults.data(forKey: key.rawValue)
    }

    static func set(_ value: Data?, for key: Key) {
        defaults.set(value, forKey: key)
    }

    static func bool(for key: Key, default defaultValue: Bool = false) -> Bool {
        return defaults.bool(forKey: key.rawValue)
    }

    static func set(_ value: Bool, for key: Key) {
        defaults.set(value, forKey: key)
    }

    // MARK: - Specialized Getters

    /// Get cache size with a default value
    static var maxCacheSizeGB: Double {
        get { double(for: .maxCacheSizeGB, default: 2.0) }
        set { set(newValue, for: .maxCacheSizeGB) }
    }

    /// Get start location name with a default value
    static var startLocationName: String {
        get { string(for: .startLocationName, default: "Random") ?? "Random" }
        set { set(newValue, for: .startLocationName) }
    }

    /// Get detected features data
    static var detectedHistoricalFeaturesData: Data? {
        get { data(for: .detectedHistoricalFeatures) }
        set { set(newValue, for: .detectedHistoricalFeatures) }
    }
}
