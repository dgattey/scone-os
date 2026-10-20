import Foundation
import SconeDomain

enum SpotifyOnSonos {
    struct Account: Sendable, Hashable {
        let serviceID: Int
        let serialNumber: Int
        let regionToken: String
    }

    static let householdDefault = Account(
        serviceID: 12, serialNumber: 3, regionToken: "SA_RINCON3079_X_#Svc3079-0-Token")

    static func discoverAccount(
        using client: SOAPClient, coordinator: SpeakerUUID, at endpoint: URL
    )
        async throws(SonosCommandError) -> Account
    {
        for objectID in ["FV:2", "Q:0"] {
            let response: XMLNode
            do {
                response = try await client.call(browse(objectID), on: coordinator, at: endpoint)
            } catch {
                continue
            }
            if let account = account(in: decoded(response.value("Result"))) { return account }
        }
        return householdDefault
    }

    static func enqueueURI(for uri: SpotifyURI, account: Account) -> String {
        let query = "sid=\(account.serviceID)&flags=8224&sn=\(account.serialNumber)"
        switch uri.kind {
        case .track:
            return "x-sonos-spotify:spotify%3Atrack%3A\(uri.id)?\(query)"
        case .album:
            return "x-rincon-cpcontainer:0004206cspotify%3Aalbum%3A\(uri.id)?\(query)"
        case .playlist:
            return "x-rincon-cpcontainer:0006206cspotify%3Aplaylist%3A\(uri.id)?\(query)"
        }
    }

    static func didl(for metadata: SpotifyTrackMetadata, uri: SpotifyURI, account: Account) -> String {
        let album = metadata.album.map { "<upnp:album>\(xmlEscaped($0))</upnp:album>" } ?? ""
        return """
            <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" \
            xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="00032020spotify%3A\(uri.kind.rawValue)%3A\(uri.id)" \
            parentID="0004206cspotify%3Aalbum%3A0" restricted="true"><dc:title>\(xmlEscaped(metadata.title))</dc:title>\
            <dc:creator>\(xmlEscaped(metadata.artist))</dc:creator>\(album)\
            <upnp:class>object.item.audioItem.musicTrack</upnp:class><desc id="cdudn" \
            nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">\(xmlEscaped(account.regionToken))</desc></item></DIDL-Lite>
            """
    }

    static func requests(
        uri: String, didl: String, currentQueuePosition: Int?, startingAt: Duration?
    ) -> [SOAPRequest] {
        let position = (currentQueuePosition ?? 0) + 1
        var requests = [
            SOAPRequest(
                service: .avTransport, action: "AddURIToQueue",
                arguments: [
                    ("InstanceID", "0"),
                    ("EnqueuedURI", uri),
                    ("EnqueuedURIMetaData", didl),
                    ("DesiredFirstTrackNumberEnqueued", String(position)),
                    ("EnqueueAsNext", "1"),
                ]),
            TransportService.seek(toTrack: position),
            TransportService.transport(.play),
        ]
        if let startingAt { requests.append(TransportService.seek(to: startingAt)) }
        return requests
    }

    private static func browse(_ objectID: String) -> SOAPRequest {
        SOAPRequest(
            service: .contentDirectory, action: "Browse",
            arguments: [
                ("ObjectID", objectID),
                ("BrowseFlag", "BrowseDirectChildren"),
                ("Filter", "*"),
                ("StartingIndex", "0"),
                ("RequestedCount", "100"),
                ("SortCriteria", ""),
            ])
    }

    private static func account(in blob: String) -> Account? {
        let lower = blob.lowercased()
        guard
            lower.contains("x-sonos-spotify:")
                || lower.contains("spotify%3a")
                || blob.contains("SA_RINCON3079")
        else { return nil }
        guard let sidMatch = blob.firstMatch(of: /[?&]sid=(\d+)/),
            let sid = Int(sidMatch.1),
            let snMatch = blob.firstMatch(of: /[?&]sn=(\d+)/),
            let serial = Int(snMatch.1)
        else { return nil }
        return Account(
            serviceID: sid, serialNumber: serial, regionToken: regionToken(in: blob) ?? householdDefault.regionToken)
    }

    private static func regionToken(in blob: String) -> String? {
        if let root = try? XMLNode.parse(Data(blob.utf8)),
            let desc = root.firstDescendant("desc")?.text, desc.contains("SA_RINCON")
        {
            return desc
        }
        guard let match = blob.firstMatch(of: /SA_RINCON[^<"\s]+/) else { return nil }
        return String(match.0)
    }

    private static func decoded(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return
            text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
