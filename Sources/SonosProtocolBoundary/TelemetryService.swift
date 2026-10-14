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
        switch number {
        case "S39": .era100
        case "S41": .era300
        case "S33": .symfoniskBookshelf
        case "S31": .beamHt(satellites: satellites)
        case "S17": .move(battery: battery)
        default: .unrecognized(modelNumber: number, displayName: displayName)
        }
    }

    static func parseDeviceDescription(_ data: Data) throws -> (modelNumber: String, displayName: String) {
        let root = try XMLNode.parse(data)
        let modelNumber = modelCode(root.descendants("modelNumber").first?.text ?? "")
        let display = root.descendants("displayName").first?.text ?? ""
        let modelName = root.descendants("modelName").first?.text ?? ""
        let name = display.isEmpty ? modelName : display
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
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if let value = firstCapture(#"Noise Floor:\s*(-?\d+)\s*dBm"#, in: line).flatMap(Int.init) {
                if value != 0, noiseFloor == nil { noiseFloor = value }
                continue
            }
            if rssi == nil, !line.contains("AVG"),
               let value = firstCapture(#"RSSI:\s*(-?\d+)\s*dBm"#, in: line).flatMap(Int.init), value != 0 {
                rssi = value
                continue
            }
            if let parts = captures(#"Node\s+([0-9A-Fa-f:]+)\s*-\s*FROM\s+(-?\d+)\s*:\s*TO\s+(-?\d+)"#, in: line),
               parts.count == 3, let from = Int(parts[1]), let to = Int(parts[2]),
               let peer = resolveMAC(parts[0], resolve: resolve) {
                if let existing = peers[peer] {
                    peers[peer] = (max(existing.from, from), max(existing.to, to))
                } else {
                    peers[peer] = (from, to)
                }
                satelliteMAC = nil
                continue
            }
            if let mac = firstCapture(#"Satellite\s+\d+:\s*([0-9A-Fa-f:]+)"#, in: line) {
                satelliteMAC = mac
                continue
            }
            if let average = firstCapture(#"RSSI AVG:?\s*(-?\d+)"#, in: line).flatMap(Int.init),
               let mac = satelliteMAC, let id = resolveMAC(mac, resolve: resolve) {
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
        guard let range = trimmed.range(of: #"S\d+"#, options: .regularExpression) else { return trimmed }
        return String(trimmed[range])
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

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        captures(pattern, in: text)?.first
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        var values: [String] = []
        for index in 1..<match.numberOfRanges {
            guard let slice = Range(match.range(at: index), in: text) else { return nil }
            values.append(String(text[slice]))
        }
        return values
    }
}
