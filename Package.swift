// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "maho-notes",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "MahoNotesKit", targets: ["MahoNotesKit"]),
        .executable(name: "mn", targets: ["mn"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3"),
        .package(url: "https://github.com/mahopan/swift-cjk-sqlite.git", from: "0.2.0"),
        .package(url: "https://github.com/jkrukowski/swift-embeddings.git", from: "0.0.26"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
    ],
    targets: [
        .target(
            name: "MahoNotesKit",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "CJKSQLite", package: "swift-cjk-sqlite"),
                .product(name: "Embeddings", package: "swift-embeddings"),
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .executableTarget(
            name: "mn",
            dependencies: [
                "MahoNotesKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "MahoNotesKitTests",
            dependencies: [
                "MahoNotesKit",
                .product(name: "CJKSQLite", package: "swift-cjk-sqlite"),
            ]
        ),
    ]
)
