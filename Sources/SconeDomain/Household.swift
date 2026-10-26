import Foundation

public struct HouseholdSnapshot: Hashable, Sendable {
    /// The household that answered, or nil when none did.
    public let household: HouseholdID?
    public let observedAt: Date
    public let speakers: [SpeakerUUID: Speaker]
    public let topology: Topology
    /// What each coordinator reported, before stale sessions are cleared. Re-sanitizing starts here.
    private let reportedStatus: [GroupID: GroupStatus]
    private let groupStatus: [GroupID: GroupStatus]
    public let rf: RFPeerMatrix
    public let presets: [PresetPill]?
    public let networkName: String?
    public let externalSpotify: SpotifyTrackContext?
    /// The group holding the room Spotify names as the connected account's active device.
    public let connectedSpotifyGroup: GroupID?
    public let groups: [SonosGroup]

    package init(
        household: HouseholdID?, observedAt: Date, speakers: [SpeakerUUID: Speaker], topology: Topology,
        groupStatus: [GroupID: GroupStatus], rf: RFPeerMatrix,
        presets: [PresetPill]? = nil,
        networkName: String? = nil,
        externalSpotify: SpotifyTrackContext? = nil,
        connectedSpotifyGroup: GroupID? = nil,
        preferredGroupIDs: Set<GroupID> = []
    ) {
        self.household = household
        self.observedAt = observedAt
        self.speakers = speakers
        self.topology = topology
        self.rf = rf
        self.presets = presets
        self.networkName = networkName
        self.externalSpotify = externalSpotify
        self.connectedSpotifyGroup = connectedSpotifyGroup
        self.reportedStatus = groupStatus
        let sanitizedStatus = Self.sanitizeGroupStatus(
            groupStatus,
            speakers: speakers,
            topology: topology,
            preferredGroupIDs: preferredGroupIDs,
            connectedSpotifyGroup: connectedSpotifyGroup
        )
        self.groupStatus = sanitizedStatus
        self.groups = Self.buildGroups(speakers: speakers, topology: topology, groupStatus: sanitizedStatus)
    }

    public func status(of group: GroupID) -> GroupStatus {
        groupStatus[group]
            ?? GroupStatus(playback: .stopped, volume: speakers[group.coordinator]?.volume ?? .v0)
    }

    public func isSemanticallyEquivalent(to other: HouseholdSnapshot) -> Bool {
        guard household == other.household,
              topology == other.topology,
              rf == other.rf,
              presets == other.presets,
              networkName == other.networkName,
              externalSpotify == other.externalSpotify,
              connectedSpotifyGroup == other.connectedSpotifyGroup,
              speakers.count == other.speakers.count else {
            return false
        }
        for (id, lhsSpeaker) in speakers {
            guard let rhsSpeaker = other.speakers[id],
                  lhsSpeaker.isSemanticallyEquivalent(to: rhsSpeaker) else {
                return false
            }
        }
        let allGroups = Set(topology.groups.keys).union(other.topology.groups.keys)
        for groupID in allGroups {
            let lhsStatus = status(of: groupID)
            let rhsStatus = other.status(of: groupID)
            if lhsStatus.volume != rhsStatus.volume
                || !lhsStatus.playback.isSemanticallyEquivalent(to: rhsStatus.playback) {
                return false
            }
        }
        return true
    }

    public func sanitizingPlaybackSessions(preferredGroupIDs: Set<GroupID> = []) -> HouseholdSnapshot {
        let sanitized = Self.sanitizeGroupStatus(
            reportedStatus,
            speakers: speakers,
            topology: topology,
            preferredGroupIDs: preferredGroupIDs,
            connectedSpotifyGroup: connectedSpotifyGroup
        )
        guard sanitized != groupStatus else { return self }
        return HouseholdSnapshot(
            household: household,
            observedAt: observedAt,
            speakers: speakers,
            topology: topology,
            groupStatus: reportedStatus,
            rf: rf,
            presets: presets,
            networkName: networkName,
            externalSpotify: externalSpotify,
            connectedSpotifyGroup: connectedSpotifyGroup,
            preferredGroupIDs: preferredGroupIDs
        )
    }

    /// Clears sessions a room still reports but no longer plays. Each Spotify account keeps at most one
    /// session: a playing one wins, otherwise the best-ranked paused one. Other accounts are left alone.
    private static func sanitizeGroupStatus(
        _ rawStatus: [GroupID: GroupStatus],
        speakers: [SpeakerUUID: Speaker],
        topology: Topology,
        preferredGroupIDs: Set<GroupID>,
        connectedSpotifyGroup: GroupID?
    ) -> [GroupID: GroupStatus] {
        let validGroups = Array(topology.groups.keys)
        guard validGroups.count > 1 else { return rawStatus }

        func groupPreferenceRank(_ a: GroupID, _ b: GroupID) -> Bool {
            if (a == connectedSpotifyGroup) != (b == connectedSpotifyGroup) { return a == connectedSpotifyGroup }

            let aPreferred = preferredGroupIDs.contains(a)
            let bPreferred = preferredGroupIDs.contains(b)
            if aPreferred != bPreferred { return aPreferred }

            let aMemberCount = 1 + (topology.groups[a]?.count ?? 0)
            let bMemberCount = 1 + (topology.groups[b]?.count ?? 0)
            if aMemberCount != bMemberCount { return aMemberCount > bMemberCount }

            let aSatCount = speakers[a.coordinator]?.bondedSatellites.count ?? 0
            let bSatCount = speakers[b.coordinator]?.bondedSatellites.count ?? 0
            if aSatCount != bSatCount { return aSatCount > bSatCount }

            return a < b
        }

        var updated = rawStatus

        func clearGroup(_ groupID: GroupID) {
            let vol = updated[groupID]?.volume ?? speakers[groupID.coordinator]?.volume ?? .v0
            updated[groupID] = GroupStatus(playback: .stopped, volume: vol)
        }

        var playingGroups: [(id: GroupID, nowPlaying: NowPlaying)] = []
        for groupID in validGroups {
            if let status = updated[groupID],
               case .playing(let nowPlaying, _, _) = status.playback {
                playingGroups.append((groupID, nowPlaying))
            }
        }

        // 0. If multiple groups claim to be .playing the same track or Spotify stream simultaneously,
        // keep only the highest-priority playing group.
        if playingGroups.count > 1 {
            let sortedPlaying = playingGroups.sorted { groupPreferenceRank($0.id, $1.id) }
            var keptPlaying: [(id: GroupID, nowPlaying: NowPlaying)] = []
            for candidate in sortedPlaying {
                let conflictsWithKept = keptPlaying.contains { kept in
                    kept.nowPlaying.matchesSession(of: candidate.nowPlaying)
                }
                if conflictsWithKept {
                    clearGroup(candidate.id)
                } else {
                    keptPlaying.append(candidate)
                }
            }
            playingGroups = keptPlaying
        }

        // 1. Suppress stale .paused sessions when another group is .playing:
        // If ANY group in the household is .playing, any OTHER group that is .paused with:
        // - the same track (title + artist or spotifyURI), OR
        // - a Spotify track (uri contains spotify / source.isSpotify), OR
        // - any leftover paused track/stream while another group is actively playing a music/stream session
        // must have its stale paused session cleared to .stopped.
        if !playingGroups.isEmpty {
            let anyPlayingMusicOrStream = playingGroups.contains {
                switch $0.nowPlaying {
                case .track, .stream: return true
                case .tvAudio: return false
                }
            }
            for groupID in validGroups {
                guard let status = updated[groupID],
                      case .paused(let pausedNow, _) = status.playback else {
                    continue
                }
                let matchesPlaying = playingGroups.contains { playing in
                    playing.nowPlaying.matchesSession(of: pausedNow)
                }
                // A paused session on a Spotify account that no room is playing is that account's
                // own session, so it stays even while a different account plays elsewhere.
                let isOwnAccountSession = pausedNow.spotifyAccountSerial != nil
                let isSpotifyPaused = pausedNow.isSpotifyOrStreaming
                let isStaleMusicSession: Bool = switch pausedNow {
                case .track, .stream: anyPlayingMusicOrStream
                case .tvAudio: false
                }
                if matchesPlaying || (!isOwnAccountSession && (isSpotifyPaused || isStaleMusicSession)) {
                    clearGroup(groupID)
                }
            }
        }

        // 2. Deduplicate .paused sessions: if multiple groups report the same .paused track (or .paused
        // Spotify sessions on one account), only ONE group retains the .paused session; clear the stale
        // duplicate .paused track from the other rooms.
        var pausedGroups: [(id: GroupID, nowPlaying: NowPlaying)] = []
        for groupID in validGroups {
            if let status = updated[groupID],
               case .paused(let nowPlaying, _) = status.playback {
                pausedGroups.append((groupID, nowPlaying))
            }
        }
        guard pausedGroups.count > 1 else { return updated }

        let sortedPaused = pausedGroups.sorted { groupPreferenceRank($0.id, $1.id) }
        var keptPaused: [(id: GroupID, nowPlaying: NowPlaying)] = []
        for candidate in sortedPaused {
            let isDuplicate = keptPaused.contains { kept in
                kept.nowPlaying.matchesSession(of: candidate.nowPlaying)
            }
            if isDuplicate {
                clearGroup(candidate.id)
            } else {
                keptPaused.append(candidate)
            }
        }

        return updated
    }

    private static func buildGroups(
        speakers: [SpeakerUUID: Speaker],
        topology: Topology,
        groupStatus: [GroupID: GroupStatus]
    ) -> [SonosGroup] {
        let roomCount = speakers.count
        return topology.groups.compactMap { groupID, memberIDs -> SonosGroup? in
            guard let coordinator = speakers[groupID.coordinator] else { return nil }
            let members = memberIDs.compactMap { speakers[$0] }.sorted { lhs, rhs in
                let left = RoomNaming.shortName(lhs.roomName, merged: false)
                let right = RoomNaming.shortName(rhs.roomName, merged: false)
                if left != right { return left < right }
                return lhs.id < rhs.id
            }
            let status = groupStatus[groupID]
                ?? GroupStatus(playback: .stopped, volume: speakers[groupID.coordinator]?.volume ?? .v0)
            return SonosGroup(
                id: groupID,
                coordinator: coordinator,
                members: members,
                playback: status.playback,
                volume: status.volume,
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
        status: (GroupID, GroupStatus)? = nil,
        externalSpotify: SpotifyTrackContext?? = nil,
        connectedSpotifyGroup: GroupID?? = nil
    ) -> HouseholdSnapshot {
        var statuses = reportedStatus
        if let status { statuses[status.0] = status.1 }
        let resolvedExternal = externalSpotify ?? self.externalSpotify
        return HouseholdSnapshot(
            household: household,
            observedAt: observedAt,
            speakers: speakers ?? self.speakers,
            topology: topology ?? self.topology,
            groupStatus: statuses,
            rf: rf,
            presets: presets,
            networkName: networkName,
            externalSpotify: resolvedExternal,
            connectedSpotifyGroup: connectedSpotifyGroup ?? self.connectedSpotifyGroup)
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
