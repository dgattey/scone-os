public enum SonosCommand: Hashable, Sendable {
    case group(member: SpeakerUUID, intoCoordinator: GroupID)
    case ungroup(member: SpeakerUUID)
    case applyPreset(PresetPill)
    case setVolume(DiscreteVolume, for: VolumeTarget)
    case playPause(PlayPause, group: GroupID)
    case nextTrack(group: GroupID)
    case previousTrack(group: GroupID)
    /// UPnP Play, only when the coordinator's transport is Spotify Connect (`x-sonos-vli:`), including a
    /// dormant one. Fails with `unsupportedForCurrentSource` otherwise.
    case resumeSpotifyConnect(group: GroupID)
    /// Sonos local API `playback:1 setPlayModes`, which toggles Spotify Connect shuffle on a Sonos room.
    case setShuffle(Bool, group: GroupID)
    case enqueueAndPlaySpotify(
        uri: SpotifyURI,
        metadata: SpotifyTrackMetadata,
        onCoordinator: GroupID,
        startingAt: Duration? = nil,
        contextURI: SpotifyURI? = nil,
        upNext: [QueueItem] = []
    )
    case savePresets([PresetPill])
    case setSystemName(String)

    public var topologyTarget: TopologyTarget? {
        switch self {
        case .group(let member, let group): .memberOf(group, member: member)
        case .ungroup(let member): .standalone(member)
        case .applyPreset(let preset): preset.target
        case .setVolume, .playPause, .nextTrack, .previousTrack, .resumeSpotifyConnect, .setShuffle,
             .enqueueAndPlaySpotify, .savePresets, .setSystemName: nil
        }
    }
}

public enum CommandOutcome: Hashable, Sendable {
    case applied
    case alreadySatisfied
    case partiallyApplied(unreachable: Set<SpeakerUUID>)
}

public enum SonosCommandError: Error, Hashable, Sendable {
    case speakerUnreachable(SpeakerUUID)
    case groupDissolved(GroupID)
    case notConverged(after: Duration)
    case unsupportedForCurrentSource
    case spotifyNotLinkedOnSonos
    case speakerRejected(detail: String)
}
