import Foundation

/// A desired transport state, never a toggle. Sending `.play` twice leaves the group playing.
/// Sending a toggle twice would undo itself, so a retried request could flip the music back off.
public enum PlayPause: Hashable, Sendable {
    case play, pause
}

public enum PlaybackState: Hashable, Sendable {
    case stopped
    case paused(NowPlaying, elapsed: Duration)
    /// `elapsed` was sampled at `sampledAt`. Views interpolate with `elapsed(at:)` in a
    /// `TimelineView` instead of polling the speaker every second.
    case playing(NowPlaying, elapsed: Duration, sampledAt: Date)

    public var nowPlaying: NowPlaying? {
        switch self {
        case .stopped: nil
        case .paused(let nowPlaying, _), .playing(let nowPlaying, _, _): nowPlaying
        }
    }

    public func elapsed(at now: Date) -> Duration? {
        fatalError("not implemented")
    }
}

public enum NowPlaying: Hashable, Sendable {
    case track(NowPlayingTrack)
    /// `x-sonos-htastream:`, the Beam's HDMI ARC input.
    case tvAudio
    /// Radio, line-in, or any source without a queue. `title` is the station or stream name.
    case stream(title: String?)
}

public struct NowPlayingTrack: Hashable, Sendable {
    public let title: String
    public let artist: String?
    public let album: String?
    /// Absolute. The boundary resolves the speaker-relative `/getaa?...` path against the coordinator.
    public let artworkURL: URL?
    public let duration: Duration?
    /// 1-based queue index. nil when the coordinator is not playing from its queue, which is
    /// exactly when next and previous have no meaning. Views disable skip buttons on nil.
    public let queuePosition: Int?
    /// Set when the track URI is `x-sonos-spotify:`.
    public let spotifyURI: SpotifyURI?

    public init(
        title: String, artist: String?, album: String?, artworkURL: URL?,
        duration: Duration?, queuePosition: Int?, spotifyURI: SpotifyURI?
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.duration = duration
        self.queuePosition = queuePosition
        self.spotifyURI = spotifyURI
    }
}
