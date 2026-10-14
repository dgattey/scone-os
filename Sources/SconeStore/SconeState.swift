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
    case searching
    case live
    case away(lastSeenAt: Date?)
}

public struct SconeState: Equatable, Sendable {
    private struct InFlight: Equatable, Sendable {
        let ticket: CommandTicket
        let command: SonosCommand
    }

    private var known: [SpeakerUUID: Speaker]
    public private(set) var live: HouseholdSnapshot?
    private var rf: RFPeerMatrix
    public private(set) var presets: [PresetPill]
    public private(set) var pins: [SpeakerUUID: RoomCoordinate]
    public private(set) var alert: SconeAlert?
    private var inFlight: [InFlight] = []
    private var nextTicket = 0
    private var inferred: [SpeakerUUID: RoomCoordinate]

    public init(loaded: LoadedFiles) {
        known = Dictionary(uniqueKeysWithValues: (loaded.cache?.speakers ?? []).map { ($0.id, $0) })
        rf = loaded.cache?.rf ?? .empty
        presets = loaded.presets?.presets ?? Self.defaultHouseholdPresets()
        pins = loaded.positions?.pins ?? [:]
        alert = loaded.quarantined.first.map { .quarantined(fileName: $0) }
        inferred = FloorplanLayout.infer(rooms: known.keys.sorted(), matrix: rf)
    }

    public mutating func absorb(_ snapshot: HouseholdSnapshot) {
        let previousRooms = Set(known.keys)
        let previousRF = rf
        for speaker in snapshot.speakers.values {
            known[speaker.id] = speaker.with(
                reachability: .offline(lastKnownIP: speaker.reachability.ip, lastSeenAt: snapshot.observedAt))
        }
        live = snapshot
        if snapshot.rf != .empty { rf = snapshot.rf }
        if Set(known.keys) != previousRooms || rf != previousRF {
            inferred = FloorplanLayout.infer(rooms: known.keys.sorted(), matrix: rf)
        }
    }

    public mutating func begin(_ command: SonosCommand) -> CommandTicket {
        let ticket = CommandTicket(value: nextTicket)
        nextTicket += 1
        inFlight.append(InFlight(ticket: ticket, command: command))
        return ticket
    }

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

    public mutating func savePreset(from group: GroupID, name: String?) {
        guard let captured = groups.first(where: { $0.id == group }) else { return }
        presets.append(PresetPill(capturing: captured, name: name))
    }

    public mutating func createPreset(name: String, coordinator: SpeakerUUID, members: Set<SpeakerUUID>) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        presets.append(PresetPill(name: trimmed, coordinatorUUID: coordinator, memberUUIDs: members))
    }

    public func groupID(containing speaker: SpeakerUUID) -> GroupID? {
        projected?.topology.group(of: speaker)
    }

    public mutating func renamePreset(_ id: PresetID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index] = presets[index].renamed(trimmed)
    }

    public mutating func deletePreset(_ id: PresetID) { presets.removeAll { $0.id == id } }
    public mutating func report(_ alert: SconeAlert) { self.alert = alert }
    public mutating func dismissAlert() { alert = nil }

    public var speakers: [Speaker] {
        known.merging(live?.speakers ?? [:]) { _, live in live }.values.sorted { $0.roomName < $1.roomName }
    }

    public var groups: [SonosGroup] { projected?.groups ?? [] }

    public var floorplan: [FloorplanNode] {
        let topology = projected?.topology
        return speakers.map { speaker in
            let pinned = pins[speaker.id]
            let coordinate = pinned ?? inferred[speaker.id] ?? RoomCoordinate(clampingX: 0.5, y: 0.5)
            return FloorplanNode(
                speaker: speaker,
                coordinate: coordinate,
                placement: pinned == nil ? .inferred : .pinned,
                group: topology?.group(of: speaker.id))
        }
    }

    public var connection: HouseholdConnection {
        guard let live else { return .searching }
        if !live.speakers.isEmpty { return .live }
        return .away(lastSeenAt: known.values.compactMap(\.lastSeenAt).max())
    }

    public func isActive(_ preset: PresetPill) -> Bool {
        projected.map { preset.target.isSatisfied(by: $0.topology) } ?? false
    }

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

extension SconeState {
    private static func defaultHouseholdPresets() -> [PresetPill] {
        func id(_ raw: String) -> SpeakerUUID {
            guard let uuid = SpeakerUUID(rawValue: raw) else { preconditionFailure("invalid household id \(raw)") }
            return uuid
        }
        let kitchen = id("RINCON_F0F6C1AAD22801400")
        let dining = id("RINCON_F0F6C1C47CEA01400")
        let living = id("RINCON_542A1B95A13A01400")
        let bedroom = id("RINCON_542A1B5F088401400")
        let guest = id("RINCON_542A1B5F08A001400")
        let basement = id("RINCON_C4387523117601400")
        return [
            PresetPill(name: "Kitchen + Dining", coordinatorUUID: kitchen, memberUUIDs: [dining]),
            PresetPill(name: "Main Floor", coordinatorUUID: living, memberUUIDs: [kitchen, dining]),
            PresetPill(name: "Upstairs", coordinatorUUID: bedroom, memberUUIDs: [guest]),
            PresetPill(
                name: "Everywhere",
                coordinatorUUID: living,
                memberUUIDs: [kitchen, dining, bedroom, guest, basement]),
        ]
    }
}

private extension Speaker {
    var lastSeenAt: Date? {
        if case .offline(_, let at) = reachability { at } else { nil }
    }
}

extension HouseholdSnapshot {
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
            let current = status(of: group)
            let playback: PlaybackState
            switch (desired, current.playback) {
            case (.play, .paused(let nowPlaying, let elapsed)):
                playback = .playing(nowPlaying, elapsed: elapsed, sampledAt: observedAt)
            case (.pause, .playing(let nowPlaying, let elapsed, _)):
                playback = .paused(nowPlaying, elapsed: elapsed)
            case (.play, .playing), (.play, .stopped), (.pause, .paused), (.pause, .stopped):
                return self
            }
            return replacing(status: (group, GroupStatus(playback: playback, volume: current.volume)))
        case .nextTrack, .previousTrack, .enqueueAndPlaySpotify:
            return self
        }
    }
}
