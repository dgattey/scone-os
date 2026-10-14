import Foundation
import SconeDomain

/// `AVTransport` and `RenderingControl`: what a group is playing, how loud, and the commands that
/// change either. Every request here goes to a coordinator except per-speaker volume.
enum TransportService {
    static let getTransportInfo = SOAPRequest(service: .avTransport, action: "GetTransportInfo", arguments: [("InstanceID", "0")])
    static let getPositionInfo = SOAPRequest(service: .avTransport, action: "GetPositionInfo", arguments: [("InstanceID", "0")])
    static let getMediaInfo = SOAPRequest(service: .avTransport, action: "GetMediaInfo", arguments: [("InstanceID", "0")])
    static let getVolume = SOAPRequest(
        service: .renderingControl, action: "GetVolume", arguments: [("InstanceID", "0"), ("Channel", "Master")])
    static let getGroupVolume = SOAPRequest(service: .groupRenderingControl, action: "GetGroupVolume", arguments: [("InstanceID", "0")])

    /// `TRANSITIONING` reads as playing. `x-rincon-queue:` in `CurrentURI` sets `queuePosition` from
    /// `Track`. `x-sonos-htastream:` reads as `.tvAudio`. Other non-queue URIs read as `.stream`.
    static func parsePlayback(
        transportInfo: XMLNode, positionInfo: XMLNode, mediaInfo: XMLNode,
        coordinatorEndpoint: URL, sampledAt: Date
    ) -> PlaybackState {
        fatalError("not implemented")
    }

    /// Speakers report any integer. The domain only holds detents, so 24 becomes 25 here and nowhere else.
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
        fatalError("not implemented")
    }
}
