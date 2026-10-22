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
- Swift 6 with the Xcode 26.5 toolchain. There's no Xcode project: Sconeos builds with SwiftPM.

## Building and running

Sconeos builds with [DylKit](https://github.com/dgattey/dyl-kit), Dylan's shared app framework. `DylApp.toml` configures the app, and the `./run` shim runs DylKit's `devkit` and `release-kit` tools. Setup, building, tests, background launches, screenshots and the iOS Simulator are in DylKit's [`apple-dev-loop`](https://github.com/dgattey/dyl-kit/blob/main/skills/apple-dev-loop/SKILL.md) skill. Releasing is in [`apple-release`](https://github.com/dgattey/dyl-kit/blob/main/skills/apple-release/SKILL.md). Both ship in the DylKit Cursor plugin.

## Code signing and Sparkle updates

`release-kit` bundles the app, strips build-machine rpaths, embeds `Sparkle.framework`, and signs everything inside-out (`Installer.xpc`, `Downloader.xpc` with its entitlements preserved, `Autoupdate`, `Updater.app`, then `Sconeos.app` with `Sconeos.local.entitlements`). Releases are signed ad-hoc with the designated requirement pinned to the bundle identifier, so Sparkle accepts each build as the same app. Untrusted self-signed certificates get killed by `syspolicyd`/`amfid` on quarantined launches.

To rotate or generate a Sparkle EdDSA keypair (storing the private key in the macOS login Keychain and writing the public key to `sparkle-public-key.txt`):

```bash
./scripts/generate-sparkle-key.sh
```

The download site in `server/` is a thin [`@dylkit/web`](https://github.com/dgattey/dyl-kit/tree/main/web) app that reads `DylApp.toml` and serves the latest release from the Blob store `[release] assets` names. CI for the site is the `site` workflow in `.github/workflows/site.yml`.
