import SwiftUI
import StoreKit

/// A tip jar section that can be embedded in Settings (macOS) or a Form (iOS).
struct TipJarView: View {
    @State private var tipJar = TipJarManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Support Maho Notes")
                        .fontWeight(.medium)
                    Text("If you enjoy using Maho Notes, consider leaving a tip!")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "heart.fill")
                    .font(.title2)
                    .foregroundStyle(.pink)
                    .frame(width: 28)
            }

            if tipJar.products.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(tipJar.products, id: \.id) { product in
                        tipButton(for: product)
                    }
                }
            }

            if let error = tipJar.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task {
            await tipJar.loadProducts()
        }
        .alert("Thank You! 🎉", isPresented: $tipJar.showThankYou) {
            Button("OK") { }
        } message: {
            Text("Your support means a lot. Thank you for helping Maho Notes grow! ☕🔭")
        }
    }

    @ViewBuilder
    private func tipButton(for product: Product) -> some View {
        Button {
            Task { await tipJar.purchase(product) }
        } label: {
            VStack(spacing: 4) {
                Text(emoji(for: product.id))
                    .font(.title2)
                Text(product.displayPrice)
                    .font(.callout.bold())
                Text(shortName(for: product.id))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            #if os(macOS)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            #endif
        }
        #if os(macOS)
        .buttonStyle(.plain)
        #else
        .buttonStyle(.bordered)
        #endif
        .disabled(tipJar.purchasing != nil)
        .overlay {
            if tipJar.purchasing == product.id {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func emoji(for productID: String) -> String {
        switch productID {
        case "com.mahonotes.tip.small": return "☕"
        case "com.mahonotes.tip.medium": return "🍱"
        case "com.mahonotes.tip.large": return "🎉"
        default: return "💝"
        }
    }

    private func shortName(for productID: String) -> String {
        switch productID {
        case "com.mahonotes.tip.small": return "Coffee"
        case "com.mahonotes.tip.medium": return "Bento"
        case "com.mahonotes.tip.large": return "Party"
        default: return "Tip"
        }
    }
}
