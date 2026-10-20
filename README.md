# Sconeos

Sconeos is a native Swift 6 spatial audio controller for Sonos households and Spotify on macOS and iOS.

## Architecture

Sconeos is structured as a single Swift Package (`SconeKit`) with strict module boundaries.

- `SconeDomain` defines pure value types for speakers (`SpeakerModel`, `BondedSatellite`, `BatteryTelemetry`), 21-step discrete volumes (`DiscreteVolume`), spatial room placement (`FloorplanNode`, `FloorLevel`), and grouping presets.
- `SonosProtocolBoundary` handles SSDP and mDNS speaker discovery, UPnP SOAP topology and transport commands, and device battery/surround telemetry.
- `SpotifyBridge` manages PKCE OAuth 2.0 authentication in Keychain, fetches track metadata and queues from the Spotify Web API, and resolves Spotify URIs for direct Sonos UPnP handoff.
- `SconeStore` coordinates household discovery, optimistic command execution, floorplan persistence, and preset state on `@MainActor`.
- `SconeUI` provides the shared SwiftUI interface across macOS and iOS, including `FloorplanMapView`, `SpeakerSilhouetteView`, `SconeBrandEmblem`, `GroupDetailView`, `NowPlayingDock`, and `SconeSettingsView`.
- `SconeosApp` is the executable entry point and wires Sparkle 2 auto-updates on macOS.

## Requirements

- macOS 14.0+ or iOS 17.0+
- Swift 6.0 / Xcode 16+

## Building and Running on macOS

Build, sign, and launch `Sconeos.app` in release configuration:

```bash
./scripts/run-macos.sh
```

To package `build/Sconeos.app` without launching:

```bash
./scripts/build-macos.sh release
```

## Building for iOS Simulator

Compile the shared `SconeUI` and `SconeosApp` targets for iOS Simulator:

```bash
xcodebuild -scheme Sconeos \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

## Code Signing and Sparkle Updates

`scripts/build-macos.sh` embeds `Sparkle.framework` and signs all nested XPC services (`Installer.xpc`, `Downloader.xpc`, `Autoupdate`, `Updater.app`) inside-out before signing `Sconeos.app` with `Sconeos.local.entitlements`.

`scripts/lib/signing.sh` signs ad-hoc (`-`) unless `SCONEOS_SIGN_IDENTITY` names a real identity. Untrusted self-signed certificates get killed by `syspolicyd`/`amfid` on quarantined launches, so releases stay ad-hoc.

To rotate or generate a Sparkle EdDSA keypair (storing the private key in the macOS login Keychain and writing the public key to `sparkle-public-key.txt`):

```bash
./scripts/generate-sparkle-key.sh
```

## Testing

Run the full unit test suite:

```bash
swift test
```
