// swift-tools-version: 6.0
import PackageDescription

let dylLint: [Target.PluginUsage] = [.plugin(name: "DylLintPlugin", package: "DylKit")]

let package = Package(
    name: "SconeKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SconeDomain", targets: ["SconeDomain"]),
        .library(name: "SonosProtocolBoundary", targets: ["SonosProtocolBoundary"]),
        .library(name: "SpotifyBridge", targets: ["SpotifyBridge"]),
        .library(name: "SconeStore", targets: ["SconeStore"]),
        .library(name: "SconeUI", targets: ["SconeUI"]),
        .executable(name: "Sconeos", targets: ["SconeosApp"]),
    ],
    dependencies: [
        .package(path: "Packages/DylKit")
    ],
    targets: [
        .target(name: "SconeDomain", plugins: dylLint),
        .target(
            name: "SonosProtocolBoundary",
            dependencies: ["SconeDomain", .product(name: "DylCore", package: "DylKit")],
            plugins: dylLint
        ),
        .target(
            name: "SpotifyBridge",
            dependencies: ["SconeDomain", .product(name: "DylCore", package: "DylKit")],
            plugins: dylLint
        ),
        .target(
            name: "SconeStore",
            dependencies: [
                "SconeDomain", "SonosProtocolBoundary", "SpotifyBridge",
                .product(name: "DylCore", package: "DylKit"),
            ],
            plugins: dylLint
        ),
        .target(
            name: "SconeUI",
            dependencies: [
                "SconeStore", "SconeDomain", "SpotifyBridge",
                .product(name: "DylCore", package: "DylKit"),
                .product(name: "DylDesign", package: "DylKit"),
            ],
            plugins: dylLint
        ),
        .executableTarget(
            name: "SconeosApp",
            dependencies: [
                "SconeUI", "SconeStore", "SconeDomain", "SpotifyBridge",
                .product(name: "DylCore", package: "DylKit"),
                .product(name: "DylShell", package: "DylKit"),
                .product(name: "DylUpdates", package: "DylKit"),
            ],
            plugins: dylLint
        ),
        .testTarget(
            name: "SconeKitTests",
            dependencies: [
                "SconeDomain", "SonosProtocolBoundary", "SpotifyBridge", "SconeStore",
                .product(name: "DylCore", package: "DylKit"),
            ]
        ),
    ]
)
