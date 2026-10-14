import Foundation

public struct HouseholdSnapshot: Hashable, Sendable {
    public let observedAt: Date
    public let speakers: [SpeakerUUID: Speaker]
    public let topology: Topology
    private let groupStatus: [GroupID: GroupStatus]
    public let rf: RFPeerMatrix

    package init(
        observedAt: Date, speakers: [SpeakerUUID: Speaker], topology: Topology,
        groupStatus: [GroupID: GroupStatus], rf: RFPeerMatrix
    ) {
        self.observedAt = observedAt
        self.speakers = speakers
        self.topology = topology
        self.groupStatus = groupStatus
        self.rf = rf
    }

    public func status(of group: GroupID) -> GroupStatus {
        groupStatus[group]
            ?? GroupStatus(playback: .stopped, volume: speakers[group.coordinator]?.volume ?? .v0)
    }

    public var groups: [SonosGroup] {
        let roomCount = speakers.count
        return topology.groups.compactMap { groupID, memberIDs -> SonosGroup? in
            guard let coordinator = speakers[groupID.coordinator] else { return nil }
            let members = memberIDs.compactMap { speakers[$0] }.sorted { lhs, rhs in
                let left = RoomNaming.shortName(lhs.roomName, merged: false)
                let right = RoomNaming.shortName(rhs.roomName, merged: false)
                if left != right { return left < right }
                return lhs.id < rhs.id
            }
            let groupStatus = status(of: groupID)
            return SonosGroup(
                id: groupID,
                coordinator: coordinator,
                members: members,
                playback: groupStatus.playback,
                volume: groupStatus.volume,
                displayName: RoomNaming.groupName(
                    coordinator: coordinator.roomName,
                    members: members.map(\.roomName),
                    onlineRoomCount: roomCount))
        }
        .sorted { lhs, rhs in
            if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
            return lhs.id < rhs.id
        }
    }

    package func replacing(
        speakers: [SpeakerUUID: Speaker]? = nil, topology: Topology? = nil,
        status: (GroupID, GroupStatus)? = nil
    ) -> HouseholdSnapshot {
        var statuses = groupStatus
        if let status { statuses[status.0] = status.1 }
        return HouseholdSnapshot(
            observedAt: observedAt,
            speakers: speakers ?? self.speakers,
            topology: topology ?? self.topology,
            groupStatus: statuses,
            rf: rf)
    }
}

public struct GroupStatus: Hashable, Sendable {
    public let playback: PlaybackState
    public let volume: DiscreteVolume

    public init(playback: PlaybackState, volume: DiscreteVolume) {
        self.playback = playback
        self.volume = volume
    }
}
