import SconeDomain
import SonosProtocolBoundary
import SpotifyBridge

/// What the store needs from a Sonos household. `SonosHousehold` is the real one, and tests use a
/// fake that yields scripted snapshots.
public protocol SonosControl: Sendable {
    func snapshots() -> AsyncStream<HouseholdSnapshot>
    func send(_ command: SonosCommand) async throws(SonosCommandError) -> CommandOutcome
}

extension SonosHousehold: SonosControl {}

@MainActor
public protocol SpotifySource: AnyObject {
    func currentContext() async throws(SpotifyBridgeError) -> SpotifyTrackContext
    func pauseSourcePlayback() async
}

extension SpotifyBridge: SpotifySource {}
