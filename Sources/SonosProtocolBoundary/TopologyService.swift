import Foundation
import SconeDomain

enum TopologyService {
    struct Member: Sendable {
        let roomName: String
        let endpoint: URL
        let satellites: [BondedSatellite]
    }

    struct Parsed: Sendable {
        let topology: Topology
        let members: [SpeakerUUID: Member]
        let vanished: Set<SpeakerUUID>
    }

    static let getZoneGroupState = SOAPRequest(service: .zoneGroupTopology, action: "GetZoneGroupState", arguments: [])

    static func parse(zoneGroupState: String) throws -> Parsed {
        let root = try XMLNode.parse(Data(zoneGroupState.utf8))
        var members: [SpeakerUUID: Member] = [:]
        var coordinatorOf: [SpeakerUUID: SpeakerUUID] = [:]
        let groups = root.name == "ZoneGroup" ? [root] : root.descendants("ZoneGroup")
        for group in groups {
            guard let coordinator = SpeakerUUID(rawValue: group.attribute("Coordinator") ?? "") else { continue }
            var visible: [(SpeakerUUID, Member)] = []
            for node in group.children where node.name == "ZoneGroupMember" {
                if node.attribute("Invisible") == "1" { continue }
                guard let id = SpeakerUUID(rawValue: node.attribute("UUID") ?? ""),
                      let endpoint = baseEndpoint(node.attribute("Location") ?? "") else { continue }
                visible.append((id, Member(
                    roomName: node.attribute("ZoneName") ?? "",
                    endpoint: endpoint,
                    satellites: satellites(of: node))))
            }
            guard visible.contains(where: { $0.0 == coordinator }) else { continue }
            for (id, member) in visible {
                members[id] = member
                coordinatorOf[id] = coordinator
            }
            coordinatorOf[coordinator] = coordinator
        }
        guard let topology = Topology(coordinatorOf: coordinatorOf) else {
            throw ProtocolParseError(description: "ZoneGroupState is not a valid topology")
        }
        return Parsed(topology: topology, members: members, vanished: vanishedIDs(in: root))
    }

    static func request(for step: TopologyStep) -> (target: SpeakerUUID, request: SOAPRequest) {
        switch step {
        case .makeStandalone(let member):
            (member, SOAPRequest(
                service: .avTransport, action: "BecomeCoordinatorOfStandaloneGroup",
                arguments: [("InstanceID", "0")]))
        case .join(let member, let coordinator):
            (member, SOAPRequest(
                service: .avTransport, action: "SetAVTransportURI",
                arguments: [("InstanceID", "0"), ("CurrentURI", "x-rincon:\(coordinator)"), ("CurrentURIMetaData", "")]))
        }
    }

    private static func satellites(of member: XMLNode) -> [BondedSatellite] {
        var roles = channelRoles(in: member.attribute("HTSatChanMapSet") ?? "")
        for satellite in member.children where satellite.name == "Satellite" {
            guard let id = SpeakerUUID(rawValue: satellite.attribute("UUID") ?? ""), roles[id] == nil else { continue }
            let map = satellite.attribute("HTSatChanMapSet") ?? ""
            if map.contains(":") {
                if let role = channelRoles(in: map)[id] { roles[id] = role }
            } else if let role = satelliteRole(channels: map) {
                roles[id] = role
            }
        }
        return roles.map { BondedSatellite(id: $0.key, role: $0.value, linkQuality: nil) }
            .sorted { lhs, rhs in
                if lhs.role != rhs.role { return lhs.role.rawValue < rhs.role.rawValue }
                return lhs.id < rhs.id
            }
    }

    private static func channelRoles(in map: String) -> [SpeakerUUID: SatelliteRole] {
        var roles: [SpeakerUUID: SatelliteRole] = [:]
        for part in map.split(separator: ";") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard let colon = piece.firstIndex(of: ":") else { continue }
            let id = SpeakerUUID(rawValue: String(piece[..<colon]))
            let channels = String(piece[piece.index(after: colon)...])
            if let id, let role = satelliteRole(channels: channels) { roles[id] = role }
        }
        return roles
    }

    private static func satelliteRole(channels: String) -> SatelliteRole? {
        let tokens = Set(channels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() })
        if tokens.contains("SW") { return .subwoofer }
        if tokens.contains("LR") || tokens.contains("LTR") { return .rearLeft }
        if tokens.contains("RR") || tokens.contains("RTR") { return .rearRight }
        return nil
    }

    private static func baseEndpoint(_ location: String) -> URL? {
        guard let url = URL(string: location), let host = url.host, !host.isEmpty else { return nil }
        let rendered = host.contains(":") ? "[\(host)]" : host
        return URL(string: "http://\(rendered):1400")
    }

    private static func vanishedIDs(in root: XMLNode) -> Set<SpeakerUUID> {
        var ids = Set<SpeakerUUID>()
        func walk(_ node: XMLNode) {
            if node.name != "VanishedDevices", let raw = node.attribute("UUID"), let id = SpeakerUUID(rawValue: raw) {
                ids.insert(id)
            }
            node.children.forEach(walk)
        }
        for container in root.descendants("VanishedDevices") {
            container.children.forEach(walk)
        }
        return ids
    }
}
