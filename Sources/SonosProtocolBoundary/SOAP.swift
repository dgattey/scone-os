import Foundation
import SconeDomain

/// The single table of services this app talks to. Paths match the probe household's SCPDs.
enum UPnPService: CaseIterable {
    case zoneGroupTopology, avTransport, renderingControl, groupRenderingControl, contentDirectory, queue

    var urn: String {
        switch self {
        case .zoneGroupTopology: "urn:schemas-upnp-org:service:ZoneGroupTopology:1"
        case .avTransport: "urn:schemas-upnp-org:service:AVTransport:1"
        case .renderingControl: "urn:schemas-upnp-org:service:RenderingControl:1"
        case .groupRenderingControl: "urn:schemas-upnp-org:service:GroupRenderingControl:1"
        case .contentDirectory: "urn:schemas-upnp-org:service:ContentDirectory:1"
        case .queue: "urn:schemas-sonos-com:service:Queue:1"
        }
    }

    var controlPath: String {
        switch self {
        case .zoneGroupTopology: "/ZoneGroupTopology/Control"
        case .avTransport: "/MediaRenderer/AVTransport/Control"
        case .renderingControl: "/MediaRenderer/RenderingControl/Control"
        case .groupRenderingControl: "/MediaRenderer/GroupRenderingControl/Control"
        case .contentDirectory: "/MediaServer/ContentDirectory/Control"
        case .queue: "/MediaRenderer/Queue/Control"
        }
    }
}

struct SOAPRequest: Sendable {
    let service: UPnPService
    let action: String
    let arguments: [(String, String)]
}

struct SOAPClient: Sendable {
    /// Builds the envelope, POSTs with `SOAPACTION`, and returns the `<u:ActionResponse>` element.
    /// Maps transport failures to `.speakerUnreachable` and `<UPnPError>` to `.speakerRejected`.
    func call(_ request: SOAPRequest, on speaker: SpeakerUUID, at endpoint: URL)
        async throws(SonosCommandError) -> XMLNode
    {
        fatalError("not implemented")
    }

    /// Plain GET for `/status/...` and `/xml/device_description.xml`.
    func get(_ path: String, at endpoint: URL) async throws(SonosCommandError) -> Data {
        fatalError("not implemented")
    }
}

/// A small DOM built on `XMLParser`. Foundation's `XMLDocument` does not exist on iOS.
/// `ZoneGroupState` and DIDL-Lite arrive as escaped XML inside a SOAP text node, so callers
/// parse twice: the envelope, then the inner string.
struct XMLNode: Sendable {
    let name: String
    let attributes: [String: String]
    let children: [XMLNode]
    let text: String

    static func parse(_ data: Data) throws -> XMLNode {
        fatalError("not implemented")
    }

    func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }
    func descendants(_ name: String) -> [XMLNode] {
        fatalError("not implemented")
    }
}
