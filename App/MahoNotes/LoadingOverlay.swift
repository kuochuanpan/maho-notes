#if os(iOS)
import SwiftUI

/// Full-screen launch/resume overlay shown on iOS while the vault registry
/// and notes are loading. Prevents the navigator from briefly rendering an
/// empty "Add a Vault" state before AppState finishes its initial load.
struct LoadingOverlay: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(MahoTheme.vaultRailBackground)
                    .symbolEffect(.pulse, options: .repeating)

                Text("Loading…")
                    .font(.title2.bold())

                ProgressView()
                    .controlSize(.regular)
                    .padding(.top, 8)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .transition(.opacity)
    }
}
#endif
