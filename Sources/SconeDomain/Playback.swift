import Foundation

public enum PlayPause: Hashable, Sendable {
    case play, pause
}

public enum PlaybackSource: Hashable, Sendable, Codable {
    case spotify(contextTitle: String? = nil)
    case sonosQueue
    case tvAudio
    case radio
    case lineIn

    public var label: String {
        switch self {
        case .spotify(let contextTitle):
            if let title = contextTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty,
               title.lowercased() != "spotify" {
                return "Playing from Spotify · \(title)"
            }
            return "Playing from Spotify"
        case .sonosQueue:
            return "Sonos Queue"
        case .tvAudio:
            return "TV Audio"
        case .radio:
            return "Radio Stream"
        case .lineIn:
            return "Line-In"
        }
    }

    public var shortBadge: String {
        switch self {
        case .spotify(let contextTitle):
            if let title = contextTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty,
               title.lowercased() != "spotify" {
                return "Spotify · \(title)"
            }
            return "Spotify"
        case .sonosQueue:
            return "Queue"
        case .tvAudio:
            return "TV"
        case .radio:
            return "Radio"
        case .lineIn:
            return "Line-In"
        }
    }

    public var isSpotify: Bool {
        if case .spotify = self { return true }
        return false
    }
}

public struct QueueItem: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let title: String
    public let artist: String?
    public let album: String?
    public let artworkURL: URL?
    public let duration: Duration?
    public let spotifyURI: SpotifyURI?

    public init(
        id: String? = nil,
        title: String,
        artist: String?,
        album: String? = nil,
        artworkURL: URL? = nil,
        duration: Duration? = nil,
        spotifyURI: SpotifyURI? = nil
    ) {
        self.id = id ?? "\(spotifyURI?.description ?? title):\(artist ?? "")"
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.duration = duration
        self.spotifyURI = spotifyURI
    }
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

    public func isSemanticallyEquivalent(to other: PlaybackState) -> Bool {
        switch (self, other) {
        case (.stopped, .stopped):
            return true
        case (.paused(let lhsNow, let lhsElapsed), .paused(let rhsNow, let rhsElapsed)):
            return lhsNow == rhsNow && lhsElapsed == rhsElapsed
        case (.playing(let lhsNow, let lhsElapsed, let lhsSampled),
              .playing(let rhsNow, let rhsElapsed, let rhsSampled)):
            guard lhsNow == rhsNow else { return false }
            let lhsSeconds = Double(lhsElapsed.components.seconds) + Double(lhsElapsed.components.attoseconds) / 1e18
            let rhsSeconds = Double(rhsElapsed.components.seconds) + Double(rhsElapsed.components.attoseconds) / 1e18
            let expectedRhs = lhsSeconds + max(0, rhsSampled.timeIntervalSince(lhsSampled))
            return abs(rhsSeconds - expectedRhs) <= 3.0
        default:
            return false
        }
    }
}

public enum NowPlaying: Hashable, Sendable {
    case track(NowPlayingTrack)
    case tvAudio
    case stream(title: String?)

    public var isSpotifyOrStreaming: Bool {
        switch self {
        case .track(let track):
            return track.isSpotifyStream
        case .stream:
            return true
        case .tvAudio:
            return false
        }
    }

    public func matchesSession(of other: NowPlaying) -> Bool {
        switch (self, other) {
        case (.track(let lhs), .track(let rhs)):
            if lhs.matchesIdentity(of: rhs) { return true }
            if lhs.isSpotifyStream && rhs.isSpotifyStream { return true }
            return false
        case (.stream(let lhsTitle), .stream(let rhsTitle)):
            guard let l = lhsTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let r = rhsTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !l.isEmpty, !r.isEmpty else {
                return false
            }
            return l.caseInsensitiveCompare(r) == .orderedSame
        default:
            return false
        }
    }
}

public struct NowPlayingTrack: Hashable, Sendable {
    public let title: String
    public let artist: String?
    public let album: String?
    public let artworkURL: URL?
    public let duration: Duration?
    public let queuePosition: Int?
    public let spotifyURI: SpotifyURI?
    public let source: PlaybackSource?
    public let upNext: [QueueItem]
    public let canSkip: Bool
    /// Spotify's live shuffle state for this session, or nil when Spotify isn't driving it.
    public let isShuffling: Bool?

    public init(
        title: String,
        artist: String?,
        album: String?,
        artworkURL: URL?,
        duration: Duration?,
        queuePosition: Int?,
        spotifyURI: SpotifyURI?,
        source: PlaybackSource? = nil,
        upNext: [QueueItem] = [],
        canSkip: Bool? = nil,
        isShuffling: Bool? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.duration = duration
        self.queuePosition = queuePosition
        self.spotifyURI = spotifyURI
        self.source = source ?? (spotifyURI != nil ? .spotify() : (queuePosition != nil ? .sonosQueue : nil))
        self.upNext = upNext
        self.canSkip = canSkip ?? (queuePosition != nil || spotifyURI != nil)
        self.isShuffling = isShuffling
    }

    public func merging(
        artworkURL: URL? = nil,
        source: PlaybackSource? = nil,
        upNext: [QueueItem]? = nil,
        canSkip: Bool? = nil,
        isShuffling: Bool? = nil
    ) -> NowPlayingTrack {
        NowPlayingTrack(
            title: title,
            artist: artist,
            album: album,
            artworkURL: artworkURL ?? self.artworkURL,
            duration: duration,
            queuePosition: queuePosition,
            spotifyURI: spotifyURI,
            source: source ?? self.source,
            upNext: upNext ?? self.upNext,
            canSkip: canSkip ?? self.canSkip,
            isShuffling: isShuffling ?? self.isShuffling
        )
    }

    public var isSpotifyStream: Bool {
        spotifyURI != nil || (source?.isSpotify == true)
    }

    public func matchesIdentity(of other: NowPlayingTrack) -> Bool {
        if let lhsURI = spotifyURI, let rhsURI = other.spotifyURI {
            return lhsURI == rhsURI
        }
        let lhsTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsTitle = other.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lhsTitle.isEmpty,
              lhsTitle.caseInsensitiveCompare(rhsTitle) == .orderedSame else {
            return false
        }
        let lhsArtist = (artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsArtist = (other.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if lhsArtist.isEmpty || rhsArtist.isEmpty {
            return true
        }
        return lhsArtist.caseInsensitiveCompare(rhsArtist) == .orderedSame
    }
}
