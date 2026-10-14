import Foundation

public enum PlayPause: Hashable, Sendable {
    case play, pause
}

public enum PlaybackState: Hashable, Sendable {
    case stopped
    case paused(NowPlaying, elapsed: Duration)
    case playing(NowPlaying, elapsed: Duration, sampledAt: Date)

    public var nowPlaying: NowPlaying? {
        switch self {
        case .stopped: nil
        case .paused(let nowPlaying, _), .playing(let nowPlaying, _, _): nowPlaying
        }
    }

    public func elapsed(at now: Date) -> Duration? {
        switch self {
        case .stopped:
            return nil
        case .paused(_, let elapsed):
            return elapsed
        case .playing(let nowPlaying, let elapsed, let sampledAt):
            let advanced = elapsed + max(.zero, .seconds(now.timeIntervalSince(sampledAt)))
            guard case .track(let track) = nowPlaying, let duration = track.duration else { return advanced }
            return min(advanced, duration)
        }
    }
}

public enum NowPlaying: Hashable, Sendable {
    case track(NowPlayingTrack)
    case tvAudio
    case stream(title: String?)
}

public struct NowPlayingTrack: Hashable, Sendable {
    public let title: String
    public let artist: String?
    public let album: String?
    public let artworkURL: URL?
    public let duration: Duration?
    public let queuePosition: Int?
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
