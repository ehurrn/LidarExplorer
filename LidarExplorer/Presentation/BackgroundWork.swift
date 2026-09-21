//
//  BackgroundWork.swift
//  LidarExplorer
//
//  Keeps the app running long enough to finish work it began as it was sent to the background.
//

#if canImport(UIKit)
import UIKit

@MainActor
enum BackgroundWork {

    /// Runs `work`, and asks the system not to suspend the app until it is done. Without this, a save begun on the
    /// way to the background can be cut off half way by the suspension it was racing.
    static func run(_ name: String, _ work: @escaping @MainActor () async -> Void) {
        let assertion = Assertion()
        assertion.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            // Out of time: hand the assertion back rather than be terminated for holding it.
            assertion.end()
        }
        Task {
            await work()
            assertion.end()
        }
    }

    @MainActor
    private final class Assertion {
        var identifier = UIBackgroundTaskIdentifier.invalid

        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
}
#endif
