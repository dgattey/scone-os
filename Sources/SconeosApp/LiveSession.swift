import Foundation
import SconeStore
import SpotifyBridge

@MainActor
struct LiveSession {
    let spotify: SpotifyBridge
    let store: SconeStore

    /// Every window awaits the same load, so a second window never builds a second Sonos household.
    static let shared = Task { await load() }

    private static func load() async -> LiveSession {
        let spotify = await SpotifyBridge.restore(redirectURI: URL(string: "sconeos://spotify-callback")!)
        let store = await SconeStore.live(spotify: spotify)
        return LiveSession(spotify: spotify, store: store)
    }
}
