import Foundation
import SconeDomain

/// The undocumented HTTP `/status` pages and the device description. Slow-moving facts read on
/// the telemetry interval, not every sweep.
enum TelemetryService {
    struct PeerReading: Sendable {
        let peer: SpeakerUUID
        let from: Int
        let to: Int
    }

    struct RadioStatus: Sendable {
        let peers: [PeerReading]
        /// dBm. `0` in the page means not measured and parses to nil.
        let noiseFloor: Int?
        let rssi: Int?
        /// Soundbar only: satellite UUID to `RX Stats RSSI AVG`.
        let satelliteLinkQuality: [SpeakerUUID: Int]
    }

    /// The one model table. Adding hardware means adding a case to `SpeakerModel` and a line here.
    static func model(
        number: String, displayName: String, satellites: [BondedSatellite], battery: BatteryTelemetry?
    ) -> SpeakerModel {
        switch number {
        case "S39": .era100
        case "S41": .era300
        case "S33": .symfoniskBookshelf
        case "S31": .beamHt(satellites: satellites)
        case "S17": .move(battery: battery)
        default: .unrecognized(modelNumber: number, displayName: displayName)
        }
    }

    /// `/xml/device_description.xml` -> (`modelNumber`, `displayName`). Read once per speaker and cached.
    static func parseDeviceDescription(_ data: Data) throws -> (modelNumber: String, displayName: String) {
        fatalError("not implemented")
    }

    /// `/status/proc/ath_rincon/status`. Lines look like `Node 54:2A:1B:5F:08:A1 - FROM 42 : TO 43 : STP 03`.
    /// Radio MACs are the base MAC or base+1, so `resolve` matches the last octet within one.
    static func parseRadioStatus(_ text: String, resolve: (String) -> SpeakerUUID?) -> RadioStatus {
        fatalError("not implemented")
    }

    /// `/status/batterystatus`: `Level`, `PowerSource`, `Temperature` data elements.
    static func parseBatteryStatus(_ data: Data, sampledAt: Date) throws -> BatteryTelemetry {
        fatalError("not implemented")
    }
}
