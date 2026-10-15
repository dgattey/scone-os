# Sconeos architecture, candidate 1

One runner's candidate for the architect arena. The full type sketch is a SwiftPM package at `/tmp/arena-scone-os/candidate-1/sketch/`. It builds under the Swift 6 language mode with strict concurrency and `-warnings-as-errors`, and every body is `fatalError("not implemented")` or a `// TODO` with pseudocode. The `UsageSketch` target holds the SwiftUI call sites from the usage section, so the compiler checks the usage against the types. `/tmp/arena-scone-os/candidate-1/fence-check/` is a separate package that tries to mint a `GroupID` and a `Topology` from outside the package. It fails to build, which backs decision 1 below.

## Problem

Sconeos is a macOS and iOS SwiftUI app that drives one Sonos S2 household over the LAN with no Sonos cloud. It groups rooms, applies saved presets, sets volume, controls transport, hands off Spotify, and draws the rooms on a floorplan, including while the household is unreachable. The PoC trace and the spatial probe set constraints that make the shape non-obvious.

- Wire group IDs are not identities. Ungrouping Bedroom changed its group ID from `RINCON_542A1B5F088401400:2737252947` to `RINCON_542A1B5F088401400:2737252948`. Presets and view identity must key on speakers.
- Coordinator-only actions fail on members. `GetGroupVolume` and `SetGroupVolume` on a grouped member returned HTTP 500. Transport and queue actions follow the same rule.
- The two Era 100 surrounds (`.72`, `.83`) answer SSDP and have their own RINCON ids, but they are `Invisible="1"` satellites behind the Beam. They must never appear as rooms or command targets.
- Regrouping is eventually consistent. The PoC converged in 420 to 695 ms and had to poll `GetZoneGroupState` to know it was done.
- Telemetry is irregular text. A `0 dBm` noise floor means not measured. RF peer lines name radio MACs, which are the base MAC or base+1. Peer strength moves between reads.
- Speakers report any integer volume (Kitchen read 24). The product allows 5% detents only.
- iOS has no `XMLDocument`, and SSDP multicast on iOS needs an entitlement Apple grants by request.
- The PoC never exercised Spotify on Sonos. A `x-sonos-spotify:` URI needs a household-specific account serial.

## Usage (caller's view)

### Quickstart

Sconeos has three library modules a caller touches and one domain module they all share. A view imports `SconeStore` and `SconeDomain`, reads `store.state`, and sends `SonosCommand` values. The one way to change the household is `store.send(_:)`.

```swift
import SconeDomain
import SconeStore
import SpotifyBridge
import SwiftUI

struct SconeosApp: App {
    @State private var spotify: SpotifyBridge
    @State private var store: SconeStore

    init() {
        let spotify = SpotifyBridge(clientID: "<spotify client id>", redirectURI: URL(string: "sconeos://spotify-callback")!)
        _spotify = State(initialValue: spotify)
        _store = State(initialValue: SconeStore.live(spotify: spotify))   // reads the 3 files before returning
    }

    var body: some Scene {
        WindowGroup {
            HouseView()
                .environment(store)
                .environment(spotify)
                .task { await store.run() }                                // consumes live snapshots until cancelled
        }
    }
}
```

The first frame already shows the cached house, because `SconeStore.live` reads the three files synchronously. `run()` then reconciles live sweeps into the same state.

### Call site 1. Preset pills

```swift
ForEach(store.state.presets) { preset in
    Button(preset.name) { store.send(.applyPreset(preset)) }
        .buttonStyle(.borderedProminent)
        .tint(store.state.isActive(preset) ? .accentColor : .secondary)
}
```

`isActive` asks the preset's `TopologyTarget` whether the projected topology satisfies it. The planner uses the same predicate, so a pill lights exactly when applying it would send nothing. It lights the moment it is tapped, because the projection includes in-flight commands.

### Call site 2. A group card

```swift
Text(group.displayName)                                            // "Kitchen + Dining"
Button(isPlaying ? "Pause" : "Play") {
    store.send(.playPause(isPlaying ? .pause : .play, group: group.id))
}
Button("Next") { store.send(.nextTrack(group: group.id)) }
    .disabled(!canSkip)                                            // NowPlayingTrack.queuePosition == nil
VolumeDial(volume: group.volume) { store.send(.setVolume($0, for: .group(group.id))) }
ForEach(group.speakers) { speaker in
    VolumeDial(volume: speaker.volume) { store.send(.setVolume($0, for: .speaker(speaker.id))) }
}
Button("Play from Spotify here") { store.handOffSpotify(to: group.id) }
Button("Save as preset") { store.savePreset(from: group.id) }      // named "Kitchen + Dining" by default

struct VolumeDial: View {
    let volume: DiscreteVolume
    let onChange: (DiscreteVolume) -> Void
    var body: some View {
        HStack {
            Button("-") { onChange(volume.stepped(by: -1)) }
            Slider(value: Binding(get: { volume.fraction },
                                  set: { let v = DiscreteVolume(snappingFraction: $0); if v != volume { onChange(v) } }),
                   in: 0...1, step: 0.05)
            Button("+") { onChange(volume.stepped(by: 1)) }
        }
    }
}
```

A view cannot pass a grouped member or a satellite to `.playPause` or `.setVolume(_, for: .group)`. Those take a `GroupID`, and views cannot construct one.

### Call site 3. The floorplan

```swift
ForEach(store.state.floorplan) { node in
    RoomNode(node: node)                                   // grayed when node.speaker.reachability is .offline
        .position(x: node.coordinate.x * size.width, y: node.coordinate.y * size.height)
        .gesture(DragGesture(coordinateSpace: .named("floorplan")).onEnded { drag in
            store.moveRoom(node.id, to: RoomCoordinate(clampingX: drag.location.x / size.width,
                                                       y: drag.location.y / size.height))
        })
        .contextMenu {
            ForEach(store.state.groups.filter { $0.id != node.group }) { group in
                Button("Join \(group.displayName)") { store.send(.group(member: node.id, intoCoordinator: group.id)) }
            }
            Button("Leave group") { store.send(.ungroup(member: node.id)) }.disabled(node.group == nil)
            if node.placement == .pinned { Button("Reset position") { store.resetRoom(node.id) } }
        }
}
```

### Call site 4. The boundary without the store (a CLI or an integration test)

```swift
let sonos = SonosHousehold(seedIPs: ["192.168.68.58"])
for await snapshot in sonos.snapshots() {
    guard let kitchen = snapshot.groups.first(where: { $0.coordinator.roomName == "Kitchen Speaker" }) else { continue }
    let preset = PresetPill(capturing: kitchen)               // name defaults to kitchen.displayName
    let outcome = try await sonos.send(.applyPreset(preset))  // .alreadySatisfied: zero SOAP calls sent
    break
}
```

## Shape

### Module map

```
scone-os/
  Sconeos.xcodeproj               multiplatform app target: SwiftUI views only
  Packages/SconeKit/Package.swift
    SconeDomain                   pure value types and pure algorithms. Depends on Foundation only.
      Identity.swift              SpeakerUUID, GroupID
      Volume.swift                DiscreteVolume, VolumeTarget
      Speaker.swift               Speaker, SpeakerModel, BondedSatellite, SatelliteRole, BatteryTelemetry, ReachabilityState
      Topology.swift              Topology, TopologyStep, TopologyTarget (predicate + planner), TopologyPlan
      Playback.swift              PlayPause, PlaybackState, NowPlaying, NowPlayingTrack
      Group.swift                 SonosGroup, RoomNaming
      Floorplan.swift             RoomCoordinate, RFPeerMatrix, FloorplanNode, Placement, FloorplanLayout
      Preset.swift                PresetID, PresetPill
      Spotify.swift               SpotifyURI, SpotifyTrackMetadata, SpotifyTrackContext
      Command.swift               SonosCommand, CommandOutcome, SonosCommandError
      Household.swift             HouseholdSnapshot, GroupStatus
    SonosProtocolBoundary         depends on SconeDomain. One public type.
      SonosHousehold.swift        public actor: init(seedIPs:), snapshots(), send(_:). AddressBook.
      SOAP.swift                  UPnPService table, SOAPClient, XMLNode (DOM over XMLParser)
      TopologyService.swift       ZoneGroupState parse (satellite folding, VanishedDevices), TopologyStep -> SOAP
      TransportService.swift      AVTransport + RenderingControl parse and requests, volume snapping
      TelemetryService.swift      model table, device description, ath_rincon/status, batterystatus
      Discovery.swift             SSDP request and parse, Bonjour _sonos._tcp, seed stream
      SpotifyOnSonos.swift        account discovery, x-sonos-spotify URI, DIDL-Lite, enqueue sequence
    SpotifyBridge                 depends on SconeDomain. One public type plus its error.
      SpotifyBridge.swift         @MainActor @Observable: connect, disconnect, currentContext, pauseSourcePlayback
      WebAPI.swift                PKCE, TokenVault (Keychain), currently-playing, pause
      AppleScriptSource.swift     #if os(macOS): osascript script and its pure output parser
    SconeStore                    depends on all three
      SconeState.swift            the reducer: stored state, pure transitions, derived reads, optimistic projection
      SconeStore.swift            @MainActor @Observable shell: run, send, handOffSpotify, user-data intents, file writes
      SconeFiles.swift            FileSlot (3 typed slots), file formats, synchronous atomic load and save
      Ports.swift                 SonosControl, SpotifySource (for test fakes)
```

The dependency graph is a diamond with no cycles. `SconeDomain` sits at the bottom. `SonosProtocolBoundary` and `SpotifyBridge` sit beside each other and never import each other. `SpotifyTrackContext` and `SpotifyURI` live in the domain so the bridge can produce them and the boundary can consume them. `SconeStore` sits on top, and the app target sits above it. Tracing any user action takes at most three files: the view, `SconeStore.swift` plus `SconeState.swift`, and `SonosHousehold.swift`, per minimize-reader-load.

### Core data structures

These are listed in order of how much code they delete.

**`Topology` is a member-to-coordinator map.** `[SpeakerUUID: SpeakerUUID]`, where each coordinator maps to itself. A dictionary key cannot repeat, so a speaker in two groups cannot be written down. The package-only initializer rejects a value that does not map to itself, so a group cannot point at a missing coordinator. The PoC's `restore_topology` built exactly this map (`current_coord_by_member`) to plan its moves. Every access pattern runs on it directly. The planner asks "who coordinates X", the floorplan asks "which group is this room in", and `groups` derives the grouped view on demand, per foundational-thinking.

**`TopologyTarget` turns commands into end states.** `group(member:intoCoordinator:)` becomes `.memberOf`, `ungroup(member:)` becomes `.standalone`, and `applyPreset` becomes `.exactGroup`. Each target owns its predicate (`isSatisfied(by:ignoring:)`) and its planner (`plan(from:)`). Planning against a topology that already satisfies the target yields no steps, so all three commands are idempotent by construction and a crash halfway is fixed by planning again from a fresh read, per make-operations-idempotent. The same `Topology.applying(_:)` simulates plans in the boundary and projects in-flight commands in the store.

**`GroupID` is the coordinator.** The boundary drops the reminted numeric suffix. Group identity in SwiftUI is then stable across regroups, and presets cannot accidentally key on a value that changes. Only the package mints `GroupID`, from a parsed topology. Holding one is proof that its speaker coordinated a group at parse time, which is what transport, group volume, and queue actions need, per type-system-discipline.

**`DiscreteVolume` is a 21-case enum.** `DiscreteVolume(rawValue: 23)` is nil, and no stored property, file, or command can hold 23. Continuous values enter through two snapping initializers, called in exactly two places, the wire parse in `TransportService.parseVolume` and the slider binding. Detents also bound a slider drag to at most 20 commands.

**Satellites are payload, not speakers.** `SpeakerModel.beamHt(satellites: [BondedSatellite])`. The topology parser folds `<Satellite Invisible="1">` children into their soundbar. `Speaker`, `Topology`, `SonosGroup`, and `PresetPill` therefore cannot contain a satellite, and the filtering rule from the PoC ("filter out `X-RINCON-PROXY`") lives in one parser instead of every list, per model-the-domain. Battery telemetry rides on `.move(battery:)` for the same reason. An Era 100 with a battery reading cannot be built.

**`ReachabilityState` is reconciled, never tracked.** The boundary only emits speakers it saw, all `.online(ip:rssi:noiseFloor:)`, with `0 dBm` mapped to nil. The store keeps `known`, every speaker ever seen in last-known `.offline(lastKnownIP:lastSeenAt:)` form, and displays `known` overlaid by the live snapshot. `known` is also exactly what `cached-speakers.json` holds, so loading the cache needs no conversion and every cached speaker starts offline until a sweep sees it.

**`PlaybackState` carries its own clock.** `.playing(NowPlaying, elapsed:, sampledAt:)` lets a `TimelineView` interpolate progress without per-second polling. `NowPlayingTrack.queuePosition` is nil exactly when skip has no meaning (radio, line-in, TV), so the skip buttons disable from the type instead of from a source-type check.

**`RFPeerMatrix` stores quantized bands.** Raw peer strength moved between probe reads. Three bands (weak, moderate, strong) on an unordered `SpeakerPair` key absorb that, so an unchanged house yields an equal matrix, and the deterministic layout yields equal coordinates. Rooms do not jitter on the floorplan between sweeps, per experience-first.

### Data flow

The read path has three steps.

1. `SonosHousehold`'s sweep loop polls topology, transport, and volume every 2 s and telemetry every 30 s. It parses everything into domain types and yields a `HouseholdSnapshot` only when it differs from the last one.
2. `SconeStore.run()` calls `state.absorb(snapshot)`, which updates `known`, `live`, `rf`, and the layout memo, then writes whichever file slice changed.
3. Views read derived properties: `state.groups`, `state.floorplan`, `state.isActive(_:)`, `state.connection`. None of them is stored.

The write path has four steps.

1. A view calls `store.send(.setVolume(.v30, for: .group(id)))`.
2. `state.begin(_:)` records the command as in flight. Derived reads now project it, so the slider stays at 30.
3. `SonosHousehold.send` plans or routes, sends SOAP to the right speaker, refreshes the slice it touched, yields the confirming snapshot, and returns.
4. The store has already absorbed that snapshot, so `state.finish(_:with:)` drops the projection with no flicker. A partial or failed outcome becomes an alert.

The live household is owned by the boundary and the person's pending intents are owned by the store. They merge only at read time in `projected`, per separate-before-serializing-shared-state. Neither writes the other's field, so there is no "snap back to the old value" race between a slow sweep and a fast tap, and no timer has to expire the overlay.

### Load-bearing decisions

1. **Package-scoped construction for proof-carrying types.** `GroupID`, `Topology`, `HouseholdSnapshot`, `SonosGroup`, and `FloorplanNode` have `package` initializers. The app target lives outside the package, so a view cannot forge a coordinator or a snapshot. The fence-check package confirms that the build fails with "initializer is inaccessible due to 'package' protection level". This answers the importable-internals red flag with the compiler instead of a convention.
2. **One command enum and one `send`.** `SonosCommand` cases carry the requested labels (`.group(member:intoCoordinator:)`, `.setVolume(_:for:)`, and so on). The store's `projecting(_:)` switch is exhaustive with no `default`, so a new command does not compile until someone decides how it looks before the speakers confirm, per encode-lessons-in-structure.
3. **Idempotence for commands that are not naturally idempotent.** `playPause` takes the desired state, because a retried toggle undoes itself. `nextTrack` and `previousTrack` compute an absolute `Seek(TRACK_NR, n)` once per command, so a retried request lands on the same track. `enqueueAndPlaySpotify` is a no-op when the coordinator already plays that URI. Per make-operations-idempotent. The signature cost is one extra argument on `playPause`.
4. **Read-your-writes from the boundary.** `send` returns only after it yielded a snapshot reflecting the command. This moves the hard part (knowing when the household caught up) into the module that polls the household, and reduces the store's optimistic state to "commands in flight".
5. **Discovery only finds a seed.** `GetZoneGroupState` from any one speaker names every member and its IP. Cached last-known IPs are tried first, so a warm launch needs no multicast at all. SSDP and Bonjour `_sonos._tcp` run only when no seed answers. This also contains the iOS multicast-entitlement risk.
6. **Pure reducer, thin shell, no effect enum.** `SconeState` holds every rule as `mutating` functions with no I/O, clock, or tasks. `SconeStore` is about 100 lines that feed it events and write files, per boundary-discipline. Every stored field names its single writer in a doc comment.
7. **Pins persist, inference derives.** `floorplan-positions.json` holds only rooms the person dragged. Inferred positions come from `FloorplanLayout.infer` over the cached RF matrix, memoized on the room set and matrix. Pins do not feed the solve, so dragging one room never moves another.
8. **Three files, split by writer and by what a loss costs.** The disposable cache is deleted on a decode failure. User files are renamed to `<name>.corrupt-<timestamp>` and the app starts with an alert, so nothing overwrites a user file before anyone read it. `FileSlot<Content>` ties each file name to its content type, so presets cannot be written into the cache slot. `persistChangedSlices()` is the only writer. It compares per-slice projections with what it last wrote, so call sites never remember to save.
9. **The boundary is organized by service knowledge.** `TopologyService` owns both the `ZoneGroupState` parse and the regroup requests. `TransportService` owns both the playback parse and transport requests. No `Parsers/` and `Commands/` folders repeat each service's rules in two places.

### Interface depth

`SonosHousehold` has three public members: `init(seedIPs:configuration:)`, `snapshots()`, and `send(_:)`. Behind them sit SSDP and Bonjour discovery, the address book, six UPnP services, SOAP envelopes, two levels of escaped XML (envelope, then `ZoneGroupState` or DIDL-Lite), three `/status` text formats, the model-number table, satellite folding, radio-MAC resolution, the liveness debounce, coordinator routing, per-coordinator ordering, convergence polling, Spotify account discovery, and DIDL rendering. No SOAP, XML, URL, or HTTP type appears on the public surface.

`SpotifyBridge` has five public members: `authorization`, `connect(using:)`, `disconnect()`, `currentContext()`, and `pauseSourcePlayback()`. Behind them sit PKCE, the Keychain vault, token refresh, the Web API, `osascript`, the AppleScript output parser, and the choice of source. The caller never picks a source.

`SconeStore` has `state`, `run()`, `send(_:)`, `handOffSpotify(to:)`, and six one-line user-data intents (move, reset, save, rename, delete preset, dismiss alert). The intents exist because each one writes a file slice. Sonos commands do not get per-command methods, so the store is not a pass-through layer over the boundary.

### What it deliberately does not do

GENA event subscriptions (it polls), mute, EQ, queue browsing, stereo-pair modeling, multiple households, per-preset volumes, preset sync across devices, and background operation on iOS.

## Type and signature sketch

The authoritative version is the compiling package. This is the public surface condensed, bodies omitted.

### SconeDomain

```swift
public struct SpeakerUUID: Hashable, Comparable, Sendable, Codable, CodingKeyRepresentable {
    public let rawValue: String
    public init?(rawValue: String)                          // ^RINCON_[0-9A-F]{12}[0-9]{5}$
    package var macHex: Substring
}

public struct GroupID: Hashable, Comparable, Sendable {
    public let coordinator: SpeakerUUID
    package init(coordinator: SpeakerUUID)
}

public enum DiscreteVolume: Int, CaseIterable, Comparable, Codable, Sendable {
    case v0 = 0, v5 = 5, /* every multiple of 5 */ v100 = 100
    public init(snappingPercent: Int)                       // 22 -> v20, 23 -> v25, clamped
    public init(snappingFraction: Double)                   // non-finite -> v0
    public func stepped(by detents: Int) -> DiscreteVolume  // clamped at both ends
    public var percent: Int { get }
    public var fraction: Double { get }
}

public enum VolumeTarget: Hashable, Sendable {
    case speaker(SpeakerUUID)                               // RenderingControl on that speaker
    case group(GroupID)                                     // GroupRenderingControl on the coordinator
}

public struct Speaker: Identifiable, Hashable, Sendable, Codable {
    public let id: SpeakerUUID
    public let roomName: String                             // ZoneName verbatim
    public let model: SpeakerModel
    public let reachability: ReachabilityState
    public let volume: DiscreteVolume
    public func with(volume: DiscreteVolume) -> Speaker
    public func with(reachability: ReachabilityState) -> Speaker
}

public enum SpeakerModel: Hashable, Sendable, Codable {
    case era100                                             // S39
    case era300                                             // S41
    case symfoniskBookshelf                                 // S33
    case beamHt(satellites: [BondedSatellite])              // S31
    case move(battery: BatteryTelemetry?)                   // S17
    case unrecognized(modelNumber: String, displayName: String)
    public var battery: BatteryTelemetry? { get }
    public var satellites: [BondedSatellite] { get }
}

public struct BondedSatellite: Identifiable, Hashable, Sendable, Codable {
    public let id: SpeakerUUID
    public let role: SatelliteRole                          // .rearLeft (LR,LTR), .rearRight (RR,RTR), .subwoofer (SW)
    public let linkQuality: Int?                            // soundbar RX RSSI AVG (probe: 62 and 62)
}

public struct BatteryTelemetry: Hashable, Sendable, Codable {
    public let levelPercent: Int
    public let isOnCharger: Bool                            // PowerSource != BATTERY
    public let temperatureCelsius: Int?
    public let sampledAt: Date
}

public enum ReachabilityState: Hashable, Sendable, Codable {
    case online(ip: String, rssi: Int?, noiseFloor: Int?)
    case offline(lastKnownIP: String, lastSeenAt: Date)
    public var isOnline: Bool { get }
    public var ip: String { get }                           // current or last known; doubles as a seed
}

public struct Topology: Hashable, Sendable {
    package init?(coordinatorOf: [SpeakerUUID: SpeakerUUID])
    public static let empty: Topology
    public var speakers: Set<SpeakerUUID> { get }
    public var groups: [GroupID: Set<SpeakerUUID>] { get }  // members exclude the coordinator
    public func group(of speaker: SpeakerUUID) -> GroupID?
    public func applying(_ step: TopologyStep) -> Topology  // total
}

public enum TopologyStep: Hashable, Sendable {
    case makeStandalone(SpeakerUUID)                        // BecomeCoordinatorOfStandaloneGroup on the member
    case join(SpeakerUUID, coordinator: SpeakerUUID)        // SetAVTransportURI(x-rincon:<coordinator>) on the member
}

public enum TopologyTarget: Hashable, Sendable {
    case memberOf(GroupID, member: SpeakerUUID)
    case standalone(SpeakerUUID)
    case exactGroup(coordinator: SpeakerUUID, members: Set<SpeakerUUID>)
    public func isSatisfied(by: Topology, ignoring absent: Set<SpeakerUUID> = []) -> Bool
    public func plan(from: Topology) -> TopologyPlan
}

public enum TopologyPlan: Hashable, Sendable {
    case steps([TopologyStep], skipped: Set<SpeakerUUID>)  // [] means already satisfied
    case impossible(TopologyPlanFailure)                    // .coordinatorMissing, .groupDissolved
}

public enum PlayPause: Hashable, Sendable { case play, pause }

public enum PlaybackState: Hashable, Sendable {
    case stopped
    case paused(NowPlaying, elapsed: Duration)
    case playing(NowPlaying, elapsed: Duration, sampledAt: Date)
    public var nowPlaying: NowPlaying? { get }
    public func elapsed(at now: Date) -> Duration?
}

public enum NowPlaying: Hashable, Sendable {
    case track(NowPlayingTrack)
    case tvAudio                                            // x-sonos-htastream
    case stream(title: String?)                             // radio, line-in, anything without a queue
}

public struct NowPlayingTrack: Hashable, Sendable {
    public let title: String
    public let artist: String?
    public let album: String?
    public let artworkURL: URL?                             // absolute
    public let duration: Duration?
    public let queuePosition: Int?                          // nil disables skip
    public let spotifyURI: SpotifyURI?
}

public struct SonosGroup: Identifiable, Hashable, Sendable {
    public let id: GroupID
    public let coordinator: Speaker
    public let members: [Speaker]                           // excludes coordinator
    public let playback: PlaybackState
    public let volume: DiscreteVolume
    public let displayName: String                          // "Kitchen + Dining"
    public var speakers: [Speaker] { get }
    package init(...)
}

public enum RoomNaming {
    public static func shortName(_ zoneName: String, merged: Bool) -> String
    public static func groupName(coordinator: String, members: [String], onlineRoomCount: Int) -> String
}

public struct RoomCoordinate: Hashable, Sendable, Codable {
    public let x: Double                                    // 0...1, west to east
    public let y: Double                                    // 0...1, north to south
    public init(clampingX: Double, y: Double)               // decoding clamps too
}

public struct RFPeerMatrix: Hashable, Sendable, Codable {
    public enum Band: Int, Comparable, Codable { case weak = 1, moderate, strong }
    public static let empty: RFPeerMatrix
    public func band(_ a: SpeakerUUID, _ b: SpeakerUUID) -> Band?
    package mutating func record(_ a: SpeakerUUID, _ b: SpeakerUUID, from: Int, to: Int)
}

public enum Placement: Hashable, Sendable { case inferred, pinned }

public struct FloorplanNode: Identifiable, Hashable, Sendable {
    public let speaker: Speaker
    public let coordinate: RoomCoordinate
    public let placement: Placement
    public let group: GroupID?                              // nil while offline
}

public enum FloorplanLayout {
    public static func infer(rooms: [SpeakerUUID], matrix: RFPeerMatrix) -> [SpeakerUUID: RoomCoordinate]
}

public struct PresetID: Hashable, Sendable, Codable { public let rawValue: UUID }

public struct PresetPill: Identifiable, Hashable, Sendable, Codable {
    public let id: PresetID
    public let name: String
    public let coordinatorUUID: SpeakerUUID
    public let memberUUIDs: Set<SpeakerUUID>                // never contains coordinatorUUID, decoding included
    public init(id: PresetID = PresetID(), name: String, coordinatorUUID: SpeakerUUID, memberUUIDs: some Sequence<SpeakerUUID>)
    public init(capturing group: SonosGroup, name: String? = nil)
    public func renamed(_ name: String) -> PresetPill
    public var target: TopologyTarget { get }
}

public struct SpotifyURI: Hashable, Sendable, Codable {
    public enum Kind: String, Codable { case track, album, playlist }
    public let kind: Kind
    public let id: String
    public init?(_ string: String)                          // rejects spotify:local:, episodes
}

public struct SpotifyTrackMetadata: Hashable, Sendable {
    public let title: String, artist: String, album: String?, artworkURL: URL?, duration: Duration?
}

public struct SpotifyTrackContext: Hashable, Sendable {
    public let uri: SpotifyURI
    public let metadata: SpotifyTrackMetadata
    public let position: Duration?                          // so the hand-off resumes mid-song
}

public enum SonosCommand: Hashable, Sendable {
    case group(member: SpeakerUUID, intoCoordinator: GroupID)
    case ungroup(member: SpeakerUUID)
    case applyPreset(PresetPill)
    case setVolume(DiscreteVolume, for: VolumeTarget)
    case playPause(PlayPause, group: GroupID)
    case nextTrack(group: GroupID)
    case previousTrack(group: GroupID)
    case enqueueAndPlaySpotify(uri: SpotifyURI, metadata: SpotifyTrackMetadata,
                               onCoordinator: GroupID, startingAt: Duration? = nil)
    public var topologyTarget: TopologyTarget? { get }
}

public enum CommandOutcome: Hashable, Sendable {
    case applied, alreadySatisfied, partiallyApplied(unreachable: Set<SpeakerUUID>)
}

public enum SonosCommandError: Error, Hashable, Sendable {
    case speakerUnreachable(SpeakerUUID), groupDissolved(GroupID), notConverged(after: Duration)
    case unsupportedForCurrentSource, spotifyNotLinkedOnSonos, speakerRejected(detail: String)
}

public struct HouseholdSnapshot: Hashable, Sendable {
    public let observedAt: Date
    public let speakers: [SpeakerUUID: Speaker]             // all .online, no satellites
    public let topology: Topology
    public let rf: RFPeerMatrix
    public func status(of group: GroupID) -> GroupStatus    // total: missing reads as stopped at coordinator volume
    public var groups: [SonosGroup] { get }
    package init(...)
}
```

### SonosProtocolBoundary

```swift
public actor SonosHousehold {
    public struct Configuration: Sendable {
        public var sweepInterval: Duration = .seconds(2)
        public var telemetryInterval: Duration = .seconds(30)
        public var offlineAfter: Duration = .seconds(10)
        public var convergenceTimeout: Duration = .seconds(8)
    }
    public init(seedIPs: [String], configuration: Configuration = Configuration())
    public nonisolated func snapshots() -> AsyncStream<HouseholdSnapshot>
    public func send(_ command: SonosCommand) async throws(SonosCommandError) -> CommandOutcome
}

// internal
struct AddressBook { func endpoint(for: SpeakerUUID) -> URL?; mutating func absorb(_: TopologyService.Parsed) }
enum UPnPService: CaseIterable { case zoneGroupTopology, avTransport, renderingControl, groupRenderingControl, contentDirectory, queue }
struct SOAPClient { func call(_: SOAPRequest, on: SpeakerUUID, at: URL) async throws(SonosCommandError) -> XMLNode }
struct XMLNode { static func parse(_: Data) throws -> XMLNode }        // XMLParser-backed; iOS has no XMLDocument
enum TopologyService { static func parse(zoneGroupState: String) throws -> Parsed; static func request(for: TopologyStep) -> (SpeakerUUID, SOAPRequest) }
enum TransportService { static func parsePlayback(...) -> PlaybackState; static func parseVolume(_:) -> DiscreteVolume; static func seek(toTrack:) -> SOAPRequest }
enum TelemetryService { static func model(number:displayName:satellites:battery:) -> SpeakerModel; static func parseRadioStatus(_:resolve:) -> RadioStatus; static func parseBatteryStatus(_:sampledAt:) throws -> BatteryTelemetry }
enum Discovery { static func parse(ssdpResponse: Data) -> SSDPSighting?; static let bonjourServiceType = "_sonos._tcp"; static func seeds() -> AsyncStream<URL> }
enum SpotifyOnSonos { static func discoverAccount(...) async throws(SonosCommandError) -> Account; static func enqueueURI(for:account:) -> String; static func didl(for:uri:account:) -> String }
```

### SpotifyBridge

```swift
public enum SpotifyBridgeError: Error, Hashable, Sendable {
    case notConnected, nothingPlaying, unplayableOnSonos(String), automationDenied
    case authorizationFailed(String), network(String)
}

@MainActor @Observable
public final class SpotifyBridge {
    public enum Authorization: Hashable, Sendable { case notConnected, connected(displayName: String) }
    public private(set) var authorization: Authorization
    public init(clientID: String, redirectURI: URL)
    public func connect(using session: WebAuthenticationSession) async throws(SpotifyBridgeError)   // PKCE
    public func disconnect()
    public func currentContext() async throws(SpotifyBridgeError) -> SpotifyTrackContext
    public func pauseSourcePlayback() async
}
```

On macOS, `currentContext()` asks Spotify.app through `osascript` first when it is running and has a track, then falls back to the Web API. On iOS it uses the Web API. The script guards on `application "Spotify" is running` because a bare `tell` launches the app, and it reports position as integer milliseconds because AppleScript formats reals with the locale's decimal separator. `AppleScriptSource.parse(_:)` is pure and tested against literal script output.

### SconeStore

```swift
public protocol SonosControl: Sendable {                    // SonosHousehold conforms; tests fake it
    func snapshots() -> AsyncStream<HouseholdSnapshot>
    func send(_ command: SonosCommand) async throws(SonosCommandError) -> CommandOutcome
}

@MainActor public protocol SpotifySource: AnyObject {      // SpotifyBridge conforms
    func currentContext() async throws(SpotifyBridgeError) -> SpotifyTrackContext
    func pauseSourcePlayback() async
}

public struct SconeState: Equatable, Sendable {
    // stored, one writer each
    private var known: [SpeakerUUID: Speaker]               // last-known form, always .offline
    public private(set) var live: HouseholdSnapshot?
    private var rf: RFPeerMatrix
    public private(set) var presets: [PresetPill]
    public private(set) var pins: [SpeakerUUID: RoomCoordinate]
    public private(set) var alert: SconeAlert?
    private var inFlight: [InFlight]
    private var inferred: [SpeakerUUID: RoomCoordinate]     // memo, recomputed when rooms or rf change

    public init(loaded: LoadedFiles)
    // transitions
    public mutating func absorb(_ snapshot: HouseholdSnapshot)
    public mutating func begin(_ command: SonosCommand) -> CommandTicket
    public mutating func finish(_ ticket: CommandTicket, with: Result<CommandOutcome, SonosCommandError>)
    public mutating func pin(_ room: SpeakerUUID, at: RoomCoordinate)
    public mutating func unpin(_ room: SpeakerUUID)
    public mutating func savePreset(from group: GroupID, name: String?)
    public mutating func renamePreset(_ id: PresetID, to name: String)
    public mutating func deletePreset(_ id: PresetID)
    public mutating func report(_ alert: SconeAlert)
    public mutating func dismissAlert()
    // derived
    public var speakers: [Speaker] { get }
    public var groups: [SonosGroup] { get }                 // live + in-flight projection
    public var floorplan: [FloorplanNode] { get }
    public var connection: HouseholdConnection { get }      // .searching, .live, .away(lastSeenAt:)
    public func isActive(_ preset: PresetPill) -> Bool
    public var persisted: PersistedSlices { get }
}

@MainActor @Observable
public final class SconeStore {
    public private(set) var state: SconeState
    public init(loaded: LoadedFiles, files: SconeFiles, sonos: any SonosControl, spotify: any SpotifySource)
    public static func live(spotify: SpotifyBridge) -> SconeStore
    public func run() async
    public func send(_ command: SonosCommand)
    public func handOffSpotify(to group: GroupID)
    public func moveRoom(_ room: SpeakerUUID, to: RoomCoordinate)
    public func resetRoom(_ room: SpeakerUUID)
    public func savePreset(from group: GroupID, name: String? = nil)
    public func renamePreset(_ id: PresetID, to name: String)
    public func deletePreset(_ id: PresetID)
    public func dismissAlert()
}

public struct FileSlot<Content: Codable & Equatable & Sendable>: Sendable {
    public let name: String
    public let isDisposable: Bool
    // .cachedSpeakers  -> CachedSpeakersFile       { version, speakers: [Speaker], rf: RFPeerMatrix }
    // .presets         -> PresetsFile              { version, presets: [PresetPill] }
    // .floorplanPositions -> FloorplanPositionsFile { version, pins: [SpeakerUUID: RoomCoordinate] }
}

public struct SconeFiles: Sendable {
    public init(directory: URL)
    public func load<C>(_ slot: FileSlot<C>) -> LoadResult<C>   // .missing, .loaded, .quarantined(fileName:)
    public func save<C>(_ content: C, to slot: FileSlot<C>) throws
    public func loadAll() -> LoadedFiles                         // .seedIPs feeds SonosHousehold
}
```

`floorplan-positions.json` encodes as a JSON object keyed by RINCON id, because `SpeakerUUID` conforms to `CodingKeyRepresentable`.

### Naming rules, as a table test

| Zone names (coordinator first) | Display name |
| :--- | :--- |
| Kitchen Speaker | Kitchen |
| Living Room Soundbar | Living Room |
| Kitchen Speaker, Dining Room Speaker | Kitchen + Dining |
| Kitchen Speaker, Dining Room Speaker, Bedroom Speaker | Kitchen + Bedroom + Dining |
| Kitchen Speaker plus 4 others | Kitchen + Basement + 3 more |
| all 6 online rooms | Everywhere |

## Synthesis decision

Candidate 1 (`claude-opus-5-5-xhigh`) won the arena cross-judge evaluation 19/20 over Candidate 2 (`grok-4.7-xhigh-fast`, 13/20) and was chosen as the base because its 21-case `DiscreteVolume` enum, coordinator-backed `GroupID` with `package` construction, `Topology` member-to-coordinator map, and 3-member `SonosHousehold` boundary eliminate entire classes of illegal states at compile time.

Grafts folded into the base from Candidate 2:
- **Spatial layout prior (`FloorplanLayout.infer(rooms:matrix:prior:)`).** Seeds rooms that lack 2.4 GHz peer readings (5 GHz Kitchen and Dining Room) from the spatial probe coordinates and quantizes inferred coordinates so minor RSSI jitter never moves unpinned rooms.
- **Household ID filtering in discovery.** Filters SSDP responses by `X-RINCON-HOUSEHOLD` when known so neighboring households are ignored.
- **Reachability on `BondedSatellite`.** Tracks whether each bonded rear surround is online.
- **Non-interpolated AppleScript and verified Spotify queue template.** Uses a fixed `osascript` query and the household-verified `sid=12&flags=8224&sn=3` `x-sonos-spotify:` queue format.

## Tradeoffs accepted

- We accept a displayed volume up to 2 points off the speaker's real value (Kitchen at 24 shows 25) in exchange for a type that cannot hold an off-step volume. The first change from Sconeos lands on a detent.
- We accept up to one sweep interval (2 s) of staleness for changes made in the Sonos app in exchange for having no inbound HTTP listener. GENA events need one, which triggers the macOS firewall prompt and dies in the iOS background.
- We accept that `GroupID` equality ignores the wire generation in exchange for SwiftUI identity that survives regroups and presets that cannot key on a reminted value.
- We accept full snapshots instead of deltas. At eight speakers, equality is trivial, and the store reconciles state instead of replaying events.
- We accept that the optimistic projection guesses which member Sonos promotes when a coordinator leaves. Verification checks targets, never exact topologies, so the guess never decides correctness.
- We accept that `SpeakerModel` mixes hardware family with live telemetry (battery, satellites) in exchange for making a battery on an Era 100 unrepresentable. The cache therefore stores the last telemetry as part of the model.
- We accept that a crash between `AddURIToQueue` and `Seek` can leave one extra queue entry after the retry. The URI check makes every other replay a no-op.
- We accept synchronous file writes on the main actor (a few KB, about a millisecond) in exchange for guaranteed write order with no writer queue.
- We accept that `@Observable` tracks `state` as one property, so any change re-evaluates every view that reads it. At this size that costs less than splitting state into observed fragments.
- We accept that applying a preset releases speakers from the coordinator's current group when they are not in the preset. A preset means this exact arrangement.
- We accept `ip: String` in `ReachabilityState` as specified. Only the boundary turns an IP into a URL, and it keeps its own address book.

## Alternatives considered

- **An object per speaker** (the SoCo and node-sonos shape), with `speaker.join(other)` and `speaker.volume = 24`. It exposes coordinator routing, satellites, and convergence to every caller, and the HTTP 500 rule becomes something each call site must remember. Mutable speaker objects shared across actors also leave no single snapshot to reconcile against the cache. It has a larger surface and hides less.
- **A TCA-style reducer with `Action` and `Effect` enums.** Every intent appears as an action case, an effect case, and an interpreter case, three lists kept in sync by hand, and a trace runs through four files. The rules that benefit from purity (planning, reconciliation, naming, layout, projection) are already pure functions on value types here, so the effect layer adds reach without hiding anything.
- **GENA event deltas into per-entity stores.** Subscription renewal, event ordering, and resync after a gap leak into the store, and a full read is still needed at start and after every gap. It is polling plus a callback server.
- **One state file.** A machine write every sweep would share a file with presets, so one bad write or one schema change risks user data. The requirement also names three files.

## Open questions and risks

- Merged names drop "Room", so "Living Room" becomes "Living" in "Kitchen + Living". Is that acceptable, or should the rule drop "Room" only after words that read well alone, like Dining and Guest?
- Should presets sync between the Mac and the iPhone? If yes, `presets.json` gains a second writer and should become one CloudKit record per preset.
- Is Spotify linked in this Sonos household, and can the account serial be lifted from an existing favorite? The PoC did not test any of the Spotify path.
- Does this household advertise `_sonos._tcp` over Bonjour? That is an inference. If it does not, an iOS cold start without the multicast entitlement depends on cached IPs.
- Should presets carry per-room volumes?
- Kitchen advertises a `STEREO_PAIR` capability. A future stereo pair would arrive as an invisible member that is not a home-theater satellite. Should `SpeakerModel` gain a pair payload then?
- Should the hand-off always pause the source, or only when the source is this Mac?
- What should an older build do with a user file whose `version` is newer? The proposal is to treat that slot as read-only for the session.
- When a new speaker joins, inference changes and unpinned rooms re-flow. Should the first inference freeze into pins instead?
- **Sparse RF input.** The probe got peer lines only from the SYMFONISK pair and the Move. Kitchen and Dining had none, so they start in grid slots until pinned.
- **Guessed band thresholds.** Weak below 20 and strong from 35 are fitted to three readings.
- **Local-network permission.** iOS prompts on first launch. A denial leaves the app on the cache only, and `connection` should say so.

## Next implementation step

Build `Topology.applying(_:)` and `TopologyTarget.plan(from:)` with two property tests over generated topologies (applying the planned steps satisfies the target, and planning again yields no steps), then the `ZoneGroupState` parser against a fixture captured from this household with the PoC script.

## Red-flag screen

| Red flag | Result |
| :--- | :--- |
| Shallow module | `SonosHousehold` has 3 public members, `SpotifyBridge` has 5. The store's 6 small intents each own a file-slice write. |
| Information leakage | No SOAP, XML, URL, or HTTP type is public. `speakerRejected(detail:)` carries fault text as a string only. |
| Temporal decomposition | Boundary files are per service, each owning its parse and its requests. |
| Pass-through method | `send` adds projection and alerts. `SonosControl` has a second implementation, the test fake. |
| Split ownership | Each `SconeState` field names its writer. The boundary owns live state, the store owns intents, and `persistChangedSlices` is the only file writer. |
| Two ways to do one task | One `send(SonosCommand)`. Spotify authorization goes only through the bridge, hand-off only through the store. |
| Importable internals | `package` initializers on proof-carrying types, confirmed by the fence-check build failure. Boundary internals are `internal`. |
| Hand-synced list | One model table (`TelemetryService.model`), one service table (`UPnPService`), one file-slot list, and an exhaustive `projecting` switch the compiler checks. |

## Verification of this sketch

- `swift build -Xswiftc -warnings-as-errors` from a clean `.build` in `/tmp/arena-scone-os/candidate-1/sketch/` completes with no errors or warnings (Swift 6.4, Swift 6 language mode, macOS 14 and iOS 17 deployment targets).
- The `UsageSketch` target compiles every call site in the usage section except call site 4, which is the same API from a non-view caller.
- `/tmp/arena-scone-os/candidate-1/fence-check/` fails to build with "'GroupID' initializer is inaccessible due to 'package' protection level" and the same error for `Topology`. `DiscreteVolume(rawValue: 23)` compiles there and returns nil, which is the intended behavior.
- Nothing was run against the household. No body is implemented.
