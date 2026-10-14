import Foundation
import SconeDomain

/// The only public type in this module. Everything else (SSDP, Bonjour, SOAP envelopes, the
/// escaped XML inside them, `/status` text formats, the address book, coordinator routing,
/// convergence polling, Spotify service-account discovery) is internal.
///
/// Guarantees:
/// - Snapshots contain only domain types, all speakers `.online`, satellites folded into `.beamHt`.
/// - `send` returns only after a snapshot reflecting the command has been yielded (read your
///   writes), so callers can drop optimistic state on return without a flicker.
/// - Commands to one coordinator run in order. Commands to different coordinators run concurrently.
public actor SonosHousehold {
    public struct Configuration: Sendable {
        public var sweepInterval: Duration = .seconds(2)
        public var telemetryInterval: Duration = .seconds(30)
        /// A speaker missing from topology for this long leaves the snapshot. One slow sweep is not offline.
        public var offlineAfter: Duration = .seconds(10)
        public var convergenceTimeout: Duration = .seconds(8)
        public init() {}
    }

    private let configuration: Configuration
    private var addressBook: AddressBook
    private var latest: HouseholdSnapshot?
    private var subscribers: [UUID: AsyncStream<HouseholdSnapshot>.Continuation] = [:]
    /// Per-coordinator FIFO. Each new command chains onto the previous task for its coordinator.
    private var lanes: [SpeakerUUID: Task<Void, Never>] = [:]
    private var spotifyAccount: SpotifyOnSonos.Account?

    /// `seedIPs` are last-known speaker IPs from the cache. Any one live speaker is enough, because
    /// `GetZoneGroupState` returns every member's `Location`. SSDP and Bonjour only matter when
    /// no seed answers (first launch, or DHCP moved everyone).
    public init(seedIPs: [String], configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.addressBook = AddressBook(seedIPs: seedIPs)
    }

    /// Each call returns a new stream fed by the same sweep loop. The loop starts with the first
    /// subscriber and stops when the last one terminates.
    public nonisolated func snapshots() -> AsyncStream<HouseholdSnapshot> {
        // TODO: makeStream; Task { await register(continuation) }; onTermination -> unregister.
        // register yields `latest` immediately when present, then starts `sweepLoop()` if idle.
        fatalError("not implemented")
    }

    public func send(_ command: SonosCommand) async throws(SonosCommandError) -> CommandOutcome {
        // TODO:
        // if let target = command.topologyTarget:
        //   plan = target.plan(from: fresh topology)        // re-read, never trust `latest` for writes
        //   .impossible -> throw; .steps([]) -> .alreadySatisfied
        //   run each step via TopologyService on its member's endpoint
        //   poll topology until target.isSatisfied(by:ignoring: skipped) or convergenceTimeout
        //   publish; return skipped.isEmpty ? .applied : .partiallyApplied(skipped)
        // else route by coordinator lane:
        //   .setVolume(.speaker) -> RenderingControl on that speaker; .setVolume(.group) -> GroupRenderingControl
        //   on group.coordinator, then re-read member volumes (Sonos rescales them)
        //   .playPause -> read transport; already in desired state -> .alreadySatisfied; else Play/Pause
        //   .nextTrack/.previousTrack -> NowPlayingTrack.queuePosition nil -> .unsupportedForCurrentSource
        //   .enqueueAndPlaySpotify -> SpotifyOnSonos
        //   then refresh the touched slice and publish before returning
        fatalError("not implemented")
    }

    private func sweepLoop() async {
        // TODO: every sweepInterval: topology from any reachable endpoint (seeds first), then per coordinator
        // GetTransportInfo + GetPositionInfo + GetMediaInfo + GetGroupVolume, per speaker GetVolume.
        // Every telemetryInterval: ath_rincon/status for RF + noise floor, batterystatus for Move models,
        // device_description once per speaker for its model number.
        // When no endpoint answers: Discovery.seeds() and retry. Assemble, publish if != latest.
        fatalError("not implemented")
    }

    private func publish(_ snapshot: HouseholdSnapshot) {
        guard snapshot != latest else { return }
        latest = snapshot
        for continuation in subscribers.values { continuation.yield(snapshot) }
    }
}

/// UUID to endpoint, rebuilt from every `ZoneGroupState` (members' `Location` attributes).
/// Seeds are tried in order until one answers.
struct AddressBook: Sendable {
    private var endpoints: [SpeakerUUID: URL] = [:]
    private(set) var seeds: [URL]

    init(seedIPs: [String]) {
        seeds = seedIPs.compactMap { URL(string: "http://\($0):1400") }
    }

    func endpoint(for speaker: SpeakerUUID) -> URL? { endpoints[speaker] }

    mutating func absorb(_ parsed: TopologyService.Parsed) {
        fatalError("not implemented")
    }
}
