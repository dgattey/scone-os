import Foundation

public struct SpotifyURI: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Kind: String, Hashable, Sendable, Codable {
        case track, album, playlist
    }

    public let kind: Kind
    public let id: String

    public init?(_ string: String) {
        guard let parsed = Self.parseURI(string) ?? Self.parseOpenURL(string) else { return nil }
        self.kind = parsed.kind
        self.id = parsed.id
    }

    private static func parseURI(_ string: String) -> (kind: Kind, id: String)? {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "spotify", let kind = Kind(rawValue: String(parts[1])) else { return nil }
        let id = String(parts[2])
        guard isPlayableID(id) else { return nil }
        return (kind, id)
    }

    private static func parseOpenURL(_ string: String) -> (kind: Kind, id: String)? {
        var text = string
        if let query = text.firstIndex(of: "?") { text = String(text[..<query]) }
        if let fragment = text.firstIndex(of: "#") { text = String(text[..<fragment]) }
        let prefix = "https://open.spotify.com/"
        guard text.hasPrefix(prefix) else { return nil }
        var path = text.dropFirst(prefix.count)
        if path.hasSuffix("/") { path.removeLast() }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let kind = Kind(rawValue: String(parts[0])) else { return nil }
        let id = String(parts[1])
        guard isPlayableID(id) else { return nil }
        return (kind, id)
    }

    private static func isPlayableID(_ id: String) -> Bool {
        guard (15...30).contains(id.count) else { return false }
        return id.allSatisfy { character in
            switch character {
            case "A"..."Z", "a"..."z", "0"..."9": true
            default: false
            }
        }
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

public struct SpotifyTrackContext: Hashable, Sendable {
    public let uri: SpotifyURI
    public let metadata: SpotifyTrackMetadata
    public let position: Duration?
    public let contextTitle: String?
    public let contextURI: String?
    public let deviceID: String?
    public let deviceName: String?
    public let deviceType: String?
    public let isPlaying: Bool
    /// Spotify's `shuffle_state`, or nil when the player didn't report one.
    public let isShuffling: Bool?
    public let upNext: [QueueItem]

    public init(
        uri: SpotifyURI,
        metadata: SpotifyTrackMetadata,
        position: Duration?,
        contextTitle: String? = nil,
        contextURI: String? = nil,
        deviceID: String? = nil,
        deviceName: String? = nil,
        deviceType: String? = nil,
        isPlaying: Bool = false,
        isShuffling: Bool? = nil,
        upNext: [QueueItem] = []
    ) {
        self.uri = uri
        self.metadata = metadata
        self.position = position
        self.contextTitle = contextTitle
        self.contextURI = contextURI
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.isPlaying = isPlaying
        self.isShuffling = isShuffling
        self.upNext = upNext
    }

    public var externalDeviceDisplayName: String {
        if Self.isLocalComputerDevice(name: deviceName, type: deviceType) {
            return "This computer"
        }
        if let name = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return "Spotify"
    }

    public var externalPlaybackLabel: String {
        "Playing on \(externalDeviceDisplayName)"
    }

    public static func isLocalComputerDevice(name: String?, type: String?) -> Bool {
        if let type = type?.trimmingCharacters(in: .whitespacesAndNewlines),
           type.caseInsensitiveCompare("Computer") == .orderedSame {
            return true
        }
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return false
        }
        if trimmed.caseInsensitiveCompare("This computer") == .orderedSame
            || trimmed.caseInsensitiveCompare("This Mac") == .orderedSame {
            return true
        }
        let lower = trimmed.lowercased()
        if lower.contains("macbook") || lower.contains(" mbp") || lower.hasSuffix("mbp")
            || lower.contains("imac") || lower.contains("mac studio") || lower.contains("mac mini")
            || lower.contains("mac pro") {
            return true
        }
        #if os(macOS)
        if let localName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !localName.isEmpty,
           trimmed.caseInsensitiveCompare(localName) == .orderedSame {
            return true
        }
        #endif
        return false
    }
}
