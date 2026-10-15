import Foundation
import SconeDomain

enum TransportService {
    static let getTransportInfo = SOAPRequest(service: .avTransport, action: "GetTransportInfo", arguments: [("InstanceID", "0")])
    static let getPositionInfo = SOAPRequest(service: .avTransport, action: "GetPositionInfo", arguments: [("InstanceID", "0")])
    static let getMediaInfo = SOAPRequest(service: .avTransport, action: "GetMediaInfo", arguments: [("InstanceID", "0")])
    static let getVolume = SOAPRequest(
        service: .renderingControl, action: "GetVolume", arguments: [("InstanceID", "0"), ("Channel", "Master")])
    static let getGroupVolume = SOAPRequest(service: .groupRenderingControl, action: "GetGroupVolume", arguments: [("InstanceID", "0")])
    static let next = SOAPRequest(service: .avTransport, action: "Next", arguments: [("InstanceID", "0")])
    static let previous = SOAPRequest(service: .avTransport, action: "Previous", arguments: [("InstanceID", "0")])

    static func browseQueue(startingAt start: Int = 0, count: Int = 25) -> SOAPRequest {
        SOAPRequest(
            service: .queue,
            action: "Browse",
            arguments: [
                ("QueueID", "0"),
                ("StartingIndex", String(max(0, start))),
                ("RequestedCount", String(max(1, count))),
            ]
        )
    }

    static func browseContentDirectoryQueue(startingAt start: Int = 0, count: Int = 25) -> SOAPRequest {
        SOAPRequest(
            service: .contentDirectory,
            action: "Browse",
            arguments: [
                ("ObjectID", "Q:0"),
                ("BrowseFlag", "BrowseDirectChildren"),
                ("Filter", "*"),
                ("StartingIndex", String(max(0, start))),
                ("RequestedCount", String(max(1, count))),
                ("SortCriteria", ""),
            ]
        )
    }

    static func parsePlayback(
        transportInfo: XMLNode,
        positionInfo: XMLNode,
        mediaInfo: XMLNode,
        queueItems: [QueueItem] = [],
        coordinatorEndpoint: URL,
        sampledAt: Date
    ) -> PlaybackState {
        let activity = activity(transportInfo.value("CurrentTransportState"))
        if activity == .stopped {
            return .stopped
        }
        let trackURI = positionInfo.value("TrackURI")
        let currentURI = mediaInfo.value("CurrentURI")
        if trackURI.hasPrefix("x-sonos-htastream:") || currentURI.hasPrefix("x-sonos-htastream:") {
            let elapsed = clock(positionInfo.value("RelTime")) ?? .zero
            switch activity {
            case .playing: return .playing(.tvAudio, elapsed: elapsed, sampledAt: sampledAt)
            case .paused: return .paused(.tvAudio, elapsed: elapsed)
            case .stopped: return .stopped
            }
        }
        let trackMeta = positionInfo.value("TrackMetaData")
        let currentMeta = mediaInfo.value("CurrentURIMetaData")
        let facts = mergedFacts(track: trackMeta, current: currentMeta)
        let elapsed = clock(positionInfo.value("RelTime")) ?? .zero
        let spotify = spotifyTrack(in: trackURI)
            ?? spotifyTrack(in: currentURI)
            ?? spotifyTrack(in: facts.resURI)
            ?? spotifyTrack(in: trackMeta)
        let isSpotifyOrigin = spotify != nil
            || isSpotifyURI(trackURI)
            || isSpotifyURI(currentURI)
            || isSpotifyURI(facts.resURI)
            || currentMeta.lowercased().contains("spotify")
        let queued = currentURI.hasPrefix("x-rincon-queue:")
        let now: NowPlaying
        if queued || isSpotifyOrigin || !facts.title.isEmpty {
            let trackNumber = Int(positionInfo.value("Track")) ?? 0
            let artist = facts.creator.isEmpty ? facts.streamContent.nilIfEmpty : facts.creator.nilIfEmpty
            let contextTitle = extractContextTitle(currentMeta: currentMeta, trackFacts: facts)
            let source: PlaybackSource = if isSpotifyOrigin {
                .spotify(contextTitle: contextTitle)
            } else if queued {
                .sonosQueue
            } else {
                .radio
            }

            let resolvedQueuePosition = queued && trackNumber > 0 ? trackNumber : nil
            let filteredUpNext: [QueueItem] = if let pos = resolvedQueuePosition {
                queueItems.filter { ($0.queueNumber ?? 0) > pos }
            } else {
                queueItems
            }

            now = .track(NowPlayingTrack(
                title: facts.title,
                artist: artist,
                album: facts.album.nilIfEmpty,
                artworkURL: artwork(facts.art, relativeTo: coordinatorEndpoint),
                duration: clock(positionInfo.value("TrackDuration")),
                queuePosition: resolvedQueuePosition,
                spotifyURI: spotify,
                source: source,
                upNext: filteredUpNext,
                canSkip: queued || isSpotifyOrigin
            ))
        } else {
            now = .stream(title: facts.title.nilIfEmpty ?? facts.streamContent.nilIfEmpty)
        }
        switch activity {
        case .playing: return .playing(now, elapsed: elapsed, sampledAt: sampledAt)
        case .paused: return .paused(now, elapsed: elapsed)
        case .stopped: return .stopped
        }
    }

    static func parseQueueBrowseResponse(
        _ response: XMLNode,
        startingIndex: Int = 0,
        coordinatorEndpoint: URL
    ) -> [QueueItem] {
        guard let root = parseDIDLRoot(response.value("Result")) else {
            return []
        }
        let items = root.descendants("item")
        return items.enumerated().compactMap { offset, itemNode -> QueueItem? in
            let title = itemNode.descendants("title").first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            let creator = itemNode.descendants("creator").first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let album = itemNode.descendants("album").first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let artRaw = itemNode.descendants("albumArtURI").first?.text ?? ""
            let resNode = itemNode.descendants("res").first
            let resText = resNode?.text ?? ""
            let duration = resNode?.attribute("duration").flatMap(clock)
            let itemIDAttr = itemNode.attribute("id") ?? ""
            let parsedQueueIndex: Int = {
                if let slash = itemIDAttr.lastIndex(of: "/"),
                   let num = Int(itemIDAttr[itemIDAttr.index(after: slash)...]),
                   num > 0 {
                    return num
                }
                return startingIndex + offset + 1
            }()
            let spotify = spotifyTrack(in: resText) ?? spotifyTrack(in: itemIDAttr)
            return QueueItem(
                title: title,
                artist: creator?.nilIfEmpty,
                album: album?.nilIfEmpty,
                artworkURL: artwork(artRaw, relativeTo: coordinatorEndpoint),
                duration: duration,
                queueNumber: parsedQueueIndex,
                spotifyURI: spotify
            )
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
        var resURI = ""
        var upnpClass = ""
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
        let resolvedTitle: String = {
            if !primary.title.isEmpty { return primary.title }
            if secondary.title.lowercased() == "spotify" { return "" }
            return secondary.title
        }()
        return DIDLFacts(
            title: resolvedTitle,
            creator: primary.creator.isEmpty ? secondary.creator : primary.creator,
            streamContent: primary.streamContent.isEmpty ? secondary.streamContent : primary.streamContent,
            album: primary.album.isEmpty ? secondary.album : primary.album,
            art: primary.art.isEmpty ? secondary.art : primary.art,
            resURI: primary.resURI.isEmpty ? secondary.resURI : primary.resURI,
            upnpClass: primary.upnpClass.isEmpty ? secondary.upnpClass : primary.upnpClass
        )
    }

    private static func parseDIDLRoot(_ xml: String) -> XMLNode? {
        let trimmed = xml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "NOT_IMPLEMENTED" else { return nil }
        if let root = try? XMLNode.parse(Data(trimmed.utf8)) {
            return root
        }
        let unescaped = unescapeXML(trimmed)
        return try? XMLNode.parse(Data(unescaped.utf8))
    }

    private static func facts(from xml: String) -> DIDLFacts {
        guard let root = parseDIDLRoot(xml) else { return DIDLFacts() }
        func text(_ name: String) -> String {
            root.descendants(name).first?.text ?? ""
        }
        return DIDLFacts(
            title: text("title"),
            creator: text("creator"),
            streamContent: text("streamContent"),
            album: text("album"),
            art: text("albumArtURI"),
            resURI: text("res"),
            upnpClass: text("class")
        )
    }

    private static func extractContextTitle(currentMeta: String, trackFacts: DIDLFacts) -> String? {
        let currentFacts = facts(from: currentMeta)
        let candidate = currentFacts.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.isEmpty,
           candidate.lowercased() != "spotify",
           candidate != trackFacts.title {
            return candidate
        }
        return nil
    }

    private static func isSpotifyURI(_ raw: String) -> Bool {
        let lowered = (raw.removingPercentEncoding ?? raw).lowercased()
        return lowered.contains("spotify:")
            || lowered.contains("x-sonos-spotify:")
            || lowered.contains("x-sonos-vli:") && lowered.contains("spotify")
    }

    private static func spotifyTrack(in raw: String) -> SpotifyURI? {
        let unescaped = unescapeXML(raw)
        let decoded = unescaped.removingPercentEncoding ?? unescaped
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

    static func artwork(_ raw: String, relativeTo endpoint: URL) -> URL? {
        let unescaped = unescapeXML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if unescaped.isEmpty { return nil }
        if unescaped.hasPrefix("http://") || unescaped.hasPrefix("https://") {
            return URL(string: unescaped)
        }
        return sonosURL(endpoint: endpoint, path: unescaped)
    }

    static func unescapeXML(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
