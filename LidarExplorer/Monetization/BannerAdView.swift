//
//  BannerAdView.swift
//  LidarExplorer
//
//  SwiftUI wrapper for an adaptive banner.
//

import GoogleMobileAds
import SwiftUI
import UIKit
import os

/// A banner that requests an ad once it is actually on screen.
///
/// Loading is driven from `didMoveToWindow` rather than from SwiftUI's
/// `updateUIView`. Two failure modes made that necessary:
///
///  - Requesting in `makeUIView` happens before layout, when the view's
///    bounds are still zero.
///  - Gating `updateUIView` on `window != nil` never fires, because entering
///    a window is not a SwiftUI state change and nothing re-invokes it.
///
/// UIKit already reports both events precisely, so the view owns its own
/// lifecycle and SwiftUI only supplies placement.
public final class AdaptiveBannerView: BannerView {

    private var hasRequested = false
    private var lastRequestedWidth: CGFloat = 0

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        requestIfPossible()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // Rotation or a split-view resize changes the adaptive width enough to
        // warrant a fresh request.
        if hasRequested, abs(availableWidth - lastRequestedWidth) > 1 {
            hasRequested = false
        }
        requestIfPossible()
    }

    /// Width to size the banner to, clamped to the window.
    ///
    /// The SDK rejects a banner wider than the window with "Ad size will not
    /// fit on screen", so the window is the authority rather than the view's
    /// own bounds — which are themselves derived from the ad size, and so
    /// cannot be trusted to bound it.
    private var availableWidth: CGFloat {
        guard let width = window?.bounds.width, width > 0 else { return 0 }
        return width
    }

    private func requestIfPossible() {
        guard !hasRequested, window != nil else { return }
        let width = availableWidth
        guard width >= 320 else { return }

        if rootViewController == nil {
            rootViewController = AdService.topViewController()
        }
        guard rootViewController != nil else { return }

        hasRequested = true
        lastRequestedWidth = width
        adSize = currentOrientationAnchoredAdaptiveBanner(width: width)

        Log.ads.debug(
            "Requesting banner \(self.adSize.size.width, format: .fixed(precision: 0))x\(self.adSize.size.height, format: .fixed(precision: 0)) in window \(width, format: .fixed(precision: 0))"
        )
        load(AdService.makeRequest())
    }
}

/// Places an ``AdaptiveBannerView`` in the SwiftUI hierarchy.
public struct BannerAdView: UIViewRepresentable {

    public init() {}

    public func makeUIView(context: Context) -> AdaptiveBannerView {
        let view = AdaptiveBannerView(adSize: AdSizeBanner)
        view.adUnitID = AdService.bannerUnitID
        view.delegate = context.coordinator
        return view
    }

    public func updateUIView(_ view: AdaptiveBannerView, context: Context) {
        // Nothing to push: the view drives its own request from didMoveToWindow.
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator: NSObject, BannerViewDelegate {
        nonisolated public func bannerViewDidReceiveAd(_ bannerView: BannerView) {
            Log.ads.info("Banner loaded")
        }
        nonisolated public func bannerView(
            _ bannerView: BannerView, didFailToReceiveAdWithError error: any Error
        ) {
            // Expected offline and in regions with no fill. Not an app error.
            Log.ads.notice("Banner failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Reserves banner height only while an ad is actually being shown.
///
/// A permanently reserved strip would waste map area for paying customers and
/// for free users whose ad failed to fill.
public struct BannerAdSlot: View {
    let isActive: Bool

    public init(isActive: Bool) {
        self.isActive = isActive
    }

    /// Height must come from the ad size, not a constant.
    ///
    /// An anchored adaptive banner's height scales with width — about 50pt at
    /// phone widths, 90pt across a 13-inch iPad. Pinning the container to
    /// 50pt would make the ad taller than its host and the request would be
    /// rejected.
    private var adHeight: CGFloat {
        let width = AdService.topViewController()?.view.bounds.width ?? 0
        guard width >= 320 else { return AdSizeBanner.size.height }
        return currentOrientationAnchoredAdaptiveBanner(width: width).size.height
    }

    public var body: some View {
        if isActive {
            BannerAdView()
                .frame(maxWidth: .infinity)
                .frame(height: adHeight)
                .background(.thinMaterial)
        }
    }
}
