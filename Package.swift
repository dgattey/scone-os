// swift-tools-version: 6.0
import PackageDescription

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
        // macOS auto-update (canonical for non-App-Store apps). Linked only into the macOS shell.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        .target(name: "SconeDomain"),
        .target(name: "SonosProtocolBoundary", dependencies: ["SconeDomain"]),
        .target(name: "SpotifyBridge", dependencies: ["SconeDomain"]),
        .target(name: "SconeStore", dependencies: ["SconeDomain", "SonosProtocolBoundary", "SpotifyBridge"]),
        .target(name: "SconeUI", dependencies: ["SconeStore", "SconeDomain", "SpotifyBridge"]),
        .executableTarget(
            name: "SconeosApp",
            dependencies: [
                "SconeUI",
                "SconeStore",
                "SconeDomain",
                "SpotifyBridge",
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
            ],
            linkerSettings: [
                // build-macos.sh embeds Sparkle.framework under Contents/Frameworks.
                .unsafeFlags(
                    ["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"],
                    .when(platforms: [.macOS])
                ),
            ]
        ),
        .testTarget(name: "SconeKitTests", dependencies: ["SconeDomain", "SonosProtocolBoundary", "SpotifyBridge", "SconeStore"]),
    ]
)
