import Foundation

public struct PresetID: Hashable, Sendable, Codable {
    public let rawValue: UUID
    public init() { rawValue = UUID() }
}

/// A saved arrangement, keyed by speakers, never by `GroupID`. Wire group IDs are reminted on
/// every ungroup, so a preset holding one would stop matching after the first change.
public struct PresetPill: Identifiable, Hashable, Sendable, Codable {
    public let id: PresetID
    public let name: String
    public let coordinatorUUID: SpeakerUUID
    /// Never contains `coordinatorUUID`. Every initializer, decoding included, removes it.
    public let memberUUIDs: Set<SpeakerUUID>

    public init(
        id: PresetID = PresetID(), name: String,
        coordinatorUUID: SpeakerUUID, memberUUIDs: some Sequence<SpeakerUUID>
    ) {
        self.id = id
        self.name = name
        self.coordinatorUUID = coordinatorUUID
        self.memberUUIDs = Set(memberUUIDs).subtracting([coordinatorUUID])
    }

    /// The name defaults to the group's display name, so saving "Kitchen + Dining" takes one tap.
    public init(capturing group: SonosGroup, name: String? = nil) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(
            name: trimmed.isEmpty ? group.displayName : trimmed,
            coordinatorUUID: group.coordinator.id,
            memberUUIDs: group.members.map(\.id))
    }

    public func renamed(_ name: String) -> PresetPill {
        PresetPill(id: id, name: name, coordinatorUUID: coordinatorUUID, memberUUIDs: memberUUIDs)
    }

    public var target: TopologyTarget {
        .exactGroup(coordinator: coordinatorUUID, members: memberUUIDs)
    }

    private enum CodingKeys: String, CodingKey { case id, name, coordinatorUUID, memberUUIDs }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(PresetID.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            coordinatorUUID: try c.decode(SpeakerUUID.self, forKey: .coordinatorUUID),
            memberUUIDs: try c.decode([SpeakerUUID].self, forKey: .memberUUIDs))
    }
}
