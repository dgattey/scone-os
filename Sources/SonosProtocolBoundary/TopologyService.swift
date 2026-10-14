import Foundation
import SconeDomain

/// Everything about `ZoneGroupTopology` and regrouping: the parse and the commands that change it.
enum TopologyService {
    struct Member: Sendable {
        let roomName: String
        let endpoint: URL
        let satellites: [BondedSatellite]
    }

    struct Parsed: Sendable {
        let topology: Topology
        /// Visible members only. `<Satellite Invisible="1">` children fold into their soundbar's
        /// `satellites`, with roles from `HTSatChanMapSet`.
        let members: [SpeakerUUID: Member]
        /// S2 lists recently departed players under `<VanishedDevices>`. Inferred from S2 firmware
        /// behavior, not seen in the probe trace.
        let vanished: Set<SpeakerUUID>
    }

    static let getZoneGroupState = SOAPRequest(service: .zoneGroupTopology, action: "GetZoneGroupState", arguments: [])

    /// Input is the escaped `ZoneGroupState` text from the SOAP response. Rejects the whole parse if
    /// the result is not a valid `Topology`. A half-trusted topology would feed the planner bad moves.
    static func parse(zoneGroupState: String) throws -> Parsed {
        fatalError("not implemented")
    }

    /// Both actions go to the member being moved, never to the coordinator.
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
}
