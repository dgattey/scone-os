import Foundation
import Observation
import SconeDomain
import SonosProtocolBoundary
import SpotifyBridge

/// The imperative shell around `SconeState`. It owns the one state value, feeds it snapshots and
/// command results, and writes whichever file slice changed after each transition. It holds no
/// rules of its own.
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

    /// Reads the three files before returning, so the first frame already shows the cached house.
    public static func live(spotify: SpotifyBridge) -> SconeStore {
        let files = SconeFiles(directory: URL.applicationSupportDirectory.appending(path: "SconeOS"))
        let loaded = files.loadAll()
        return SconeStore(
            loaded: loaded, files: files, sonos: SonosHousehold(seedIPs: loaded.seedIPs), spotify: spotify)
    }

    /// Call once from the root view's `.task`. Returns when that task is cancelled.
    public func run() async {
        for await snapshot in sonos.snapshots() {
            state.absorb(snapshot)
            persistChangedSlices()
        }
    }

    public func send(_ command: SonosCommand) {
        Task { _ = await perform(command) }
    }

    /// Reads what Spotify is playing, starts it on the group at the same position, then pauses
    /// the source so the song does not play in two places.
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

    /// The only place files are written. User slices write immediately. The cache changes every
    /// sweep (`lastSeenAt`), so it writes at most every 30 seconds.
    private func persistChangedSlices() {
        // TODO: compare state.persisted to `written` per slice; save changed user slices now; save the
        // cache when changed and lastCacheWrite is 30s old; update `written` for each slice saved.
        // A save error raises an alert and leaves `written` unchanged so the next transition retries.
        fatalError("not implemented")
    }
}
