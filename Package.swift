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
        .executable(name: "SconeOS", targets: ["SconeOSApp"]),
    ],
    targets: [
        .target(name: "SconeDomain"),
        .target(name: "SonosProtocolBoundary", dependencies: ["SconeDomain"]),
        .target(name: "SpotifyBridge", dependencies: ["SconeDomain"]),
        .target(name: "SconeStore", dependencies: ["SconeDomain", "SonosProtocolBoundary", "SpotifyBridge"]),
        .target(name: "SconeUI", dependencies: ["SconeStore", "SconeDomain", "SpotifyBridge"]),
        .executableTarget(name: "SconeOSApp", dependencies: ["SconeUI", "SconeStore", "SconeDomain", "SpotifyBridge"]),
        .testTarget(name: "SconeKitTests", dependencies: ["SconeDomain", "SonosProtocolBoundary", "SpotifyBridge", "SconeStore"]),
    ]
)
