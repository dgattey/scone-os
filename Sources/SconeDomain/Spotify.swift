import Foundation

/// A Spotify item Sonos can play. Shared by the bridge (which produces it) and the Sonos
/// boundary (which encodes it as `x-sonos-spotify:` or `x-rincon-cpcontainer:`).
public struct SpotifyURI: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Kind: String, Hashable, Sendable, Codable {
        case track, album, playlist
    }

    public let kind: Kind
    /// 22-character base62 id.
    public let id: String

    /// Accepts `spotify:track:<id>` and `https://open.spotify.com/track/<id>`. Rejects
    /// `spotify:local:...`, episodes, and anything else Sonos cannot stream.
    public init?(_ string: String) {
        fatalError("not implemented")
    }

    public var description: String { "spotify:\(kind.rawValue):\(id)" }
}

public struct SpotifyTrackMetadata: Hashable, Sendable {
    public let title: String
    public let artist: String
    public let album: String?
    public let artworkURL: URL?
    public let duration: Duration?

    public init(title: String, artist: String, album: String?, artworkURL: URL?, duration: Duration?) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.duration = duration
    }
}

/// What the person is listening to right now, ready to hand to a Sonos group.
public struct SpotifyTrackContext: Hashable, Sendable {
    public let uri: SpotifyURI
    public let metadata: SpotifyTrackMetadata
    /// Where the source player is, so the hand-off resumes mid-song instead of restarting it.
    public let position: Duration?

    public init(uri: SpotifyURI, metadata: SpotifyTrackMetadata, position: Duration?) {
        self.uri = uri
        self.metadata = metadata
        self.position = position
    }
}
