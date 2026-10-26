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

Sconeos builds with [DylKit](https://github.com/dgattey/dyl-kit), Dylan's shared app framework. `DylApp.toml` configures the app, and `swift run devkit`, `swift run release-kit` and `swift run dyl-lint` run DylKit's tools. Setup, building, tests, background launches, screenshots and the iOS Simulator are in DylKit's [`apple-dev-loop`](https://github.com/dgattey/dyl-kit/blob/main/skills/apple-dev-loop/SKILL.md) skill. Releasing is in [`apple-release`](https://github.com/dgattey/dyl-kit/blob/main/skills/apple-release/SKILL.md). Both ship in the DylKit Cursor plugin.

## Code signing and Sparkle updates

`release-kit` bundles the app, strips build-machine rpaths, embeds `Sparkle.framework`, and signs everything inside-out (`Installer.xpc`, `Downloader.xpc` with its entitlements preserved, `Autoupdate`, `Updater.app`, then `Sconeos.app` with `Sconeos.local.entitlements`). Releases are signed ad-hoc with the designated requirement pinned to the bundle identifier, so Sparkle accepts each build as the same app. Untrusted self-signed certificates get killed by `syspolicyd`/`amfid` on quarantined launches.

To generate the Sparkle EdDSA keypair (storing the private key in the login Keychain account `com.sconeos.SconeOS`, not Sparkle's shared `ed25519` one, and writing the public key to `sparkle-public-key.txt`):

```bash
./scripts/generate-sparkle-key.sh
```

While `sparkle-public-key.txt` names a key the Keychain account doesn't hold, the script refuses to generate a new one. Import the existing key into the account instead with `generate_keys --account com.sconeos.SconeOS -f <exported key>`, then delete the exported file. Run locally, `release-kit appcast` signs only with that Keychain account (or a file passed with `--ed-key-file`) and reads no other key files.

The download site in `server/` is a thin [`@dylkit/web`](https://github.com/dgattey/dyl-kit/tree/main/web) app that reads `DylApp.toml` and serves the latest release from the Blob store `[release] assets` names. CI for the site is the `site` workflow in `.github/workflows/site.yml`.
