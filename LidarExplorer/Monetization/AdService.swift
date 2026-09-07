//
//  AdService.swift
//  LidarExplorer
//
//  Ad SDK lifecycle, gated on the remove-ads entitlement.
//

import GoogleMobileAds
import Observation
import SwiftUI
import UIKit
import UserMessagingPlatform
import os

/// Starts and configures the ad SDK for the free tier.
///
/// ## Non-personalized only
///
/// Requests are configured with
/// ``PublisherPrivacyPersonalizationState/disabled`` before the SDK starts,
/// and carry the legacy `npa=1` extra as well, since some mediation adapters
/// still read only that. The consequence is deliberate: no cross-app
/// tracking, so **no App Tracking Transparency prompt is required**, and the
/// App Privacy disclosure stays narrow. It trades some ad revenue for a much
/// simpler privacy posture — a good deal for a professional tool whose ATT
/// opt-in rate would be poor anyway.
///
/// ## Gating
///
/// The SDK is never started for a customer who bought ad removal. Starting it
/// would collect data on someone who paid specifically not to be advertised
/// to, and `start()` is what kicks off the SDK's own network activity.
@MainActor
@Observable
public final class AdService {

    /// Google's documented test banner unit.
    ///
    /// Replace with the real unit before shipping. Serving live ads against a
    /// real unit during development risks invalid-traffic strikes on the
    /// AdMob account, which is why Google publishes these.
    public nonisolated static let testBannerUnitID = "ca-app-pub-3940256099942544/2934735716"

    /// The unit ads are actually requested from.
    public nonisolated static var bannerUnitID: String {
        #if DEBUG
        testBannerUnitID
        #else
        // TODO: replace with the production AdMob banner unit ID.
        testBannerUnitID
        #endif
    }

    /// True once the SDK has started and ads may be requested.
    public private(set) var canShowAds = false

    /// True while consent is being gathered, so the UI can hold off.
    public private(set) var isPreparing = false

    /// Whether a privacy-options entry point must be offered (EEA/UK).
    public private(set) var requiresPrivacyOptions = false

    private var hasStarted = false

    public init() {}

    /// Prepares the ad stack unless the user has bought ad removal.
    ///
    /// Idempotent. Calling it after a purchase tears the banner down.
    public func prepare(hasRemoveAds: Bool) async {
        guard !hasRemoveAds else {
            canShowAds = false
            Log.ads.info("Ad removal owned; ad SDK will not be started.")
            return
        }
        guard !hasStarted else {
            canShowAds = ConsentInformation.shared.canRequestAds
            return
        }
        hasStarted = true
        isPreparing = true
        defer { isPreparing = false }

        await gatherConsent()

        // Must be set before start() so the very first request carries it.
        let configuration = MobileAds.shared.requestConfiguration
        configuration.publisherPrivacyPersonalizationState = .disabled

        await withCheckedContinuation { continuation in
            MobileAds.shared.start { _ in continuation.resume() }
        }

        // canRequestAds is false when consent is required and not yet given.
        canShowAds = ConsentInformation.shared.canRequestAds
        requiresPrivacyOptions =
            ConsentInformation.shared.privacyOptionsRequirementStatus == .required

        Log.ads.info("Ad SDK started. canShowAds=\(self.canShowAds)")
    }

    /// Runs the UMP consent flow.
    ///
    /// Required in the EEA and UK even for non-personalized ads: consent
    /// covers the SDK's data processing, not just ad targeting.
    private func gatherConsent() async {
        let parameters = RequestParameters()

        await withCheckedContinuation { continuation in
            ConsentInformation.shared.requestConsentInfoUpdate(with: parameters) { error in
                if let error {
                    Log.ads.error(
                        "Consent info update failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
                continuation.resume()
            }
        }

        guard let controller = Self.topViewController() else { return }

        await withCheckedContinuation { continuation in
            ConsentForm.loadAndPresentIfRequired(from: controller) { error in
                if let error {
                    Log.ads.error(
                        "Consent form failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
                continuation.resume()
            }
        }
    }

    /// Re-presents the privacy options form, for the settings entry point.
    public func presentPrivacyOptions() async {
        guard let controller = Self.topViewController() else { return }
        await withCheckedContinuation { continuation in
            ConsentForm.presentPrivacyOptionsForm(from: controller) { error in
                if let error {
                    Log.ads.error(
                        "Privacy options failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
                continuation.resume()
            }
        }
    }

    /// Builds a request carrying the non-personalized signal.
    nonisolated static func makeRequest() -> Request {
        let request = Request()
        // Belt and braces alongside publisherPrivacyPersonalizationState:
        // some mediation adapters only read this older extra.
        let extras = Extras()
        extras.additionalParameters = ["npa": "1"]
        request.register(extras)
        return request
    }

    /// The view controller ads should present from.
    nonisolated static func topViewController() -> UIViewController? {
        MainActor.assumeIsolated {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            guard var top = scene?.keyWindow?.rootViewController else { return nil }
            while let presented = top.presentedViewController { top = presented }
            return top
        }
    }
}
