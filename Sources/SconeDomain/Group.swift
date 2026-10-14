/// A read model for one live group, rebuilt from `HouseholdSnapshot` on every change.
/// Nothing stores a `SonosGroup`, so its display name and member list cannot go stale.
public struct SonosGroup: Identifiable, Hashable, Sendable {
    public let id: GroupID
    public let coordinator: Speaker
    /// Excludes the coordinator. Sorted by short room name.
    public let members: [Speaker]
    public let playback: PlaybackState
    public let volume: DiscreteVolume
    /// "Kitchen + Dining". See `RoomNaming.groupName`.
    public let displayName: String

    public var speakers: [Speaker] { [coordinator] + members }

    package init(
        id: GroupID, coordinator: Speaker, members: [Speaker],
        playback: PlaybackState, volume: DiscreteVolume, displayName: String
    ) {
        self.id = id
        self.coordinator = coordinator
        self.members = members
        self.playback = playback
        self.volume = volume
        self.displayName = displayName
    }
}

/// Pure naming rules, table-tested with the household's real zone names.
public enum RoomNaming {
    /// Drops a trailing "Speaker" or "Soundbar". When `merged`, also drops a trailing "Room" so
    /// group names stay short. Falls back to the input if nothing would remain.
    ///
    /// "Kitchen Speaker" -> "Kitchen". "Living Room Soundbar" -> "Living Room".
    /// "Dining Room Speaker" merged -> "Dining".
    public static func shortName(_ zoneName: String, merged: Bool) -> String {
        fatalError("not implemented")
    }

    /// Coordinator first, then members by short name, joined with " + ".
    /// - One room: its unmerged short name ("Living Room").
    /// - Every online room in one group: "Everywhere".
    /// - More than three rooms: "Kitchen + Dining + 2 more".
    /// Duplicate short names keep their full zone names instead.
    public static func groupName(coordinator: String, members: [String], onlineRoomCount: Int) -> String {
        fatalError("not implemented")
    }
}
