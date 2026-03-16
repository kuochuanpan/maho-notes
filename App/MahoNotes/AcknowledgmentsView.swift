import SwiftUI

/// Displays open source acknowledgments for third-party dependencies.
struct AcknowledgmentsView: View {
    var body: some View {
        List {
            Section {
                Text("Maho Notes is built with the following open source libraries. Thank you to all the authors and contributors!")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section("Direct Dependencies") {
                ForEach(directDependencies) { dep in
                    DependencyRow(dependency: dep)
                }
            }

            Section("Transitive Dependencies") {
                ForEach(transitiveDependencies) { dep in
                    DependencyRow(dependency: dep)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 400)
        #endif
        .navigationTitle("Acknowledgments")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Dependency Model

private struct Dependency: Identifiable {
    let id: String
    let name: String
    let author: String
    let license: String
    let url: URL

    init(_ name: String, author: String, license: String, url: String) {
        self.id = name
        self.name = name
        self.author = author
        self.license = license
        self.url = URL(string: url)!
    }
}

// MARK: - Row View

private struct DependencyRow: View {
    let dependency: Dependency

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Link(destination: dependency.url) {
                    HStack(spacing: 4) {
                        Text(dependency.name)
                            .fontWeight(.medium)
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                    }
                }

                Spacer()

                Text(dependency.license)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }

            Text(dependency.author)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Data

private let directDependencies: [Dependency] = [
    Dependency("swift-argument-parser", author: "Apple Inc.", license: "Apache 2.0",
               url: "https://github.com/apple/swift-argument-parser"),
    Dependency("swift-markdown", author: "Apple Inc.", license: "Apache 2.0",
               url: "https://github.com/swiftlang/swift-markdown"),
    Dependency("Yams", author: "JP Simard", license: "MIT",
               url: "https://github.com/jpsim/Yams"),
    Dependency("swift-cjk-sqlite", author: "Maho", license: "MIT",
               url: "https://github.com/mahopan/swift-cjk-sqlite"),
    Dependency("swift-embeddings", author: "Jan Krukowski", license: "MIT",
               url: "https://github.com/jkrukowski/swift-embeddings"),
    Dependency("swift-github-api", author: "Maho", license: "MIT",
               url: "https://github.com/mahopan/swift-github-api"),
]

private let transitiveDependencies: [Dependency] = [
    Dependency("swift-cmark", author: "John MacFarlane", license: "MIT",
               url: "https://github.com/swiftlang/swift-cmark"),
    Dependency("swift-collections", author: "Apple Inc.", license: "Apache 2.0",
               url: "https://github.com/apple/swift-collections"),
    Dependency("swift-crypto", author: "Apple Inc.", license: "Apache 2.0",
               url: "https://github.com/apple/swift-crypto"),
    Dependency("swift-asn1", author: "Apple Inc.", license: "Apache 2.0",
               url: "https://github.com/apple/swift-asn1"),
    Dependency("swift-transformers", author: "Hugging Face", license: "Apache 2.0",
               url: "https://github.com/huggingface/swift-transformers"),
    Dependency("swift-jinja", author: "Hugging Face", license: "Apache 2.0",
               url: "https://github.com/huggingface/swift-jinja"),
    Dependency("swift-safetensors", author: "Jan Krukowski", license: "MIT",
               url: "https://github.com/jkrukowski/swift-safetensors"),
    Dependency("swift-sentencepiece", author: "Jan Krukowski", license: "MIT",
               url: "https://github.com/jkrukowski/swift-sentencepiece"),
    Dependency("yyjson", author: "YaoYuan (ibireme)", license: "MIT",
               url: "https://github.com/ibireme/yyjson"),
]

#Preview {
    NavigationStack {
        AcknowledgmentsView()
    }
}
