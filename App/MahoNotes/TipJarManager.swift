import StoreKit
import SwiftUI

/// Manages In-App Purchase tip jar products using StoreKit 2.
@Observable
@MainActor
final class TipJarManager {
    /// Available tip products, sorted by price.
    var products: [Product] = []
    /// Whether product loading has completed (regardless of result).
    var didLoadProducts = false
    /// Currently processing purchase (product ID).
    var purchasing: String?
    /// Last error message.
    var errorMessage: String?
    /// Whether a thank-you message should be shown.
    var showThankYou = false

    /// Product identifiers for tip tiers.
    static let productIDs: Set<String> = [
        "com.mahonotes.tip.small",   // ☕ Small tip
        "com.mahonotes.tip.medium",  // 🍱 Medium tip
        "com.mahonotes.tip.large",   // 🎉 Large tip
    ]

    /// Load products from the App Store.
    func loadProducts() async {
        do {
            let storeProducts = try await Product.products(for: Self.productIDs)
            products = storeProducts.sorted { $0.price < $1.price }
        } catch {
            errorMessage = "Failed to load products: \(error.localizedDescription)"
        }
        didLoadProducts = true
    }

    /// Purchase a tip product.
    func purchase(_ product: Product) async {
        purchasing = product.id
        errorMessage = nil

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                // Consumable — finish immediately
                await transaction.finish()
                showThankYou = true
                purchasing = nil
            case .userCancelled:
                purchasing = nil
            case .pending:
                purchasing = nil
            @unknown default:
                purchasing = nil
            }
        } catch {
            errorMessage = "Purchase failed: \(error.localizedDescription)"
            purchasing = nil
        }
    }

    /// Verify the transaction.
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let safe):
            return safe
        }
    }
}
