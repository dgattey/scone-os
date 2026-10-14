import Foundation

/// One sweep of the live household, as the protocol boundary saw it. The boundary yields a new
/// snapshot only when it differs from the last one.
public struct HouseholdSnapshot: Hashable, Sendable {
    public let observedAt: Date
    /// Visible zone players in this sweep, all `.online`. Satellites are inside `.beamHt`.
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

    /// Total. A group with no status yet (a projected regroup, or a group formed since the last
    /// transport read) reads as stopped at its coordinator's own volume.
    public func status(of group: GroupID) -> GroupStatus {
        groupStatus[group]
            ?? GroupStatus(playback: .stopped, volume: speakers[group.coordinator]?.volume ?? .v0)
    }

    /// Assembled with `RoomNaming`. Sorted by display name.
    public var groups: [SonosGroup] {
        fatalError("not implemented")
    }

    package func replacing(
        speakers: [SpeakerUUID: Speaker]? = nil, topology: Topology? = nil,
        status: (GroupID, GroupStatus)? = nil
    ) -> HouseholdSnapshot {
        fatalError("not implemented")
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
