import Foundation
import Observation
import SconeDomain
import SonosProtocolBoundary
import SpotifyBridge

@MainActor
@Observable
public final class SconeStore {
    public private(set) var state: SconeState
    @ObservationIgnored private var preMuteVolumes: [SpeakerUUID: DiscreteVolume] = [:]

    @ObservationIgnored private let sonos: any SonosControl
    @ObservationIgnored private let spotify: any SpotifySource
    @ObservationIgnored private let files: SconeFiles
    @ObservationIgnored private var written: PersistedSlices
    @ObservationIgnored private var lastCacheWrite: Date = .distantPast
    @ObservationIgnored private var lastSpotifyEnrich: Date = .distantPast
    @ObservationIgnored private var lastEnrichedTrackIdentity: String?
    @ObservationIgnored private var cachedSpotifyContext: SpotifyTrackContext?
    @ObservationIgnored private var inFlightSpotifyRefresh: Task<Void, Never>?
    @ObservationIgnored private var lastKnownTracks: [GroupID: NowPlayingTrack] = [:]
    @ObservationIgnored private var preferredActiveGroupIDs: Set<GroupID> = []
    @ObservationIgnored private var pendingVolumes: [VolumeTarget: DiscreteVolume] = [:]
    @ObservationIgnored private var activeVolumeTasks: [VolumeTarget: Task<Void, Never>] = [:]
    @ObservationIgnored private var isRunningLoop = false

    public init(
        loaded: LoadedFiles,
        files: SconeFiles,
        sonos: any SonosControl,
        spotify: any SpotifySource,
        initialPresets: [PresetPill] = []
    ) {
        let state = SconeState(loaded: loaded, initialPresets: initialPresets)
        self.state = state
        self.written = state.persisted
        self.files = files
        self.sonos = sonos
        self.spotify = spotify
    }

    public static func live(spotify: SpotifyBridge) -> SconeStore {
        let support = URL.applicationSupportDirectory
        let targetDir = support.appending(path: "Sconeos")
        #if targetEnvironment(simulator)
        if let hostHome = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"], !hostHome.isEmpty {
            let hostAppSupport = URL(fileURLWithPath: hostHome).appending(path: "Library/Application Support/Sconeos")
            SconeFiles.migrateLegacyDirectoryIfNeeded(from: hostAppSupport, to: targetDir)
        }
        #endif
        let files = SconeFiles(directory: targetDir)
        let loaded = files.loadAll()
        return SconeStore(
            loaded: loaded,
            files: files,
            sonos: SonosHousehold(seedIPs: mergedSeedIPs(cached: loaded.seedIPs)),
            spotify: spotify)
    }

    @discardableResult
    private func mutateState<R>(_ body: (inout SconeState) -> R) -> R {
        var next = state
        let result = body(&next)
        if next != state {
            state = next
        }
        return result
    }

    public func run() async {
        guard !isRunningLoop else { return }
        isRunningLoop = true
        defer { isRunningLoop = false }

        for await snapshot in sonos.snapshots() {
            let enriched = await enrichWithSpotifyIfNeeded(snapshot)
            if let currentLive = state.live,
               currentLive.isSemanticallyEquivalent(to: enriched),
               !state.hasExpiredVolumeOverrides() {
                await persistChangedSlicesAsync()
                continue
            }
            var precomputedLayout: (inferred: [SpeakerUUID: RoomCoordinate], floors: [SpeakerUUID: FloorLevel])?
            if let reinferInput = state.needsFloorplanReinference(for: enriched) {
                precomputedLayout = await Task.detached(priority: .utility) {
                    let inf = FloorplanLayout.infer(speakers: reinferInput.speakers, matrix: reinferInput.rf)
                    let flr = FloorplanLayout.classifyFloors(speakers: reinferInput.speakers, matrix: reinferInput.rf)
                    return (inf, flr)
                }.value
            }
            mutateState { $0.absorb(enriched, precomputedLayout: precomputedLayout) }
            await persistChangedSlicesAsync()
        }
    }

    public func refreshSpotifyQueueIfNeeded() {
        let now = Date()
        guard inFlightSpotifyRefresh == nil,
              now.timeIntervalSince(lastSpotifyEnrich) >= 4 else { return }
        lastSpotifyEnrich = now
        inFlightSpotifyRefresh = Task { [weak self] in
            guard let self else { return }
            defer { self.inFlightSpotifyRefresh = nil }
            let fetched = try? await self.spotify.currentContext()
            self.lastSpotifyEnrich = Date()
            guard let fetched else { return }
            self.cachedSpotifyContext = fetched
            if let live = self.state.live {
                let enriched = await self.enrichWithSpotifyIfNeeded(live)
                if !live.isSemanticallyEquivalent(to: enriched) {
                    self.mutateState { $0.absorb(enriched) }
                }
            }
        }
    }

    public func playQueueItem(_ item: QueueItem, on group: GroupID) {
        if let queueNumber = item.queueNumber, queueNumber > 0 {
            send(.seekToQueueTrack(number: queueNumber, group: group))
        } else if let uri = item.spotifyURI {
            let metadata = SpotifyTrackMetadata(
                title: item.title,
                artist: item.artist ?? "",
                album: item.album,
                artworkURL: item.artworkURL,
                duration: item.duration
            )
            send(.enqueueAndPlaySpotify(uri: uri, metadata: metadata, onCoordinator: group))
        }
        schedulePostTransportSpotifyRefresh()
    }

    private func schedulePostTransportSpotifyRefresh() {
        Task {
            try? await Task.sleep(for: .seconds(1))
            refreshSpotifyQueueIfNeeded()
        }
    }

    private func enrichWithSpotifyIfNeeded(_ rawSnapshot: HouseholdSnapshot) async -> HouseholdSnapshot {
        let snapshot = rawSnapshot.sanitizingPlaybackSessions(preferredGroupIDs: preferredActiveGroupIDs)

        let activeGroupIDs = Set(snapshot.groups.compactMap { group -> GroupID? in
            if case .stopped = group.playback { return nil }
            return group.id
        })
        preferredActiveGroupIDs = activeGroupIDs

        for groupID in Array(lastKnownTracks.keys) where !activeGroupIDs.contains(groupID) {
            lastKnownTracks.removeValue(forKey: groupID)
        }

        let activeGroups = snapshot.groups.filter { activeGroupIDs.contains($0.id) }
        guard !activeGroups.isEmpty else { return snapshot }

        let trackIdentity = activeGroups.compactMap { group -> String? in
            guard case .track(let track) = group.playback.nowPlaying else { return nil }
            return track.spotifyURI?.description ?? track.title
        }.joined(separator: "|")

        let isAnyPlaying = activeGroups.contains {
            if case .playing = $0.playback { return true }
            return false
        }
        let refreshInterval: TimeInterval = isAnyPlaying ? 30 : 120
        let trackChanged = !trackIdentity.isEmpty && trackIdentity != lastEnrichedTrackIdentity
        let now = Date()

        if trackChanged || now.timeIntervalSince(lastSpotifyEnrich) >= refreshInterval {
            lastSpotifyEnrich = now
            if !trackIdentity.isEmpty {
                lastEnrichedTrackIdentity = trackIdentity
            }
            if let fetched = try? await spotify.currentContext() {
                cachedSpotifyContext = fetched
            }
        }

        // Determine the single primary active group eligible to receive SpotifyTrackContext + upNext queue
        var primarySpotifyGroupID: GroupID?
        if let ctx = cachedSpotifyContext {
            let matchingGroups = activeGroups.filter { group in
                guard case .track(let track) = group.playback.nowPlaying else { return false }
                let sameURI = (track.spotifyURI != nil && track.spotifyURI == ctx.uri)
                let sameTitle = !track.title.isEmpty && track.title.caseInsensitiveCompare(ctx.metadata.title) == .orderedSame
                let sameDevice = ctx.deviceName.map { dev in
                    group.speakers.contains { $0.roomName.caseInsensitiveCompare(dev) == .orderedSame }
                } ?? false
                return sameURI || sameTitle || sameDevice
            }
            primarySpotifyGroupID = matchingGroups.max { lhs, rhs in
                let lhsRank = playbackRank(lhs.playback)
                let rhsRank = playbackRank(rhs.playback)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if lhs.speakers.count != rhs.speakers.count { return lhs.speakers.count < rhs.speakers.count }
                return lhs.id > rhs.id
            }?.id
        }

        var updated = snapshot
        for group in activeGroups {
            guard case .track(let track) = group.playback.nowPlaying else { continue }
            var enrichedTrack = track

            if let ctx = cachedSpotifyContext, group.id == primarySpotifyGroupID {
                let mergedSource: PlaybackSource? = if let ctxTitle = ctx.contextTitle, !ctxTitle.isEmpty {
                    .spotify(contextTitle: ctxTitle)
                } else {
                    track.source ?? .spotify(contextTitle: track.album)
                }
                let mergedUpNext = track.upNext.isEmpty ? ctx.upNext : track.upNext
                let mergedArt = track.artworkURL ?? ctx.metadata.artworkURL
                enrichedTrack = track.merging(
                    artworkURL: mergedArt,
                    source: mergedSource,
                    upNext: mergedUpNext,
                    canSkip: true
                )
            }

            if let cached = lastKnownTracks[group.id],
               (enrichedTrack.spotifyURI != nil && enrichedTrack.spotifyURI == cached.spotifyURI)
               || (!enrichedTrack.title.isEmpty && enrichedTrack.title == cached.title) {
                let allowCachedQueue = group.id == primarySpotifyGroupID || !enrichedTrack.isSpotifyStream
                enrichedTrack = enrichedTrack.merging(
                    artworkURL: enrichedTrack.artworkURL ?? cached.artworkURL,
                    source: enrichedTrack.source ?? cached.source,
                    upNext: (allowCachedQueue && enrichedTrack.upNext.isEmpty) ? cached.upNext : enrichedTrack.upNext,
                    canSkip: enrichedTrack.canSkip || cached.canSkip
                )
            }

            lastKnownTracks[group.id] = enrichedTrack

            if enrichedTrack != track {
                let newPlayback: PlaybackState = switch group.playback {
                case .playing(_, let elapsed, let sampledAt):
                    .playing(.track(enrichedTrack), elapsed: elapsed, sampledAt: sampledAt)
                case .paused(_, let elapsed):
                    .paused(.track(enrichedTrack), elapsed: elapsed)
                case .stopped:
                    .stopped
                }
                updated = updated.replacing(
                    status: (group.id, GroupStatus(playback: newPlayback, volume: group.volume))
                )
            }
        }
        return updated.sanitizingPlaybackSessions(preferredGroupIDs: preferredActiveGroupIDs)
    }

    public func send(_ command: SonosCommand) {
        if case .setVolume(let volume, let target) = command {
            setVolume(volume, for: target)
            return
        }
        switch command {
        case .nextTrack, .previousTrack, .playPause, .seekToQueueTrack, .enqueueAndPlaySpotify:
            schedulePostTransportSpotifyRefresh()
        default:
            break
        }
        Task { _ = await perform(command) }
    }

    public func setVolume(_ volume: DiscreteVolume, for target: VolumeTarget) {
        mutateState { $0.setOptimisticVolume(volume, for: target, ttl: 2.0) }
        pendingVolumes[target] = volume
        guard activeVolumeTasks[target] == nil else { return }

        activeVolumeTasks[target] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(75))
            while let nextVolume = self.pendingVolumes.removeValue(forKey: target) {
                let cmd = SonosCommand.setVolume(nextVolume, for: target)
                do throws(SonosCommandError) {
                    let outcome = try await self.sonos.send(cmd)
                    if case .partiallyApplied(let unreachable) = outcome {
                        self.mutateState { $0.report(.partiallyApplied(cmd, unreachable: unreachable)) }
                    }
                } catch {
                    self.mutateState { $0.report(.commandFailed(cmd, error)) }
                }
                self.mutateState { $0.setOptimisticVolume(nextVolume, for: target, ttl: 1.5) }
                if self.pendingVolumes[target] != nil {
                    try? await Task.sleep(for: .milliseconds(75))
                }
            }
            self.activeVolumeTasks[target] = nil
        }
    }

    public func handOffSpotify(to group: GroupID) {
        Task {
            let context: SpotifyTrackContext
            do throws(SpotifyBridgeError) {
                context = try await spotify.currentContext()
            } catch {
                mutateState { $0.report(.spotify(error)) }
                return
            }
            let result = await perform(
                .enqueueAndPlaySpotify(
                    uri: context.uri, metadata: context.metadata, onCoordinator: group, startingAt: context.position))
            if case .success = result { await spotify.pauseSourcePlayback() }
        }
    }

    public func moveRoom(_ room: SpeakerUUID, to coordinate: RoomCoordinate) {
        mutateState { $0.pin(room, at: coordinate) }
        persistChangedSlices()
    }

    public func resetRoom(_ room: SpeakerUUID) {
        mutateState { $0.unpin(room) }
        persistChangedSlices()
    }

    public func savePreset(from group: GroupID, name: String? = nil) {
        mutateState { $0.savePreset(from: group, name: name) }
        send(.savePresets(state.presets))
    }

    public func createPreset(name: String, coordinator: SpeakerUUID, members: Set<SpeakerUUID>) {
        mutateState { $0.createPreset(name: name, coordinator: coordinator, members: members) }
        send(.savePresets(state.presets))
    }

    public func updatePreset(_ id: PresetID, from groupID: GroupID) {
        guard let group = state.groups.first(where: { $0.id == groupID }) else { return }
        mutateState { $0.updatePreset(id, from: group) }
        send(.savePresets(state.presets))
    }

    public func group(member: SpeakerUUID, onto targetSpeaker: SpeakerUUID) {
        guard member != targetSpeaker else { return }
        let sourceGroup = state.groups.first { $0.speakers.contains { $0.id == member } }
        let targetGroup = state.groups.first { $0.speakers.contains { $0.id == targetSpeaker } }

        guard let sourceGroup, let targetGroup else {
            if let targetID = state.groupID(containing: targetSpeaker) {
                send(.group(member: member, intoCoordinator: targetID))
            }
            return
        }
        guard sourceGroup.id != targetGroup.id else { return }

        let sourceRank = playbackRank(sourceGroup.playback)
        let targetRank = playbackRank(targetGroup.playback)

        if sourceGroup.speakers.count == 1 && targetGroup.speakers.count == 1 {
            if sourceRank > targetRank {
                send(.group(member: targetSpeaker, intoCoordinator: sourceGroup.id))
            } else {
                send(.group(member: member, intoCoordinator: targetGroup.id))
            }
        } else if sourceGroup.speakers.count > 1 && targetGroup.speakers.count == 1 {
            if targetRank > sourceRank {
                let allMembers = Set(sourceGroup.speakers.map(\.id)).subtracting([targetGroup.coordinator.id])
                send(.applyPreset(PresetPill(
                    name: targetGroup.displayName,
                    coordinatorUUID: targetGroup.coordinator.id,
                    memberUUIDs: allMembers
                )))
            } else {
                send(.group(member: targetSpeaker, intoCoordinator: sourceGroup.id))
            }
        } else if sourceGroup.speakers.count == 1 && targetGroup.speakers.count > 1 {
            if sourceRank > targetRank {
                let allMembers = Set(targetGroup.speakers.map(\.id)).subtracting([sourceGroup.coordinator.id])
                send(.applyPreset(PresetPill(
                    name: sourceGroup.displayName,
                    coordinatorUUID: sourceGroup.coordinator.id,
                    memberUUIDs: allMembers
                )))
            } else {
                send(.group(member: member, intoCoordinator: targetGroup.id))
            }
        } else {
            let lead = (sourceRank > targetRank) ? sourceGroup.coordinator.id : targetGroup.coordinator.id
            let unionIDs = Set(sourceGroup.speakers.map(\.id))
                .union(targetGroup.speakers.map(\.id))
                .subtracting([lead])
            send(.applyPreset(PresetPill(
                name: targetGroup.displayName,
                coordinatorUUID: lead,
                memberUUIDs: unionIDs
            )))
        }
    }

    public func ungroupSpeaker(_ speaker: SpeakerUUID) {
        guard let group = state.groups.first(where: { $0.speakers.contains { $0.id == speaker } }),
              group.speakers.count > 1 else { return }
        if speaker == group.coordinator.id,
           let promoted = group.members.map(\.id).min(),
           let cached = lastKnownTracks[group.id] {
            lastKnownTracks[GroupID(coordinator: promoted)] = cached
        }
        send(.ungroup(member: speaker))
    }

    public func dissolveGroup(_ groupID: GroupID) {
        guard let group = state.groups.first(where: { $0.id == groupID }),
              group.speakers.count > 1 else { return }
        if group.members.count == 1, let follower = group.members.first?.id {
            send(.ungroup(member: follower))
        } else {
            send(.applyPreset(PresetPill(
                name: group.displayName,
                coordinatorUUID: group.coordinator.id,
                memberUUIDs: []
            )))
        }
    }

    public func groupEverywhere() {
        let online = state.speakers.filter(\.reachability.isOnline)
        guard online.count > 1 else { return }
        let bestCoordinator = state.groups
            .max { playbackRank($0.playback) < playbackRank($1.playback) }
            .flatMap { playbackRank($0.playback) > 0 ? $0.coordinator.id : nil }
        let lead = bestCoordinator ?? online[0].id
        let members = Set(online.map(\.id)).subtracting([lead])
        send(.applyPreset(PresetPill(name: "Everywhere", coordinatorUUID: lead, memberUUIDs: members)))
    }

    public func applyPreset(_ preset: PresetPill) {
        let allIDs = Set([preset.coordinatorUUID]).union(preset.memberUUIDs)
        let candidateGroups = state.groups.filter { group in
            group.speakers.contains { allIDs.contains($0.id) }
        }
        let defaultRank = state.groups
            .first { $0.coordinator.id == preset.coordinatorUUID }
            .map { playbackRank($0.playback) } ?? 0
        if let bestGroup = candidateGroups.max(by: { playbackRank($0.playback) < playbackRank($1.playback) }),
           playbackRank(bestGroup.playback) > defaultRank,
           allIDs.contains(bestGroup.coordinator.id) {
            let lead = bestGroup.coordinator.id
            let members = allIDs.subtracting([lead])
            send(.applyPreset(PresetPill(
                id: preset.id,
                name: preset.name,
                coordinatorUUID: lead,
                memberUUIDs: members
            )))
        } else {
            send(.applyPreset(preset))
        }
    }

    public func toggleMute(for speakerID: SpeakerUUID) {
        guard let speaker = state.speakers.first(where: { $0.id == speakerID }) else { return }
        if speaker.volume == .v0 {
            let restored = preMuteVolumes[speakerID] ?? .v20
            send(.setVolume(restored, for: .speaker(speakerID)))
        } else {
            preMuteVolumes[speakerID] = speaker.volume
            send(.setVolume(.v0, for: .speaker(speakerID)))
        }
    }

    public func togglePlayOrHandOffSpotify(for group: SonosGroup) {
        switch group.playback {
        case .playing:
            send(.playPause(.pause, group: group.id))
        case .paused(let nowPlaying, let elapsed):
            Task {
                let result = await perform(.playPause(.play, group: group.id))
                if case .failure(.speakerRejected(let detail)) = result {
                    mutateState { $0.dismissAlert() }
                    if await spotify.resumeSourcePlayback() {
                        return
                    }
                    if case .track(let track) = nowPlaying, let uri = track.spotifyURI {
                        let metadata = SpotifyTrackMetadata(
                            title: track.title,
                            artist: track.artist ?? "",
                            album: track.album,
                            artworkURL: track.artworkURL,
                            duration: track.duration
                        )
                        _ = await perform(
                            .enqueueAndPlaySpotify(
                                uri: uri,
                                metadata: metadata,
                                onCoordinator: group.id,
                                startingAt: elapsed
                            )
                        )
                    } else {
                        do throws(SpotifyBridgeError) {
                            let context = try await spotify.currentContext()
                            let handoff = await perform(
                                .enqueueAndPlaySpotify(
                                    uri: context.uri,
                                    metadata: context.metadata,
                                    onCoordinator: group.id,
                                    startingAt: context.position))
                            if case .success = handoff { await spotify.pauseSourcePlayback() }
                        } catch {
                            mutateState { $0.report(.commandFailed(.playPause(.play, group: group.id), .speakerRejected(detail: detail))) }
                        }
                    }
                }
            }
        case .stopped:
            Task {
                do throws(SpotifyBridgeError) {
                    let context = try await spotify.currentContext()
                    let result = await perform(
                        .enqueueAndPlaySpotify(
                            uri: context.uri,
                            metadata: context.metadata,
                            onCoordinator: group.id,
                            startingAt: context.position))
                    if case .success = result { await spotify.pauseSourcePlayback() }
                } catch {
                    if error == .notConnected {
                        mutateState { $0.report(.spotify(error)) }
                    } else {
                        _ = await perform(.playPause(.play, group: group.id))
                    }
                }
            }
        }
    }

    public func renamePreset(_ id: PresetID, to name: String) {
        mutateState { $0.renamePreset(id, to: name) }
        send(.savePresets(state.presets))
    }

    public func deletePreset(_ id: PresetID) {
        mutateState { $0.deletePreset(id) }
        send(.savePresets(state.presets))
    }

    public func renameSystem(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateState { $0.renameSystem(to: trimmed) }
        send(.setSystemName(trimmed))
    }

    public func dismissAlert() { mutateState { $0.dismissAlert() } }

    private func playbackRank(_ playback: PlaybackState) -> Int {
        switch playback {
        case .playing: return 2
        case .paused: return 1
        case .stopped: return 0
        }
    }

    private func perform(_ command: SonosCommand) async -> Result<CommandOutcome, SonosCommandError> {
        let ticket = mutateState { $0.begin(command) }
        let result: Result<CommandOutcome, SonosCommandError>
        do throws(SonosCommandError) {
            result = .success(try await sonos.send(command))
        } catch {
            result = .failure(error)
        }
        mutateState { $0.finish(ticket, with: result) }
        return result
    }

    package nonisolated static func mergedSeedIPs(cached: [String]) -> [String] {
        var seen: Set<String> = []
        return cached.filter { seen.insert($0).inserted }
    }

    private func persistChangedSlices() {
        let next = state.persisted
        if next.positions != written.positions, save(next.positions, to: .floorplanPositions) {
            written = PersistedSlices(cache: written.cache, positions: next.positions)
        }
        let rosterOrNameChanged = next.cache.speakers.map(\.id) != written.cache.speakers.map(\.id)
            || next.cache.networkName != written.cache.networkName
        let cacheIsDue = rosterOrNameChanged || Date().timeIntervalSince(lastCacheWrite) >= 30
        if next.cache != written.cache, cacheIsDue, save(next.cache, to: .cachedSpeakers) {
            written = PersistedSlices(cache: next.cache, positions: written.positions)
            lastCacheWrite = Date()
        }
    }

    private func persistChangedSlicesAsync() async {
        let next = state.persisted
        if next.positions != written.positions, await saveAsync(next.positions, to: .floorplanPositions) {
            written = PersistedSlices(cache: written.cache, positions: next.positions)
        }
        let rosterOrNameChanged = next.cache.speakers.map(\.id) != written.cache.speakers.map(\.id)
            || next.cache.networkName != written.cache.networkName
        let cacheIsDue = rosterOrNameChanged || Date().timeIntervalSince(lastCacheWrite) >= 30
        if next.cache != written.cache, cacheIsDue, await saveAsync(next.cache, to: .cachedSpeakers) {
            written = PersistedSlices(cache: next.cache, positions: written.positions)
            lastCacheWrite = Date()
        }
    }

    private func save<C>(_ content: C, to slot: FileSlot<C>) -> Bool {
        do {
            try files.save(content, to: slot)
            return true
        } catch {
            mutateState { $0.report(.quarantined(fileName: slot.name)) }
            return false
        }
    }

    private func saveAsync<C>(_ content: C, to slot: FileSlot<C>) async -> Bool {
        do {
            try await files.saveAsync(content, to: slot)
            return true
        } catch {
            mutateState { $0.report(.quarantined(fileName: slot.name)) }
            return false
        }
    }
}
