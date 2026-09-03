//
//  StoreService.swift
//  LidarExplorer
//
//  StoreKit 2 entitlement for the one-time ad removal purchase.
//

import Observation
import StoreKit
import os

/// Owns the "Remove Ads" purchase and the entitlement derived from it.
///
/// A single non-consumable rather than a subscription: the app's data source
/// is free public USGS 3DEP, so there is no recurring cost to justify
/// recurring billing, and charging monthly to *not* see ads reads as hostile.
///
/// `@MainActor` because it drives UI directly; StoreKit 2's own types are
/// `Sendable` and safe to await from here.
@MainActor
@Observable
public final class StoreService {

    /// Must match the product created in App Store Connect.
    public nonisolated static let removeAdsProductID = "com.detsom.LidarExplorer.removeads"

    /// The purchasable product, once loaded from the App Store.
    public private(set) var removeAdsProduct: Product?

    /// Whether ads should be suppressed. The single source of truth.
    public private(set) var hasRemoveAds = false

    public private(set) var isPurchasing = false
    public private(set) var isRestoring = false

    /// Set when a purchase or restore failed in a way worth showing the user.
    public private(set) var lastErrorMessage: String?

    /// Whether the store is reachable and the product was found.
    public private(set) var isProductAvailable = false

    private var updatesTask: Task<Void, Never>?

    public init() {
        // Start listening before any purchase can occur, so a transaction that
        // completes outside a purchase() call -- Ask to Buy approval, a
        // purchase made on another device, an interrupted payment finishing
        // later -- is still observed and unlocks the app.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                await self.handle(update)
            }
        }
    }

    // No `deinit` cancelling `updatesTask`: `deinit` is nonisolated and
    // cannot touch main-actor state. It is not needed either — the loop
    // captures `self` weakly and returns once the service is gone. In
    // practice this object lives for the whole app session anyway.

    // MARK: - Loading

    /// Loads the product and the current entitlement. Safe to call repeatedly.
    public func refresh() async {
        await loadProduct()
        await refreshEntitlement()
    }

    private func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.removeAdsProductID])
            removeAdsProduct = products.first
            isProductAvailable = products.first != nil
            if products.isEmpty {
                Log.store.notice(
                    "Product \(Self.removeAdsProductID, privacy: .public) not returned by the App Store"
                )
            }
        } catch {
            isProductAvailable = false
            Log.store.error("Product load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Recomputes the entitlement from StoreKit's current entitlements.
    ///
    /// Deliberately derived from StoreKit rather than cached in UserDefaults.
    /// A local flag can be flipped by anyone with file access, and it drifts
    /// when a purchase is refunded or revoked by Family Sharing.
    public func refreshEntitlement() async {
        var entitled = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == Self.removeAdsProductID,
               transaction.revocationDate == nil {
                entitled = true
            }
        }
        if entitled != hasRemoveAds {
            Log.store.info("Remove-ads entitlement is now \(entitled)")
        }
        hasRemoveAds = entitled
    }

    // MARK: - Purchase

    /// Buys the product. Returns `true` when the entitlement is granted.
    @discardableResult
    public func purchase() async -> Bool {
        guard let product = removeAdsProduct else {
            lastErrorMessage = "The purchase isn't available right now."
            return false
        }
        guard !isPurchasing else { return false }

        isPurchasing = true
        lastErrorMessage = nil
        defer { isPurchasing = false }

        do {
            switch try await product.purchase() {
            case .success(let verification):
                await handle(verification)
                return hasRemoveAds

            case .userCancelled:
                // Not an error; say nothing rather than nagging.
                return false

            case .pending:
                // Ask to Buy, or a payment needing approval. The updates
                // listener will unlock the app when it resolves.
                lastErrorMessage = "Purchase pending approval."
                return false

            @unknown default:
                return false
            }
        } catch {
            Log.store.error("Purchase failed: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = "Purchase failed. \(error.localizedDescription)"
            return false
        }
    }

    /// Restores a purchase made previously or on another device.
    ///
    /// Apple requires a visible restore path for non-consumables, and a user
    /// on a new device has no other way to recover what they paid for.
    public func restore() async {
        guard !isRestoring else { return }
        isRestoring = true
        lastErrorMessage = nil
        defer { isRestoring = false }

        do {
            try await AppStore.sync()
            await refreshEntitlement()
            if !hasRemoveAds {
                lastErrorMessage = "No previous purchase found for this Apple Account."
            }
        } catch {
            Log.store.error("Restore failed: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = "Restore failed. \(error.localizedDescription)"
        }
    }

    // MARK: - Transactions

    /// Validates a transaction, applies it, and closes it out.
    private func handle(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .verified(let transaction):
            if transaction.productID == Self.removeAdsProductID {
                hasRemoveAds = transaction.revocationDate == nil
            }
            // Must finish, or StoreKit replays it on every launch.
            await transaction.finish()

        case .unverified(_, let error):
            // A transaction that fails App Store signature validation is not
            // trusted, and must not grant the entitlement.
            Log.store.error(
                "Unverified transaction rejected: \(error.localizedDescription, privacy: .public)"
            )
            lastErrorMessage = "That purchase could not be verified."
        }
    }
}
