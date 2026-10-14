import Foundation
import SconeDomain

enum TransportService {
    static let getTransportInfo = SOAPRequest(service: .avTransport, action: "GetTransportInfo", arguments: [("InstanceID", "0")])
    static let getPositionInfo = SOAPRequest(service: .avTransport, action: "GetPositionInfo", arguments: [("InstanceID", "0")])
    static let getMediaInfo = SOAPRequest(service: .avTransport, action: "GetMediaInfo", arguments: [("InstanceID", "0")])
    static let getVolume = SOAPRequest(
        service: .renderingControl, action: "GetVolume", arguments: [("InstanceID", "0"), ("Channel", "Master")])
    static let getGroupVolume = SOAPRequest(service: .groupRenderingControl, action: "GetGroupVolume", arguments: [("InstanceID", "0")])

    static func parsePlayback(
        transportInfo: XMLNode, positionInfo: XMLNode, mediaInfo: XMLNode,
        coordinatorEndpoint: URL, sampledAt: Date
    ) -> PlaybackState {
        let activity = activity(transportInfo.value("CurrentTransportState"))
        let trackURI = positionInfo.value("TrackURI")
        let currentURI = mediaInfo.value("CurrentURI")
        if trackURI.hasPrefix("x-sonos-htastream:") || currentURI.hasPrefix("x-sonos-htastream:") {
            let elapsed = clock(positionInfo.value("RelTime")) ?? .zero
            switch activity {
            case .playing: return .playing(.tvAudio, elapsed: elapsed, sampledAt: sampledAt)
            case .paused, .stopped: return .paused(.tvAudio, elapsed: elapsed)
            }
        }

        let facts = mergedFacts(track: positionInfo.value("TrackMetaData"), current: mediaInfo.value("CurrentURIMetaData"))
        if activity == .stopped, facts.title.isEmpty, facts.streamContent.isEmpty {
            return .stopped
        }
        let elapsed = clock(positionInfo.value("RelTime")) ?? .zero
        let spotify = spotifyTrack(in: trackURI) ?? spotifyTrack(in: currentURI)
        let queued = currentURI.hasPrefix("x-rincon-queue:")
        let now: NowPlaying
        if queued || spotify != nil || !facts.title.isEmpty {
            let trackNumber = Int(positionInfo.value("Track")) ?? 0
            let artist = facts.creator.isEmpty ? facts.streamContent.nilIfEmpty : facts.creator.nilIfEmpty
            now = .track(NowPlayingTrack(
                title: facts.title,
                artist: artist,
                album: facts.album.nilIfEmpty,
                artworkURL: artwork(facts.art, relativeTo: coordinatorEndpoint),
                duration: clock(positionInfo.value("TrackDuration")),
                queuePosition: queued && trackNumber > 0 ? trackNumber : nil,
                spotifyURI: spotify))
        } else {
            now = .stream(title: facts.title.nilIfEmpty ?? facts.streamContent.nilIfEmpty)
        }
        switch activity {
        case .playing: return .playing(now, elapsed: elapsed, sampledAt: sampledAt)
        case .paused, .stopped: return .paused(now, elapsed: elapsed)
        }
    }

    static func parseVolume(_ response: XMLNode) -> DiscreteVolume {
        DiscreteVolume(snappingPercent: Int(response.child("CurrentVolume")?.text ?? "") ?? 0)
    }

    static func setVolume(_ volume: DiscreteVolume) -> SOAPRequest {
        SOAPRequest(
            service: .renderingControl, action: "SetVolume",
            arguments: [("InstanceID", "0"), ("Channel", "Master"), ("DesiredVolume", String(volume.percent))])
    }

    static func setGroupVolume(_ volume: DiscreteVolume) -> SOAPRequest {
        SOAPRequest(
            service: .groupRenderingControl, action: "SetGroupVolume",
            arguments: [("InstanceID", "0"), ("DesiredVolume", String(volume.percent))])
    }

    static func transport(_ desired: PlayPause) -> SOAPRequest {
        switch desired {
        case .play: SOAPRequest(service: .avTransport, action: "Play", arguments: [("InstanceID", "0"), ("Speed", "1")])
        case .pause: SOAPRequest(service: .avTransport, action: "Pause", arguments: [("InstanceID", "0")])
        }
    }

    static func seek(toTrack number: Int) -> SOAPRequest {
        SOAPRequest(service: .avTransport, action: "Seek", arguments: [("InstanceID", "0"), ("Unit", "TRACK_NR"), ("Target", String(number))])
    }

    static func seek(to elapsed: Duration) -> SOAPRequest {
        let parts = elapsed.components
        let rounded = parts.attoseconds >= 500_000_000_000_000_000 ? Int64(1) : 0
        let total = max(0, Int(parts.seconds + rounded))
        let target = String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        return SOAPRequest(
            service: .avTransport, action: "Seek",
            arguments: [("InstanceID", "0"), ("Unit", "REL_TIME"), ("Target", target)])
    }

    private enum Activity { case playing, paused, stopped }

    private struct DIDLFacts {
        var title = ""
        var creator = ""
        var streamContent = ""
        var album = ""
        var art = ""
    }

    private static func activity(_ state: String) -> Activity {
        switch state {
        case "PLAYING", "TRANSITIONING": .playing
        case "PAUSED_PLAYBACK": .paused
        default: .stopped
        }
    }

    private static func mergedFacts(track: String, current: String) -> DIDLFacts {
        let primary = facts(from: track)
        let secondary = facts(from: current)
        return DIDLFacts(
            title: primary.title.isEmpty ? secondary.title : primary.title,
            creator: primary.creator.isEmpty ? secondary.creator : primary.creator,
            streamContent: primary.streamContent.isEmpty ? secondary.streamContent : primary.streamContent,
            album: primary.album.isEmpty ? secondary.album : primary.album,
            art: primary.art.isEmpty ? secondary.art : primary.art)
    }

    private static func facts(from xml: String) -> DIDLFacts {
        let trimmed = xml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let root = try? XMLNode.parse(Data(trimmed.utf8)) else { return DIDLFacts() }
        func text(_ name: String) -> String {
            root.descendants(name).first?.text ?? ""
        }
        return DIDLFacts(
            title: text("title"), creator: text("creator"), streamContent: text("streamContent"),
            album: text("album"), art: text("albumArtURI"))
    }

    private static func spotifyTrack(in raw: String) -> SpotifyURI? {
        let decoded = raw.removingPercentEncoding ?? raw
        guard let range = decoded.range(of: "spotify:track:") else { return nil }
        var id = ""
        for character in decoded[range.upperBound...] {
            if character.isLetter || character.isNumber { id.append(character) } else { break }
        }
        guard !id.isEmpty else { return nil }
        return SpotifyURI("spotify:track:\(id)")
    }

    private static func clock(_ text: String) -> Duration? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "NOT_IMPLEMENTED" { return nil }
        let parts = trimmed.split(separator: ":")
        guard parts.count == 3, let hours = Int(parts[0]), let minutes = Int(parts[1]), let seconds = Int(parts[2]) else {
            return nil
        }
        return .seconds(hours * 3600 + minutes * 60 + seconds)
    }

    private static func artwork(_ raw: String, relativeTo endpoint: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return URL(string: trimmed) }
        return sonosURL(endpoint: endpoint, path: trimmed)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
