import Foundation

public struct SpeakerUUID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        let prefix = "RINCON_"
        guard rawValue.count == 24, rawValue.hasPrefix(prefix) else { return nil }
        let payload = rawValue.dropFirst(prefix.count)
        guard payload.prefix(12).allSatisfy(Self.isUppercaseHex),
              payload.dropFirst(12).allSatisfy(Self.isASCIIDigit) else { return nil }
        self.rawValue = rawValue
    }

    private static func isUppercaseHex(_ character: Character) -> Bool {
        switch character {
        case "0"..."9", "A"..."F": true
        default: false
        }
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

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

extension SpeakerUUID: CodingKeyRepresentable {
    public var codingKey: any CodingKey { StringKey(stringValue: rawValue) }
    public init?<T: CodingKey>(codingKey: T) { self.init(rawValue: codingKey.stringValue) }
}

/// A Sonos household (`Sonos_…`): the system a speaker belongs to, as each speaker reports it.
public struct HouseholdID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.hasPrefix("Sonos_"), rawValue.count > "Sonos_".count else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension HouseholdID: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = HouseholdID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Not a Sonos household id: \(raw)"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension HouseholdID: CodingKeyRepresentable {
    public var codingKey: any CodingKey { StringKey(stringValue: rawValue) }
    public init?<T: CodingKey>(codingKey: T) { self.init(rawValue: codingKey.stringValue) }
}

private struct StringKey: CodingKey {
    let stringValue: String
    init(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { return nil }
}

public struct GroupID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let coordinator: SpeakerUUID

    package init(coordinator: SpeakerUUID) { self.coordinator = coordinator }

    public var description: String { coordinator.rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.coordinator < rhs.coordinator }
}
