// swift-tools-version: 6.0
import PackageDescription

let dylCore: Target.Dependency = .product(name: "DylCore", package: "dyl-kit")
let dylUI: Target.Dependency = .product(name: "DylUI", package: "dyl-kit")

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
        .package(url: "https://github.com/dgattey/dyl-kit", from: "0.2.1"),
    ],
    targets: [
        .target(name: "SconeDomain"),
        .target(name: "SonosProtocolBoundary", dependencies: ["SconeDomain", dylCore]),
        .target(name: "SpotifyBridge", dependencies: ["SconeDomain", dylCore]),
        .target(name: "SconeStore", dependencies: ["SconeDomain", "SonosProtocolBoundary", "SpotifyBridge"]),
        .target(name: "SconeUI", dependencies: ["SconeStore", "SconeDomain", "SpotifyBridge", dylCore, dylUI]),
        // release-kit's bundler adds the @executable_path/../Frameworks rpath for the embedded Sparkle.framework.
        .executableTarget(
            name: "SconeosApp",
            dependencies: [
                "SconeUI",
                "SconeStore",
                "SconeDomain",
                "SpotifyBridge",
                dylUI,
                .product(name: "DylUpdates", package: "dyl-kit"),
            ]
        ),
        .testTarget(name: "SconeKitTests", dependencies: ["SconeDomain", "SonosProtocolBoundary", "SpotifyBridge", "SconeStore"]),
    ]
)
