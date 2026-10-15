import SconeDomain
import SonosProtocolBoundary
import SpotifyBridge

public protocol SonosControl: Sendable {
    func snapshots() -> AsyncStream<HouseholdSnapshot>
    func send(_ command: SonosCommand) async throws(SonosCommandError) -> CommandOutcome
}

extension SonosHousehold: SonosControl {}

@MainActor
public protocol SpotifySource: AnyObject {
    func currentContext() async throws(SpotifyBridgeError) -> SpotifyTrackContext
    func currentContext(forceRefresh: Bool) async throws(SpotifyBridgeError) -> SpotifyTrackContext
    func pauseSourcePlayback() async
    func resumeSourcePlayback() async -> Bool
    func playOnSonosGroup(
        coordinatorRoomName: String,
        memberRoomNames: [String],
        context: SpotifyTrackContext?
    ) async -> Bool
}

public extension SpotifySource {
    func currentContext(forceRefresh: Bool) async throws(SpotifyBridgeError) -> SpotifyTrackContext {
        try await currentContext()
    }

    func playOnSonosGroup(
        coordinatorRoomName: String,
        memberRoomNames: [String],
        context: SpotifyTrackContext?
    ) async -> Bool {
        false
    }
}

extension SpotifyBridge: SpotifySource {}
