import Foundation
import SconeDomain
import SpotifyBridge

public struct CommandTicket: Hashable, Sendable {
    fileprivate let value: Int
}

public enum SconeAlert: Hashable, Sendable {
    case commandFailed(SonosCommand, SonosCommandError)
    case partiallyApplied(SonosCommand, unreachable: Set<SpeakerUUID>)
    case spotify(SpotifyBridgeError)
    case quarantined(fileName: String)
}

public enum HouseholdConnection: Hashable, Sendable {
    /// No sweep has finished yet. The floorplan shows the cache.
    case searching
    case live
    /// The last sweep found no speakers: away from home, or Wi-Fi off.
    case away(lastSeenAt: Date?)
}

/// The app's whole state and every transition on it. Pure: no I/O, no clock, no tasks. This is the
/// reducer. `SconeStore` is the shell that feeds it events and runs the I/O it implies.
///
/// Each stored field has one writer, named in its comment. Everything a view reads that could be
/// computed from these fields is computed, so nothing needs syncing.
public struct SconeState: Equatable, Sendable {
    private struct InFlight: Equatable, Sendable {
        let ticket: CommandTicket
        let command: SonosCommand
    }

    /// Every speaker ever seen, in last-known form (reachability always `.offline`). Writers: `init`, `absorb`.
    private var known: [SpeakerUUID: Speaker]
    /// The latest sweep, nil before the first. Writer: `absorb`.
    public private(set) var live: HouseholdSnapshot?
    /// Last non-empty RF matrix, live or cached. Writers: `init`, `absorb`.
    private var rf: RFPeerMatrix
    /// Writers: `savePreset`, `renamePreset`, `deletePreset`.
    public private(set) var presets: [PresetPill]
    /// Writers: `pin`, `unpin`.
    public private(set) var pins: [SpeakerUUID: RoomCoordinate]
    /// Writers: `finish`, `report`, `dismissAlert`.
    public private(set) var alert: SconeAlert?
    /// Commands sent and not yet returned. Projected onto `live` for display. Writers: `begin`, `finish`.
    private var inFlight: [InFlight] = []
    private var nextTicket = 0
    /// Memo of `FloorplanLayout.infer(rooms:matrix:)`. Recomputed in `init` and `absorb`, only when the
    /// room set or `rf` changed, because views read `floorplan` on every frame of a drag.
    private var inferred: [SpeakerUUID: RoomCoordinate]

    public init(loaded: LoadedFiles) {
        known = Dictionary(uniqueKeysWithValues: (loaded.cache?.speakers ?? []).map { ($0.id, $0) })
        rf = loaded.cache?.rf ?? .empty
        presets = loaded.presets?.presets ?? []
        pins = loaded.positions?.pins ?? [:]
        alert = loaded.quarantined.first.map { .quarantined(fileName: $0) }
        inferred = FloorplanLayout.infer(rooms: known.keys.sorted(), matrix: rf)
    }

    // MARK: Transitions

    public mutating func absorb(_ snapshot: HouseholdSnapshot) {
        // TODO:
        // for speaker in snapshot.speakers.values:
        //   known[id] = speaker.with(reachability: .offline(lastKnownIP: speaker.reachability.ip, lastSeenAt: snapshot.observedAt))
        // speakers absent from the snapshot keep their entry, so lastSeenAt stays at their last sighting
        // live = snapshot
        // if snapshot.rf != .empty { rf = snapshot.rf }
        // if room set or rf changed { inferred = FloorplanLayout.infer(rooms: known.keys.sorted(), matrix: rf) }
        fatalError("not implemented")
    }

    public mutating func begin(_ command: SonosCommand) -> CommandTicket {
        let ticket = CommandTicket(value: nextTicket)
        nextTicket += 1
        inFlight.append(InFlight(ticket: ticket, command: command))
        return ticket
    }

    /// Dropping the projection here cannot flicker, because `SonosHousehold.send` only returns after
    /// it yielded a snapshot reflecting the command, and `absorb` ran first.
    public mutating func finish(_ ticket: CommandTicket, with result: Result<CommandOutcome, SonosCommandError>) {
        guard let index = inFlight.firstIndex(where: { $0.ticket == ticket }) else { return }
        let command = inFlight.remove(at: index).command
        switch result {
        case .success(.applied), .success(.alreadySatisfied): break
        case .success(.partiallyApplied(let unreachable)): alert = .partiallyApplied(command, unreachable: unreachable)
        case .failure(let error): alert = .commandFailed(command, error)
        }
    }

    public mutating func pin(_ room: SpeakerUUID, at coordinate: RoomCoordinate) { pins[room] = coordinate }
    public mutating func unpin(_ room: SpeakerUUID) { pins[room] = nil }

    /// Captures the projected group, so a preset saved mid-regroup matches what the person sees.
    public mutating func savePreset(from group: GroupID, name: String?) {
        guard let captured = groups.first(where: { $0.id == group }) else { return }
        presets.append(PresetPill(capturing: captured, name: name))
    }

    public mutating func renamePreset(_ id: PresetID, to name: String) {
        fatalError("not implemented")
    }

    public mutating func deletePreset(_ id: PresetID) { presets.removeAll { $0.id == id } }
    public mutating func report(_ alert: SconeAlert) { self.alert = alert }
    public mutating func dismissAlert() { alert = nil }

    // MARK: Derived reads

    /// Live speakers overlay their last-known entries. Sorted by room name.
    public var speakers: [Speaker] {
        known.merging(live?.speakers ?? [:]) { _, live in live }.values.sorted { $0.roomName < $1.roomName }
    }

    public var groups: [SonosGroup] { projected?.groups ?? [] }

    public var floorplan: [FloorplanNode] {
        // TODO: for each speaker: coordinate = pins[id] ?? inferred[id]; placement accordingly;
        // group = projected?.topology.group(of: id)
        fatalError("not implemented")
    }

    public var connection: HouseholdConnection {
        guard let live else { return .searching }
        if !live.speakers.isEmpty { return .live }
        return .away(lastSeenAt: known.values.compactMap(\.lastSeenAt).max())
    }

    /// Uses the projection, so a tapped pill lights up before the speakers confirm.
    public func isActive(_ preset: PresetPill) -> Bool {
        projected.map { preset.target.isSatisfied(by: $0.topology) } ?? false
    }

    /// The store writes whichever slice changed since its last write.
    public var persisted: PersistedSlices {
        PersistedSlices(
            cache: CachedSpeakersFile(speakers: known.values.sorted { $0.id < $1.id }, rf: rf),
            presets: PresetsFile(presets: presets),
            positions: FloorplanPositionsFile(pins: pins))
    }

    private var projected: HouseholdSnapshot? {
        live.map { live in inFlight.reduce(live) { $0.projecting($1.command) } }
    }
}

public struct PersistedSlices: Equatable, Sendable {
    public let cache: CachedSpeakersFile
    public let presets: PresetsFile
    public let positions: FloorplanPositionsFile
}

private extension Speaker {
    var lastSeenAt: Date? {
        if case .offline(_, let at) = reachability { at } else { nil }
    }
}

extension HouseholdSnapshot {
    /// The optimistic view of one in-flight command. Exhaustive on purpose: a new command case
    /// does not compile until someone decides what it looks like before the speakers confirm.
    func projecting(_ command: SonosCommand) -> HouseholdSnapshot {
        switch command {
        case .group, .ungroup, .applyPreset:
            guard let target = command.topologyTarget, case .steps(let steps, _) = target.plan(from: topology) else {
                return self
            }
            return replacing(topology: steps.reduce(topology) { $0.applying($1) })
        case .setVolume(let volume, .speaker(let id)):
            guard let speaker = speakers[id] else { return self }
            return replacing(speakers: speakers.merging([id: speaker.with(volume: volume)]) { $1 })
        case .setVolume(let volume, .group(let group)):
            return replacing(status: (group, GroupStatus(playback: status(of: group).playback, volume: volume)))
        case .playPause(let desired, let group):
            // TODO: .play turns .paused(np, e) into .playing(np, e, sampledAt: observedAt); .pause the reverse.
            _ = (desired, group)
            fatalError("not implemented")
        case .nextTrack, .previousTrack, .enqueueAndPlaySpotify:
            // The next track's metadata is unknown until the coordinator reports it.
            return self
        }
    }
}
