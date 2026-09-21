//
//  FieldNotebook.swift
//  LidarExplorer
//
//  A field notebook as it is saved: every trace and waypoint in the order it was made, so that undo takes back the
//  newest item after a relaunch just as it did before. The file is versioned JSON; reading it is forgiving of
//  single bad items and strict about files that are not notebooks at all. Pure Foundation, so it is tested
//  host-side.
//

import Foundation

public nonisolated struct FieldNotebook: Sendable, Equatable {

    /// The file format's version. A file from a later one is refused rather than read, since saving over it would
    /// drop whatever a later version added.
    public static let currentVersion = 1

    public enum Item: Sendable, Equatable {
        case trace(FieldAnnotationTrace)
        case waypoint(FieldWaypoint)

        public var id: UUID {
            switch self {
            case .trace(let trace): trace.id
            case .waypoint(let waypoint): waypoint.id
            }
        }
    }

    /// Oldest first.
    public var items: [Item]

    public init(items: [Item] = []) {
        self.items = items
    }

    public var isEmpty: Bool { items.isEmpty }
    public var traces: [FieldAnnotationTrace] { items.compactMap { if case .trace(let trace) = $0 { trace } else { nil } } }
    public var waypoints: [FieldWaypoint] { items.compactMap { if case .waypoint(let waypoint) = $0 { waypoint } else { nil } } }

    public enum DecodeError: Error, Equatable, Sendable {
        /// Not JSON, not an object, or missing a version or its items.
        case notANotebook(String)
        /// A version this build does not know.
        case unsupportedVersion(Int)
    }

    /// A notebook as read, and how many of its items were left out.
    public struct Decoded: Sendable, Equatable {
        public var notebook: FieldNotebook
        /// Items that could not be read, were of an unknown kind, or were not a place, a line or a colour worth
        /// keeping.
        public var dropped: Int
    }

    // MARK: - Writing

    /// The notebook as a file's bytes, keys sorted so the same notebook is always the same bytes.
    ///
    /// A value that is not a number is written as text rather than refused: a save that throws would throw every
    /// time, and the notebook would silently stop being kept. Reading cleans such values out.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: Self.infinity, negativeInfinity: Self.negativeInfinity, nan: Self.notANumber)
        return try encoder.encode(Written(version: Self.currentVersion, items: items.map(WrittenItem.init)))
    }

    // MARK: - Reading

    /// Reads a notebook, leaving out and counting what cannot be kept (see ``sanitized()``).
    ///
    /// Throws for a file that is not a notebook, or is from a later version. One item that cannot be read costs
    /// only itself, so a single damaged stroke does not take the whole notebook with it.
    public static func decode(_ data: Data) throws -> Decoded {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: infinity, negativeInfinity: negativeInfinity, nan: notANumber)

        let version: Int
        do {
            version = try decoder.decode(VersionProbe.self, from: data).version
        } catch {
            throw DecodeError.notANotebook("it has no version")
        }
        guard version >= 1 else { throw DecodeError.notANotebook("its version is \(version)") }
        guard version <= currentVersion else { throw DecodeError.unsupportedVersion(version) }

        let read: Read
        do {
            read = try decoder.decode(Read.self, from: data)
        } catch {
            throw DecodeError.notANotebook("it has no list of items")
        }
        var unreadable = 0
        var items: [Item] = []
        for entry in read.items {
            switch (entry.value?.kind, entry.value?.trace, entry.value?.waypoint) {
            case ("trace", let trace?, _): items.append(.trace(trace))
            case ("waypoint", _, let waypoint?): items.append(.waypoint(waypoint))
            default: unreadable += 1
            }
        }
        var decoded = FieldNotebook(items: items).sanitized()
        decoded.dropped += unreadable
        return decoded
    }

    /// The notebook with what cannot be kept taken out, and how many items went.
    ///
    /// A waypoint that is not a place on Earth goes. A trace loses its vertices that are not places and goes if
    /// fewer than two are left; a colour that is not hex becomes the default ink, and a width that is not a
    /// number or is beyond any pen is brought into 0.1 to 1000 (4 if it is not a number). An elevation that is not
    /// a number is forgotten. An item whose identity was already seen goes, since undo and the map find items by it.
    public func sanitized() -> Decoded {
        var seen = Set<UUID>()
        var kept: [Item] = []
        var dropped = 0
        for item in items {
            guard seen.insert(item.id).inserted else {
                dropped += 1
                continue
            }
            switch item {
            case .waypoint(var waypoint):
                guard waypoint.position.isValid else {
                    dropped += 1
                    continue
                }
                if let elevation = waypoint.elevationMeters, !elevation.isFinite { waypoint.elevationMeters = nil }
                kept.append(.waypoint(waypoint))
            case .trace(var trace):
                trace.positions = trace.positions.filter(\.isValid)
                guard trace.positions.count >= 2 else {
                    dropped += 1
                    continue
                }
                if !FieldMarkup.isValidColorHex(trace.colorHex) { trace.colorHex = FieldMarkup.defaultInkHex }
                trace.strokeWidth = trace.strokeWidth.isFinite ? min(max(trace.strokeWidth, 0.1), 1000) : 4
                kept.append(.trace(trace))
            }
        }
        return Decoded(notebook: FieldNotebook(items: kept), dropped: dropped)
    }

    // MARK: - The file's shape

    private static let infinity = "inf"
    private static let negativeInfinity = "-inf"
    private static let notANumber = "nan"

    private nonisolated struct Written: Encodable {
        var version: Int
        var items: [WrittenItem]
    }

    /// An item's kind names which of its two payloads is present.
    private nonisolated struct WrittenItem: Codable {
        var kind: String
        var trace: FieldAnnotationTrace?
        var waypoint: FieldWaypoint?

        init(_ item: Item) {
            switch item {
            case .trace(let trace):
                kind = "trace"
                self.trace = trace
            case .waypoint(let waypoint):
                kind = "waypoint"
                self.waypoint = waypoint
            }
        }
    }

    private nonisolated struct VersionProbe: Decodable {
        var version: Int
    }

    private nonisolated struct Read: Decodable {
        var items: [Lossy<WrittenItem>]
    }

    /// Decodes to `nil` instead of throwing, so one bad element does not fail the array around it.
    private nonisolated struct Lossy<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }
}
