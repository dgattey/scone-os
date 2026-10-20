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

## Building and running

Sconeos builds with [DylKit](Packages/DylKit), Dylan's shared app framework. `DylApp.toml` configures the app, and the `./run` shim runs DylKit's `devkit` and `release-kit` tools. Builds land in `build/`, never `/Applications`, and launch in the background without taking focus.

```bash
./run dev bootstrap                         # resolve packages, generate icons, install the pre-push hook
./run dev relaunch                          # build build/Sconeos.app and open it behind the current app
./run dev capture --appearance dark         # relaunch and screenshot the window into build/captures/
./run dev ios --run                         # build for the iOS Simulator and launch it headless
./run dev checks                            # SwiftLint, dyl-lint and the release checks
./run dev --help
```

Agent skills and the always-applied rule come from `Packages/DylKit/skills` and `Packages/DylKit/rules`. Edit them there and run `./run dev skills sync` to refresh `.cursor/`. Swift is formatted with `swift format` using the root `.swift-format` (4 spaces, 120 columns).

## Code signing and Sparkle updates

`release-kit` bundles the app, strips build-machine rpaths, embeds `Sparkle.framework`, and signs everything inside-out (`Installer.xpc`, `Downloader.xpc` with its entitlements preserved, `Autoupdate`, `Updater.app`, then `Sconeos.app` with `Sconeos.local.entitlements`). Releases are signed ad-hoc with the designated requirement pinned to the bundle identifier, so Sparkle accepts each build as the same app. Untrusted self-signed certificates get killed by `syspolicyd`/`amfid` on quarantined launches.

To rotate or generate a Sparkle EdDSA keypair (storing the private key in the macOS login Keychain and writing the public key to `sparkle-public-key.txt`):

```bash
./scripts/generate-sparkle-key.sh
```

## Testing

Run the app's and DylKit's tests, the checks and the site's typecheck, as CI does:

```bash
./run dev verify
```
