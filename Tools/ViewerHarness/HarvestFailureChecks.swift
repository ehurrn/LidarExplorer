//
//  HarvestFailureChecks.swift
//  ViewerHarness
//
//  A download that could not finish has to say why. A tile that failed used to be counted and its reason dropped, so
//  "3,000 could not be downloaded" could be a dead server, a full disk or a lost connection, and nothing on the screen
//  or in the log could tell them apart.
//

import CoreLocation
import Foundation

@MainActor
func runHarvestFailureChecks() async {
    print("\n=== Why a download failed ===")
    await checkFailureReasons()
    await checkFailureReasonsAreBounded()
    checkFailureDescription()
    await checkFailureReasonsReachTheController()
}

/// A source whose tiles fail for reasons the test chooses.
private nonisolated final class ReasonedSource: HarvestTileSource, @unchecked Sendable {
    let reason: @Sendable (HarvestTile) -> String?
    init(reason: @escaping @Sendable (HarvestTile) -> String?) { self.reason = reason }
    func estimatedBytesPerTile(pixels: Int) -> Int64 { 1_000 }
    func harvest(_ tile: HarvestTile, pixels: Int) async -> HarvestTileOutcome {
        if let reason = reason(tile) { return .failed(reason: reason) }
        return .stored(bytes: 1_000)
    }
}

private let failureConfiguration = HarvestConfiguration(region: downloadRegion, minZ: 15, maxZ: 16, pixels: 384)

private func run(_ source: ReasonedSource) async -> HarvestSummary? {
    let coordinator = OfflineHarvestCoordinator(elevation: source, manifestDirectory: manifestDirectory())
    return try? await coordinator.harvest(failureConfiguration, resuming: nil)
}

// MARK: - F1. The reasons are kept

@MainActor
private func checkFailureReasons() async {
    print("\n--- F1. the reasons are counted ---")
    let tiles = OfflineHarvestCoordinator.tiles(for: failureConfiguration)
    // One tile in four fails as unavailable, two in four as timed out, one in four succeeds: the commoner reason sorts
    // later alphabetically, so ordering by count and ordering by name cannot be mistaken for each other.
    let unavailable = tiles.filter { ($0.x + $0.y) % 4 == 0 }.count
    let timedOut = tiles.filter { ($0.x + $0.y) % 4 == 1 || ($0.x + $0.y) % 4 == 2 }.count
    let summary = await run(ReasonedSource { tile in
        switch (tile.x + tile.y) % 4 {
        case 0: "HTTP 503"
        case 1, 2: "The request timed out."
        default: nil
        }
    })
    let expected = [HarvestFailure(reason: "The request timed out.", count: timedOut), HarvestFailure(reason: "HTTP 503", count: unavailable)]
    check("a run that fails tiles for two reasons says which, and how many each, the commonest first",
          summary?.failed == unavailable + timedOut && summary?.failures == expected && timedOut > unavailable && unavailable > 0,
          "\(String(describing: summary?.failures)) expected \(expected), \(String(describing: summary?.failed)) failed")

    let clean = await run(ReasonedSource { _ in nil })
    check("a run with no failures lists none", clean?.failed == 0 && clean?.failures.isEmpty == true, "\(String(describing: clean?.failures))")

    // A resumed run reports its own failures, not the last run's.
    let flaky = SwitchedReason("HTTP 503")
    let directory = manifestDirectory()
    let coordinator = OfflineHarvestCoordinator(elevation: ReasonedSource { _ in flaky.current }, manifestDirectory: directory)
    let first = try? await coordinator.harvest(failureConfiguration, resuming: nil)
    flaky.current = nil
    let second = try? await coordinator.harvest(failureConfiguration, resuming: first?.jobID)
    check("a resumed run reports only what failed in it: the reasons of the run before do not carry over",
          first?.failures == [HarvestFailure(reason: "HTTP 503", count: tiles.count)] && second?.failed == 0 && second?.failures.isEmpty == true,
          "\(String(describing: first?.failures)) then \(String(describing: second?.failures))")
}

private nonisolated final class SwitchedReason: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String?) { self.value = value }
    var current: String? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

// MARK: - F2. Bounded

@MainActor
private func checkFailureReasonsAreBounded() async {
    print("\n--- F2. the reasons are bounded ---")
    // A reason that names its tile is different for every one, so a job of thousands could otherwise keep thousands of them.
    let tiles = OfflineHarvestCoordinator.tiles(for: failureConfiguration)
    let unique = await run(ReasonedSource { tile in "the file for tile \(tile.z)/\(tile.x)/\(tile.y) could not be saved" })
    let listed = unique?.failures ?? []
    let others = tiles.count - 32
    check("a reason that is different for every tile does not grow without bound: at most five are listed, and past 32 kinds the rest are counted together",
          tiles.count > 32 && unique?.failed == tiles.count && listed.count == 5
          && listed.first == HarvestFailure(reason: "other reasons", count: others)
          && listed.dropFirst().allSatisfy { $0.count == 1 }
          && listed.dropFirst().map(\.reason) == listed.dropFirst().map(\.reason).sorted(),
          "\(tiles.count) tiles, \(listed.count) listed, first \(String(describing: listed.first))")

    let long = await run(ReasonedSource { _ in String(repeating: "x", count: 500) })
    check("a very long reason is cut, not kept whole", long?.failures.first?.reason.count == 120 && long?.failures.count == 1,
          "\(long?.failures.first?.reason.count ?? -1) characters")
}

// MARK: - F3. Wording

@MainActor
private func checkFailureDescription() {
    print("\n--- F3. what the result says ---")
    func summary(failed: Int, _ failures: [HarvestFailure]) -> HarvestSummary {
        HarvestSummary(jobID: UUID(), state: .completed, total: 100, completed: 100 - failed, failed: failed, bytesStored: 0, failures: failures)
    }
    let none = OfflineHarvestController.failureDescription(for: summary(failed: 0, []))
    let one = OfflineHarvestController.failureDescription(for: summary(failed: 12, [HarvestFailure(reason: "HTTP 503", count: 12)]))
    let several = OfflineHarvestController.failureDescription(for: summary(failed: 20, [
        HarvestFailure(reason: "HTTP 503", count: 12), HarvestFailure(reason: "The request timed out.", count: 3)]))
    let unrecorded = OfflineHarvestController.failureDescription(for: summary(failed: 4, []))
    check("the reasons are worded as a list with counts, and what the list leaves out is said",
          none.isEmpty && one == "HTTP 503 (12)"
          && several == "HTTP 503 (12); The request timed out. (3); and 5 more for other reasons"
          && unrecorded == "no reason was recorded",
          "'\(none)' | '\(one)' | '\(several)' | '\(unrecorded)'")
}

// MARK: - F4. On the screen's model

@MainActor
private func checkFailureReasonsReachTheController() async {
    print("\n--- F4. the screen's model ---")
    let failing = MockHarvestSource(bytesPerTile: 1_000, delayMilliseconds: 1, fails: { ($0.x + $0.y) % 5 == 0 })
    let controller = makeController(elevation: failing)
    await controller.start()
    var text = ""
    if let done = summary(of: controller) { text = OfflineHarvestController.failureDescription(for: done) }
    check("a finished job with failures has its reasons for the screen",
          summary(of: controller)?.failures.first?.reason == "mock failure" && text.hasPrefix("mock failure ("),
          "'\(text)'")
}
