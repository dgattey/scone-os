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
    ],
    targets: [
        .target(name: "SconeDomain"),
        .target(name: "SonosProtocolBoundary", dependencies: ["SconeDomain"]),
        .target(name: "SpotifyBridge", dependencies: ["SconeDomain"]),
        .target(name: "SconeStore", dependencies: ["SconeDomain", "SonosProtocolBoundary", "SpotifyBridge"]),
        // Stands in for the Xcode app target. In the real repo the app lives outside this package,
        // so `package`-scoped initializers (GroupID, Topology, HouseholdSnapshot) are unreachable from views.
        .target(name: "UsageSketch", dependencies: ["SconeStore", "SconeDomain", "SpotifyBridge"]),
    ]
)
