import Foundation
import SconeDomain

enum TelemetryService {
    struct PeerReading: Sendable {
        let peer: SpeakerUUID
        let from: Int
        let to: Int
    }

    struct RadioStatus: Sendable {
        let peers: [PeerReading]
        let noiseFloor: Int?
        let rssi: Int?
        let satelliteLinkQuality: [SpeakerUUID: Int]
    }

    static func model(
        number: String, displayName: String, satellites: [BondedSatellite], battery: BatteryTelemetry?
    ) -> SpeakerModel {
        SpeakerModel.classify(
            modelName: displayName,
            modelNumber: number,
            satellites: satellites,
            battery: battery
        )
    }

    static func parseDeviceDescription(_ data: Data) throws -> (modelNumber: String, displayName: String) {
        let root = try XMLNode.parse(data)
        let modelNumber = modelCode(root.firstDescendant("modelNumber")?.text ?? "")
        let display = root.firstDescendant("displayName")?.text ?? ""
        let modelName = root.firstDescendant("modelName")?.text ?? ""
        let name = modelName.isEmpty ? display : modelName
        guard !modelNumber.isEmpty || !name.isEmpty else {
            throw ProtocolParseError(description: "device description has no model")
        }
        return (modelNumber, name)
    }

    static func parseRadioStatus(_ text: String, resolve: (String) -> SpeakerUUID?) -> RadioStatus {
        var noiseFloor: Int?
        var rssi: Int?
        var peers: [SpeakerUUID: (from: Int, to: Int)] = [:]
        var satelliteMAC: String?
        var links: [SpeakerUUID: Int] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            if let match = line.firstMatch(of: /(?i)Noise Floor:\s*(-?\d+)\s*dBm/),
                let value = Int(match.1)
            {
                if value != 0, noiseFloor == nil { noiseFloor = value }
                continue
            }
            if rssi == nil, !line.contains("AVG"),
                let match = line.firstMatch(of: /(?i)RSSI:\s*(-?\d+)\s*dBm/),
                let value = Int(match.1), value != 0
            {
                rssi = value
                continue
            }
            if let match = line.firstMatch(of: /(?i)Node\s+([0-9A-Fa-f:]+)\s*-\s*FROM\s+(-?\d+)\s*:\s*TO\s+(-?\d+)/),
                let from = Int(match.2),
                let to = Int(match.3),
                let peer = resolveMAC(String(match.1), resolve: resolve)
            {
                if let existing = peers[peer] {
                    peers[peer] = (max(existing.from, from), max(existing.to, to))
                } else {
                    peers[peer] = (from, to)
                }
                satelliteMAC = nil
                continue
            }
            if let match = line.firstMatch(of: /(?i)(?:Satellite\s+\d+:|Client\s+Node)\s*([0-9A-Fa-f:]+)/) {
                satelliteMAC = String(match.1)
                continue
            }
            if let match = line.firstMatch(of: /(?i)RSSI AVG:?\s*(-?\d+)/),
                let average = Int(match.1),
                let mac = satelliteMAC,
                let id = resolveMAC(mac, resolve: resolve)
            {
                links[id] = max(links[id] ?? average, average)
            }
        }
        let readings = peers.map { PeerReading(peer: $0.key, from: $0.value.from, to: $0.value.to) }
            .sorted { $0.peer < $1.peer }
        return RadioStatus(peers: readings, noiseFloor: noiseFloor, rssi: rssi, satelliteLinkQuality: links)
    }

    static func parseBatteryStatus(_ data: Data, sampledAt: Date) throws -> BatteryTelemetry {
        let root = try XMLNode.parse(data)
        var fields: [String: String] = [:]
        for node in root.descendants("Data") {
            if let name = node.attribute("name") { fields[name] = node.text }
        }
        guard let level = fields["Level"].flatMap(Int.init) else {
            throw ProtocolParseError(description: "battery status has no Level")
        }
        let source = fields["PowerSource"] ?? "BATTERY"
        return BatteryTelemetry(
            levelPercent: min(max(level, 0), 100),
            isOnCharger: source.caseInsensitiveCompare("BATTERY") != .orderedSame,
            temperatureCelsius: fields["Temperature"].flatMap(Int.init),
            sampledAt: sampledAt)
    }

    private static func modelCode(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.firstMatch(of: /S\d+/) else { return trimmed }
        return String(match.0)
    }

    // Radio MACs are the base MAC or base+1, so resolve matches the last octet within one.
    private static func resolveMAC(_ raw: String, resolve: (String) -> SpeakerUUID?) -> SpeakerUUID? {
        let hex = raw.uppercased().filter(\.isHexDigit)
        guard hex.count == 12 else { return nil }
        if let id = resolve(hex) { return id }
        guard let last = UInt8(hex.suffix(2), radix: 16), last > 0 else { return nil }
        let shifted = String(hex.dropLast(2)) + String(format: "%02X", last - 1)
        return resolve(shifted)
    }
}
