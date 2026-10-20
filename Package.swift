// swift-tools-version: 6.0
import PackageDescription

let dylLint: [Target.PluginUsage] = [.plugin(name: "DylLintPlugin", package: "DylKit")]
let dylCore: Target.Dependency = .product(name: "DylCore", package: "DylKit")

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
        .package(path: "Packages/DylKit"),
        // macOS auto-update (canonical for non-App-Store apps). Linked only into the macOS shell.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        .target(name: "SconeDomain", plugins: dylLint),
        .target(name: "SonosProtocolBoundary", dependencies: ["SconeDomain", dylCore], plugins: dylLint),
        .target(name: "SpotifyBridge", dependencies: ["SconeDomain", dylCore], plugins: dylLint),
        .target(name: "SconeStore", dependencies: ["SconeDomain", "SonosProtocolBoundary", "SpotifyBridge"], plugins: dylLint),
        .target(name: "SconeUI", dependencies: ["SconeStore", "SconeDomain", "SpotifyBridge", dylCore], plugins: dylLint),
        .executableTarget(
            name: "SconeosApp",
            dependencies: [
                "SconeUI",
                "SconeStore",
                "SconeDomain",
                "SpotifyBridge",
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
            ],
            // release-kit's bundler adds the @executable_path/../Frameworks rpath for the embedded Sparkle.framework.
            plugins: dylLint
        ),
        .testTarget(name: "SconeKitTests", dependencies: ["SconeDomain", "SonosProtocolBoundary", "SpotifyBridge", "SconeStore"]),
    ]
)
