public struct SonosGroup: Identifiable, Hashable, Sendable {
    public let id: GroupID
    public let coordinator: Speaker
    public let members: [Speaker]
    public let playback: PlaybackState
    public let volume: DiscreteVolume
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

public enum RoomNaming {
    public static func shortName(_ zoneName: String, merged: Bool) -> String {
        var name = zoneName
        if let stripped = stripping(name, suffix: " Speaker") ?? stripping(name, suffix: " Soundbar") {
            name = stripped
        }
        if merged, let stripped = stripping(name, suffix: " Room") {
            name = stripped
        }
        return name
    }

    public static func groupName(coordinator: String, members: [String], onlineRoomCount: Int) -> String {
        if members.isEmpty { return shortName(coordinator, merged: false) }
        if onlineRoomCount > 1, 1 + members.count >= onlineRoomCount { return "Everywhere" }

        let zones = [coordinator] + members
        let mergedNames = zones.map { shortName($0, merged: true) }
        var counts: [String: Int] = [:]
        for name in mergedNames { counts[name, default: 0] += 1 }
        func label(_ zone: String, _ mergedName: String) -> String {
            counts[mergedName, default: 0] > 1 ? shortName(zone, merged: false) : mergedName
        }

        let coordinatorLabel = label(coordinator, mergedNames[0])
        let memberLabels = zip(members, mergedNames.dropFirst()).map { zone, mergedName in
            label(zone, mergedName)
        }.sorted()
        let labels = [coordinatorLabel] + memberLabels
        if labels.count <= 3 { return labels.joined(separator: " + ") }
        return "\(labels[0]) + \(labels[1]) + \(labels.count - 2) more"
    }

    private static func stripping(_ name: String, suffix: String) -> String? {
        guard name.hasSuffix(suffix) else { return nil }
        let stripped = String(name.dropLast(suffix.count))
        guard !stripped.isEmpty else { return nil }
        return stripped
    }
}
