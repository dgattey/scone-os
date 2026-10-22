import Foundation
import SconeDomain

enum TopologyService {
    struct SatelliteSpec: Sendable, Hashable {
        let id: SpeakerUUID
        let parentID: SpeakerUUID
        let role: SatelliteRole
        let endpoint: URL?
    }

    struct Member: Sendable {
        let roomName: String
        let endpoint: URL
        let satellites: [SatelliteSpec]
    }

    struct Parsed: Sendable {
        let household: HouseholdID
        let topology: Topology
        let members: [SpeakerUUID: Member]
        let vanished: Set<SpeakerUUID>
        let vanishedNames: [SpeakerUUID: String]

        init(
            household: HouseholdID, topology: Topology, members: [SpeakerUUID: Member], vanished: Set<SpeakerUUID>,
            vanishedNames: [SpeakerUUID: String] = [:]
        ) {
            self.household = household
            self.topology = topology
            self.members = members
            self.vanished = vanished
            self.vanishedNames = vanishedNames
        }
    }

    static let getZoneGroupState = SOAPRequest(service: .zoneGroupTopology, action: "GetZoneGroupState", arguments: [])
    static let getHouseholdID = SOAPRequest(service: .deviceProperties, action: "GetHouseholdID", arguments: [])

    static func parse(zoneGroupState: String, household: HouseholdID) throws -> Parsed {
        let root = try XMLNode.parse(Data(zoneGroupState.utf8))
        var members: [SpeakerUUID: Member] = [:]
        var coordinatorOf: [SpeakerUUID: SpeakerUUID] = [:]
        let groups = root.name == "ZoneGroup" ? [root] : root.descendants("ZoneGroup")
        for group in groups {
            guard let coordinator = SpeakerUUID(rawValue: group.attribute("Coordinator") ?? "") else { continue }
            var visible: [(SpeakerUUID, Member)] = []
            var invisibleByParent: [SpeakerUUID: [SatelliteSpec]] = [:]

            for node in group.children where node.name == "ZoneGroupMember" && node.attribute("Invisible") == "1" {
                guard let satID = SpeakerUUID(rawValue: node.attribute("UUID") ?? "") else { continue }
                let map = node.attribute("HTSatChanMapSet") ?? node.attribute("ChannelMapSet") ?? ""
                if let (parentID, role) = parentAndRole(for: satID, in: map) {
                    let satEndpoint = baseEndpoint(node.attribute("Location") ?? "")
                    invisibleByParent[parentID, default: []].append(
                        SatelliteSpec(id: satID, parentID: parentID, role: role, endpoint: satEndpoint)
                    )
                }
            }

            for node in group.children where node.name == "ZoneGroupMember" {
                if node.attribute("Invisible") == "1" { continue }
                guard let id = SpeakerUUID(rawValue: node.attribute("UUID") ?? ""),
                      let endpoint = baseEndpoint(node.attribute("Location") ?? "") else { continue }
                var combined = satellites(of: node, parentID: id)
                for extra in invisibleByParent[id] ?? [] where !combined.contains(where: { $0.id == extra.id }) {
                    combined.append(extra)
                }
                combined.sort { lhs, rhs in
                    if lhs.role != rhs.role { return lhs.role.rawValue < rhs.role.rawValue }
                    return lhs.id < rhs.id
                }
                visible.append((id, Member(
                    roomName: node.attribute("ZoneName") ?? "",
                    endpoint: endpoint,
                    satellites: combined)))
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
        let vanishedInfo = vanishedDevices(in: root)
        return Parsed(
            household: household, topology: topology, members: members, vanished: vanishedInfo.ids,
            vanishedNames: vanishedInfo.names)
    }

    static func request(for step: TopologyStep) -> (target: SpeakerUUID, request: SOAPRequest) {
        switch step {
        case .makeStandalone(let member):
            (member, SOAPRequest(
                service: .avTransport, action: "BecomeCoordinatorOfStandaloneGroup",
                arguments: [("InstanceID", "0")]))
        case .delegateCoordination(let coordinator, let newCoordinator, let rejoinGroup):
            (coordinator, SOAPRequest(
                service: .avTransport, action: "DelegateGroupCoordinationTo",
                arguments: [
                    ("InstanceID", "0"),
                    ("NewCoordinator", newCoordinator.rawValue),
                    ("RejoinGroup", rejoinGroup ? "1" : "0"),
                ]))
        case .join(let member, let coordinator):
            (member, SOAPRequest(
                service: .avTransport, action: "SetAVTransportURI",
                arguments: [("InstanceID", "0"), ("CurrentURI", "x-rincon:\(coordinator)"), ("CurrentURIMetaData", "")]))
        }
    }

    private static func satellites(of member: XMLNode, parentID: SpeakerUUID) -> [SatelliteSpec] {
        let mapString = member.attribute("HTSatChanMapSet") ?? member.attribute("ChannelMapSet") ?? ""
        var roles = channelRoles(in: mapString, excluding: parentID)
        var endpoints: [SpeakerUUID: URL] = [:]
        for satellite in member.children where satellite.name == "Satellite" {
            guard let id = SpeakerUUID(rawValue: satellite.attribute("UUID") ?? "") else { continue }
            if let endpoint = baseEndpoint(satellite.attribute("Location") ?? "") {
                endpoints[id] = endpoint
            }
            guard roles[id] == nil else { continue }
            let map = satellite.attribute("HTSatChanMapSet") ?? satellite.attribute("ChannelMapSet") ?? ""
            if map.contains(":") {
                if let role = channelRoles(in: map, excluding: parentID)[id] { roles[id] = role }
            } else if let role = satelliteRole(channels: map) {
                roles[id] = role
            }
        }
        return roles.map {
            SatelliteSpec(id: $0.key, parentID: parentID, role: $0.value, endpoint: endpoints[$0.key])
        }
        .sorted { lhs, rhs in
            if lhs.role != rhs.role { return lhs.role.rawValue < rhs.role.rawValue }
            return lhs.id < rhs.id
        }
    }

    private static func parentAndRole(for satelliteID: SpeakerUUID, in map: String) -> (SpeakerUUID, SatelliteRole)? {
        var parentCandidate: SpeakerUUID?
        var foundRole: SatelliteRole?
        for part in map.split(separator: ";") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard let colon = piece.firstIndex(of: ":") else { continue }
            guard let id = SpeakerUUID(rawValue: String(piece[..<colon])) else { continue }
            let channels = String(piece[piece.index(after: colon)...])
            if id == satelliteID {
                foundRole = satelliteRole(channels: channels)
            } else if parentCandidate == nil {
                parentCandidate = id
            }
        }
        guard let parentCandidate, let foundRole else { return nil }
        return (parentCandidate, foundRole)
    }

    private static func channelRoles(in map: String, excluding parentID: SpeakerUUID) -> [SpeakerUUID: SatelliteRole] {
        var roles: [SpeakerUUID: SatelliteRole] = [:]
        for part in map.split(separator: ";") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard let colon = piece.firstIndex(of: ":") else { continue }
            let id = SpeakerUUID(rawValue: String(piece[..<colon]))
            let channels = String(piece[piece.index(after: colon)...])
            if let id, id != parentID, let role = satelliteRole(channels: channels) { roles[id] = role }
        }
        return roles
    }

    private static func satelliteRole(channels: String) -> SatelliteRole? {
        let tokens = Set(channels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() })
        if tokens.contains("SW") { return .subwoofer }
        if tokens.contains("LR") || tokens.contains("LTR") { return .rearLeft }
        if tokens.contains("RR") || tokens.contains("RTR") { return .rearRight }
        if tokens.contains("RF") || tokens.contains("R") { return .stereoRight }
        return nil
    }

    private static func baseEndpoint(_ location: String) -> URL? {
        guard let url = URL(string: location), let host = url.host, !host.isEmpty else { return nil }
        let rendered = host.contains(":") ? "[\(host)]" : host
        return URL(string: "http://\(rendered):1400")
    }

    private static func vanishedDevices(in root: XMLNode) -> (ids: Set<SpeakerUUID>, names: [SpeakerUUID: String]) {
        var ids = Set<SpeakerUUID>()
        var names: [SpeakerUUID: String] = [:]
        func walk(_ node: XMLNode) {
            if node.name != "VanishedDevices", let raw = node.attribute("UUID"), let id = SpeakerUUID(rawValue: raw) {
                ids.insert(id)
                if let zoneName = node.attribute("ZoneName")?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !zoneName.isEmpty {
                    names[id] = zoneName
                }
            }
            node.children.forEach(walk)
        }
        for container in root.descendants("VanishedDevices") {
            container.children.forEach(walk)
        }
        return (ids, names)
    }
}
