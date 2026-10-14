import Foundation
import Observation
import SconeDomain
import SonosProtocolBoundary
import SpotifyBridge

@MainActor
@Observable
public final class SconeStore {
    public private(set) var state: SconeState

    @ObservationIgnored private let sonos: any SonosControl
    @ObservationIgnored private let spotify: any SpotifySource
    @ObservationIgnored private let files: SconeFiles
    @ObservationIgnored private var written: PersistedSlices
    @ObservationIgnored private var lastCacheWrite: Date = .distantPast

    public init(loaded: LoadedFiles, files: SconeFiles, sonos: any SonosControl, spotify: any SpotifySource) {
        let state = SconeState(loaded: loaded)
        self.state = state
        self.written = state.persisted
        self.files = files
        self.sonos = sonos
        self.spotify = spotify
    }

    public static func live(spotify: SpotifyBridge) -> SconeStore {
        let files = SconeFiles(directory: URL.applicationSupportDirectory.appending(path: "SconeOS"))
        let loaded = files.loadAll()
        return SconeStore(
            loaded: loaded,
            files: files,
            sonos: SonosHousehold(seedIPs: mergedSeedIPs(cached: loaded.seedIPs)),
            spotify: spotify)
    }

    public func run() async {
        for await snapshot in sonos.snapshots() {
            state.absorb(snapshot)
            persistChangedSlices()
        }
    }

    public func send(_ command: SonosCommand) {
        Task { _ = await perform(command) }
    }

    public func handOffSpotify(to group: GroupID) {
        Task {
            let context: SpotifyTrackContext
            do throws(SpotifyBridgeError) {
                context = try await spotify.currentContext()
            } catch {
                state.report(.spotify(error))
                return
            }
            let result = await perform(
                .enqueueAndPlaySpotify(
                    uri: context.uri, metadata: context.metadata, onCoordinator: group, startingAt: context.position))
            if case .success = result { await spotify.pauseSourcePlayback() }
        }
    }

    public func moveRoom(_ room: SpeakerUUID, to coordinate: RoomCoordinate) {
        state.pin(room, at: coordinate)
        persistChangedSlices()
    }

    public func resetRoom(_ room: SpeakerUUID) {
        state.unpin(room)
        persistChangedSlices()
    }

    public func savePreset(from group: GroupID, name: String? = nil) {
        state.savePreset(from: group, name: name)
        persistChangedSlices()
    }

    public func createPreset(name: String, coordinator: SpeakerUUID, members: Set<SpeakerUUID>) {
        state.createPreset(name: name, coordinator: coordinator, members: members)
        persistChangedSlices()
    }

    public func group(member: SpeakerUUID, onto targetSpeaker: SpeakerUUID) {
        guard member != targetSpeaker,
              let targetGroup = state.groupID(containing: targetSpeaker) else { return }
        send(.group(member: member, intoCoordinator: targetGroup))
    }

    public func togglePlayOrHandOffSpotify(for group: SonosGroup) {
        switch group.playback {
        case .playing:
            send(.playPause(.pause, group: group.id))
        case .paused:
            send(.playPause(.play, group: group.id))
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
                    _ = await perform(.playPause(.play, group: group.id))
                }
            }
        }
    }

    public func renamePreset(_ id: PresetID, to name: String) {
        state.renamePreset(id, to: name)
        persistChangedSlices()
    }

    public func deletePreset(_ id: PresetID) {
        state.deletePreset(id)
        persistChangedSlices()
    }

    public func dismissAlert() { state.dismissAlert() }

    private func perform(_ command: SonosCommand) async -> Result<CommandOutcome, SonosCommandError> {
        let ticket = state.begin(command)
        let result: Result<CommandOutcome, SonosCommandError>
        do throws(SonosCommandError) {
            result = .success(try await sonos.send(command))
        } catch {
            result = .failure(error)
        }
        state.finish(ticket, with: result)
        return result
    }

    package nonisolated static func mergedSeedIPs(cached: [String]) -> [String] {
        var seen: Set<String> = []
        return (cached + fallbackSeedIPs).filter { seen.insert($0).inserted }
    }

    private nonisolated static let fallbackSeedIPs = [
        "192.168.68.58", "192.168.68.71", "192.168.68.73",
        "192.168.68.90", "192.168.68.92", "192.168.68.95",
    ]

    private func persistChangedSlices() {
        let next = state.persisted
        if next.presets != written.presets, save(next.presets, to: .presets) {
            written = PersistedSlices(cache: written.cache, presets: next.presets, positions: written.positions)
        }
        if next.positions != written.positions, save(next.positions, to: .floorplanPositions) {
            written = PersistedSlices(cache: written.cache, presets: written.presets, positions: next.positions)
        }
        let cacheIsDue = Date().timeIntervalSince(lastCacheWrite) >= 30
        if next.cache != written.cache, cacheIsDue, save(next.cache, to: .cachedSpeakers) {
            written = PersistedSlices(cache: next.cache, presets: written.presets, positions: written.positions)
            lastCacheWrite = Date()
        }
    }

    private func save<C>(_ content: C, to slot: FileSlot<C>) -> Bool {
        do {
            try files.save(content, to: slot)
            return true
        } catch {
            state.report(.quarantined(fileName: slot.name))
            return false
        }
    }
}
