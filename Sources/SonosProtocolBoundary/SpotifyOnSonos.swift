import Foundation
import SconeDomain

/// How a Spotify URI becomes something a Sonos queue accepts. The PoC did not exercise any of
/// this, so it is the first thing to prototype against the household.
enum SpotifyOnSonos {
    /// The household's linked Spotify account. `serialNumber` is the `sn=` query value and is
    /// specific to this household. `regionToken` goes into DIDL `<desc>` (`SA_RINCON2311_X_#Svc2311-0-Token`
    /// in the US, a different service number elsewhere).
    struct Account: Sendable, Hashable {
        let serviceID: Int
        let serialNumber: Int
        let regionToken: String
    }

    /// Reads an existing `x-sonos-spotify:` item from favorites (`ContentDirectory` Browse of `FV:2`)
    /// or the queue and lifts `sid`, `sn`, and the `<desc>` token from it. Cached for the session.
    static func discoverAccount(using client: SOAPClient, coordinator: SpeakerUUID, at endpoint: URL)
        async throws(SonosCommandError) -> Account
    {
        fatalError("not implemented")
    }

    /// Tracks: `x-sonos-spotify:spotify%3atrack%3a<id>?sid=<sid>&flags=8224&sn=<sn>`.
    /// Albums and playlists: `x-rincon-cpcontainer:` with the container prefix for that kind.
    static func enqueueURI(for uri: SpotifyURI, account: Account) -> String {
        fatalError("not implemented")
    }

    static func didl(for metadata: SpotifyTrackMetadata, uri: SpotifyURI, account: Account) -> String {
        fatalError("not implemented")
    }

    /// `AddURIToQueue` with `EnqueueAsNext=1` after the current position, then `Seek(TRACK_NR,
    /// FirstTrackNumberEnqueued)`, `Play`, and `Seek(REL_TIME)` when `startingAt` is set.
    static func requests(
        uri: String, didl: String, currentQueuePosition: Int?, startingAt: Duration?
    ) -> [SOAPRequest] {
        fatalError("not implemented")
    }
}
