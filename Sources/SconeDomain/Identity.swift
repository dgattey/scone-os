import Foundation

/// A zone player's permanent identity, as advertised in the SSDP `USN` header and in
/// `ZoneGroupTopology`, e.g. `RINCON_F0F6C1AAD22801400`. It survives reboots, DHCP changes,
/// and regrouping, so it is the only speaker key SconeOS persists.
public struct SpeakerUUID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    /// `RINCON_` + 12 uppercase hex digits (the base MAC) + 5 decimal digits (`01400` on S2).
    public init?(rawValue: String) {
        // TODO: match ^RINCON_[0-9A-F]{12}[0-9]{5}$. The boundary strips the `uuid:` prefix and
        // the `::urn:...` suffix from SSDP USNs before calling this.
        fatalError("not implemented")
    }

    /// The base MAC. The telemetry parser resolves `ath_rincon` radio MACs (base or base+1) against it.
    package var macHex: Substring { rawValue.dropFirst("RINCON_".count).prefix(12) }

    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension SpeakerUUID: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = SpeakerUUID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Not a RINCON id: \(raw)"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Lets `[SpeakerUUID: RoomCoordinate]` encode as a JSON object keyed by RINCON id
/// instead of Swift's default alternating key/value array.
extension SpeakerUUID: CodingKeyRepresentable {
    public var codingKey: any CodingKey { StringKey(stringValue: rawValue) }
    public init?<T: CodingKey>(codingKey: T) { self.init(rawValue: codingKey.stringValue) }
}

private struct StringKey: CodingKey {
    let stringValue: String
    init(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { return nil }
}

/// A group is identified by its coordinator.
///
/// The wire ID (`RINCON_F0F6C1AAD22801400:3965225496`) is reminted whenever a member leaves, so the
/// boundary drops the numeric suffix and keeps only the coordinator. Only the package can mint a
/// `GroupID`, and it only does so from a parsed topology. That makes a `GroupID` proof that its
/// speaker coordinates a group, which is what coordinator-only actions (transport, group volume,
/// queue) require. Passing a grouped member to those actions returns UPnP fault 500 on the wire.
public struct GroupID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let coordinator: SpeakerUUID

    package init(coordinator: SpeakerUUID) { self.coordinator = coordinator }

    public var description: String { coordinator.rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.coordinator < rhs.coordinator }
}
