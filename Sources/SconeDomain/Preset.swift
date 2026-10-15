import Foundation

public struct PresetID: Hashable, Sendable, Codable {
    public let rawValue: UUID
    public init() { rawValue = UUID() }
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct PresetPill: Identifiable, Hashable, Sendable, Codable {
    public let id: PresetID
    public let name: String
    public let coordinatorUUID: SpeakerUUID
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

    public func updated(coordinatorUUID: SpeakerUUID, memberUUIDs: some Sequence<SpeakerUUID>) -> PresetPill {
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

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(coordinatorUUID, forKey: .coordinatorUUID)
        try container.encode(memberUUIDs.sorted(), forKey: .memberUUIDs)
    }
}
