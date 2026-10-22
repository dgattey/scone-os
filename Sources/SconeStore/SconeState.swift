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

    private struct VolumeOverride: Equatable, Sendable {
        let volume: DiscreteVolume
        let expiresAt: Date
    }

    private struct ClusterTopologyKey: Equatable, Sendable {
        struct Entry: Equatable, Sendable {
            let id: SpeakerUUID
            let roomName: String
            let level: FloorLevel
            let coordinate: RoomCoordinate
            let placement: Placement
        }
        let entries: [Entry]
        let rf: RFPeerMatrix
    }

    private var household: HouseholdID?
    private var known: [SpeakerUUID: Speaker]
    private var otherHouseholds: [HouseholdID: HouseholdRoster]
    public private(set) var live: HouseholdSnapshot?
    private var rf: RFPeerMatrix
    public private(set) var presets: [PresetPill]
    public private(set) var networkName: String?
    public private(set) var pins: [SpeakerUUID: RoomCoordinate]
    public private(set) var alert: SconeAlert?
    private var inFlight: [InFlight] = []
    private var volumeOverrides: [VolumeTarget: VolumeOverride] = [:]
    private var nextTicket = 0
    private var inferred: [SpeakerUUID: RoomCoordinate]
    private var cachedFloorMap: [SpeakerUUID: FloorLevel]
    private var cachedProjected: HouseholdSnapshot?
    private var cachedClusterKey: ClusterTopologyKey?
    public private(set) var speakers: [Speaker] = []
    public private(set) var floorplan: [FloorplanNode] = []
    public private(set) var floorplanRoomClusters: [FloorplanRoomCluster] = []

    public init(loaded: LoadedFiles, initialPresets: [PresetPill] = []) {
        let current = loaded.cache?.current
        let saved = current.flatMap { loaded.cache?.households[$0] }
        let initialKnown = Dictionary(uniqueKeysWithValues: (saved?.speakers ?? []).map {
            ($0.id, $0.lastKnown(seenAt: $0.lastSeenAt ?? .distantPast))
        })
        let initialRF = saved?.rf ?? .empty
        let initialSpeakers = Array(initialKnown.values)
        household = current
        known = initialKnown
        otherHouseholds = (loaded.cache?.households ?? [:]).filter { $0.key != current }
        rf = initialRF
        presets = initialPresets
        networkName = saved?.networkName
        pins = loaded.positions?.pins ?? [:]
        alert = loaded.quarantined.first.map { .quarantined(fileName: $0) }
        inferred = FloorplanLayout.infer(speakers: initialSpeakers, matrix: initialRF)
        cachedFloorMap = FloorplanLayout.classifyFloors(speakers: initialSpeakers, matrix: initialRF)
        recomputeDerivedState()
    }

    public var hasActiveVolumeOverrides: Bool {
        !volumeOverrides.isEmpty
    }

    public func hasExpiredVolumeOverrides(at now: Date = Date()) -> Bool {
        volumeOverrides.values.contains { now >= $0.expiresAt }
    }

    public mutating func setOptimisticVolume(
        _ volume: DiscreteVolume,
        for target: VolumeTarget,
        now: Date = Date(),
        ttl: TimeInterval = 1.5
    ) {
        volumeOverrides[target] = VolumeOverride(
            volume: volume,
            expiresAt: now.addingTimeInterval(ttl)
        )
        recomputeDerivedState()
    }

    /// The roster a snapshot lands on: this household's, or the one saved for the household that answered.
    private func roster(for snapshot: HouseholdSnapshot) -> (known: [SpeakerUUID: Speaker], rf: RFPeerMatrix) {
        guard let next = snapshot.household, next != household else { return (known, rf) }
        let saved = otherHouseholds[next]
        return (Dictionary(uniqueKeysWithValues: (saved?.speakers ?? []).map { ($0.id, $0) }), saved?.rf ?? .empty)
    }

    /// Sets this household's roster aside for when its network comes back, and picks up the saved one for `next`.
    private mutating func enter(_ next: HouseholdID) {
        if let household {
            otherHouseholds[household] = currentRoster
        }
        let saved = otherHouseholds.removeValue(forKey: next)
        household = next
        known = Dictionary(uniqueKeysWithValues: (saved?.speakers ?? []).map { ($0.id, $0) })
        rf = saved?.rf ?? .empty
        networkName = saved?.networkName
        presets = []
    }

    private var currentRoster: HouseholdRoster {
        HouseholdRoster(speakers: known.values.sorted { $0.id < $1.id }, rf: rf, networkName: networkName)
    }

    public func needsFloorplanReinference(for snapshot: HouseholdSnapshot) -> (speakers: [Speaker], rf: RFPeerMatrix)? {
        let base = roster(for: snapshot)
        var nextKnown = base.known
        for speaker in snapshot.speakers.values {
            nextKnown[speaker.id] = speaker.lastKnown(seenAt: snapshot.observedAt)
        }
        let nextRF = snapshot.rf != .empty ? snapshot.rf : base.rf
        if Set(nextKnown.keys) != Set(known.keys)
            || nextKnown.mapValues(\.roomName) != known.mapValues(\.roomName)
            || nextRF != rf {
            return (Array(nextKnown.values), nextRF)
        }
        return nil
    }

    public mutating func absorb(
        _ snapshot: HouseholdSnapshot,
        precomputedLayout: (inferred: [SpeakerUUID: RoomCoordinate], floors: [SpeakerUUID: FloorLevel])? = nil
    ) {
        let prevActiveGroups: Set<GroupID> = Set(
            (live?.groups ?? []).compactMap { group in
                if case .stopped = group.playback { return nil }
                return group.id
            }
        )
        let sanitizedSnapshot = snapshot.sanitizingPlaybackSessions(preferredGroupIDs: prevActiveGroups)
        let now = max(Date(), sanitizedSnapshot.observedAt)
        volumeOverrides = volumeOverrides.filter { target, override in
            guard now < override.expiresAt else { return false }
            switch target {
            case .speaker(let id):
                return sanitizedSnapshot.speakers[id]?.volume != override.volume
            case .group(let groupID):
                return sanitizedSnapshot.status(of: groupID).volume != override.volume
            }
        }

        let previousRooms = Set(known.keys)
        let previousNames = known.mapValues(\.roomName)
        let previousRF = rf
        if let next = sanitizedSnapshot.household, next != household {
            enter(next)
        }
        for speaker in sanitizedSnapshot.speakers.values {
            known[speaker.id] = speaker.lastKnown(seenAt: sanitizedSnapshot.observedAt)
        }
        live = sanitizedSnapshot
        if let sonosPresets = sanitizedSnapshot.presets {
            presets = sonosPresets
        }
        if let net = sanitizedSnapshot.networkName, !net.isEmpty {
            networkName = net
        }
        if sanitizedSnapshot.rf != .empty { rf = sanitizedSnapshot.rf }
        if let precomputedLayout {
            inferred = precomputedLayout.inferred
            cachedFloorMap = precomputedLayout.floors
        } else if Set(known.keys) != previousRooms || known.mapValues(\.roomName) != previousNames || rf != previousRF {
            let knownSpeakers = Array(known.values)
            inferred = FloorplanLayout.infer(speakers: knownSpeakers, matrix: rf)
            cachedFloorMap = FloorplanLayout.classifyFloors(speakers: knownSpeakers, matrix: rf)
        }
        recomputeDerivedState()
    }

    public mutating func begin(_ command: SonosCommand) -> CommandTicket {
        let ticket = CommandTicket(value: nextTicket)
        nextTicket += 1
        inFlight.append(InFlight(ticket: ticket, command: command))
        recomputeDerivedState()
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
        recomputeDerivedState()
    }

    public mutating func pin(_ room: SpeakerUUID, at coordinate: RoomCoordinate) {
        guard pins[room] != coordinate else { return }
        pins[room] = coordinate
        recomputeDerivedState()
    }

    public mutating func unpin(_ room: SpeakerUUID) {
        guard pins[room] != nil else { return }
        pins[room] = nil
        recomputeDerivedState()
    }

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
        cachedProjected?.topology.group(of: speaker)
    }

    public mutating func renamePreset(_ id: PresetID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index] = presets[index].renamed(trimmed)
    }

    public mutating func updatePreset(_ id: PresetID, from group: SonosGroup) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index] = presets[index].updated(
            coordinatorUUID: group.coordinator.id,
            memberUUIDs: group.members.map(\.id)
        )
    }

    public mutating func deletePreset(_ id: PresetID) { presets.removeAll { $0.id == id } }
    public mutating func renameSystem(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        networkName = trimmed
    }
    public mutating func report(_ alert: SconeAlert) { self.alert = alert }
    public mutating func dismissAlert() { alert = nil }

    public var totalSpeakerCount: Int {
        speakers.reduce(0) { $0 + 1 + $1.bondedSatellites.count }
    }

    public var speakerCountSummary: String {
        let count = totalSpeakerCount
        let noun = count == 1 ? "speaker" : "speakers"
        return "\(count) \(noun)"
    }

    public var networkAndSpeakerSummary: String {
        let count = totalSpeakerCount
        let noun = count == 1 ? "speaker" : "speakers"
        if let net = networkName, !net.isEmpty {
            return "\(net) · \(count) \(noun)"
        }
        return "\(count) \(noun)"
    }

    public var groups: [SonosGroup] { cachedProjected?.groups ?? [] }

    public var externalSpotify: SpotifyTrackContext? {
        cachedProjected?.externalSpotify ?? live?.externalSpotify
    }

    public var connection: HouseholdConnection {
        guard let live else { return .searching }
        if !live.speakers.isEmpty { return .live }
        return .away(lastSeenAt: known.values.compactMap(\.lastSeenAt).max())
    }

    public func isActive(_ preset: PresetPill) -> Bool {
        guard let projected = cachedProjected else { return false }
        let expectedRooms = Set([preset.coordinatorUUID]).union(preset.memberUUIDs)
        if expectedRooms.count == 1 {
            let groupID = GroupID(coordinator: preset.coordinatorUUID)
            guard projected.topology.groups[groupID] == [] else { return false }
            switch projected.status(of: groupID).playback {
            case .playing, .paused:
                return true
            case .stopped:
                return false
            }
        }
        if preset.target.isSatisfied(by: projected.topology) { return true }
        return projected.topology.groups.contains { coordinator, members in
            Set([coordinator.coordinator]).union(members) == expectedRooms
        }
    }

    public var persisted: PersistedSlices {
        var households = otherHouseholds
        if let household { households[household] = currentRoster }
        return PersistedSlices(
            cache: CachedSpeakersFile(current: household, households: households),
            positions: FloorplanPositionsFile(pins: pins))
    }

    private mutating func recomputeDerivedState() {
        let projectedSnapshot: HouseholdSnapshot? = live.map { liveSnap in
            let afterInFlight = inFlight.reduce(liveSnap) { $0.projecting($1.command) }
            return volumeOverrides.reduce(afterInFlight) { acc, entry in
                acc.projecting(.setVolume(entry.value.volume, for: entry.key))
            }
        }
        cachedProjected = projectedSnapshot

        let roster = live?.speakers.isEmpty == true ? [:] : known
        let mergedSpeakers = roster
            .merging(projectedSnapshot?.speakers ?? live?.speakers ?? [:]) { _, liveSpk in liveSpk }
            .values
            .sorted { $0.roomName < $1.roomName }
        speakers = mergedSpeakers

        let topology = projectedSnapshot?.topology
        let computedFloorplan = mergedSpeakers.map { speaker in
            let pinned = pins[speaker.id]
            let coordinate = pinned ?? inferred[speaker.id] ?? RoomCoordinate(clampingX: 0.5, y: 0.5)
            let level = cachedFloorMap[speaker.id] ?? FloorLevel.classify(roomName: speaker.roomName)
            return FloorplanNode(
                speaker: speaker,
                level: level,
                coordinate: coordinate,
                placement: pinned == nil ? .inferred : .pinned,
                group: topology?.group(of: speaker.id))
        }
        floorplan = computedFloorplan

        let nextClusterKey = ClusterTopologyKey(
            entries: computedFloorplan.map {
                ClusterTopologyKey.Entry(
                    id: $0.id,
                    roomName: $0.speaker.roomName,
                    level: $0.level,
                    coordinate: $0.coordinate,
                    placement: $0.placement
                )
            },
            rf: rf
        )
        if cachedClusterKey == nextClusterKey, !floorplanRoomClusters.isEmpty {
            let nodesByID = Dictionary(uniqueKeysWithValues: computedFloorplan.map { ($0.id, $0) })
            floorplanRoomClusters = floorplanRoomClusters.map { cluster in
                FloorplanRoomCluster(
                    id: cluster.id,
                    title: cluster.title,
                    level: cluster.level,
                    nodes: cluster.nodes.map { nodesByID[$0.id] ?? $0 }
                )
            }
        } else {
            cachedClusterKey = nextClusterKey
            floorplanRoomClusters = FloorplanLayout.clusterRooms(nodes: computedFloorplan, matrix: rf)
        }
    }
}

public struct PersistedSlices: Equatable, Sendable {
    public let cache: CachedSpeakersFile
    public let positions: FloorplanPositionsFile
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
        case .enqueueAndPlaySpotify(let uri, let metadata, let group, let startingAt, _, let upNext):
            let current = status(of: group)
            let track = NowPlayingTrack(
                title: metadata.title,
                artist: metadata.artist.isEmpty ? nil : metadata.artist,
                album: metadata.album,
                artworkURL: metadata.artworkURL,
                duration: metadata.duration,
                queuePosition: nil,
                spotifyURI: uri,
                source: .spotify(contextTitle: externalSpotify?.contextTitle),
                upNext: upNext,
                canSkip: true
            )
            let playback = PlaybackState.playing(
                .track(track),
                elapsed: startingAt ?? .zero,
                sampledAt: observedAt
            )
            return replacing(
                status: (group, GroupStatus(playback: playback, volume: current.volume)),
                externalSpotify: .some(nil)
            )
        case .nextTrack, .previousTrack, .seekToQueueTrack, .savePresets, .setSystemName:
            return self
        }
    }
}
