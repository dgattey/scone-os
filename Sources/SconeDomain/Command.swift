/// Everything SconeOS can ask a Sonos household to do. Each case is idempotent: sending it twice,
/// or again after a crash halfway through, converges on the same end state.
public enum SonosCommand: Hashable, Sendable {
    case group(member: SpeakerUUID, intoCoordinator: GroupID)
    case ungroup(member: SpeakerUUID)
    case applyPreset(PresetPill)
    case setVolume(DiscreteVolume, for: VolumeTarget)
    case playPause(PlayPause, group: GroupID)
    /// Sent as an absolute `Seek(TRACK_NR, n + 1)` computed once per command, so a retry
    /// re-seeks to the same track instead of skipping twice.
    case nextTrack(group: GroupID)
    /// Past 3 seconds into the track this restarts it (`Seek(REL_TIME, 0)`), otherwise it seeks to n - 1.
    case previousTrack(group: GroupID)
    /// A no-op when the coordinator is already playing `uri`. Otherwise inserts after the current
    /// queue position, seeks to it, plays, and seeks to `startingAt` when given.
    case enqueueAndPlaySpotify(
        uri: SpotifyURI, metadata: SpotifyTrackMetadata, onCoordinator: GroupID, startingAt: Duration? = nil)

    /// The three topology commands share one planner. nil for the rest.
    public var topologyTarget: TopologyTarget? {
        switch self {
        case .group(let member, let group): .memberOf(group, member: member)
        case .ungroup(let member): .standalone(member)
        case .applyPreset(let preset): preset.target
        case .setVolume, .playPause, .nextTrack, .previousTrack, .enqueueAndPlaySpotify: nil
        }
    }
}

public enum CommandOutcome: Hashable, Sendable {
    case applied
    /// Nothing was sent because the household already matched.
    case alreadySatisfied
    /// Offline preset members were skipped. Everyone reachable converged.
    case partiallyApplied(unreachable: Set<SpeakerUUID>)
}

public enum SonosCommandError: Error, Hashable, Sendable {
    case speakerUnreachable(SpeakerUUID)
    case groupDissolved(GroupID)
    /// The topology did not reach the target before the convergence timeout. The probe household
    /// converged in 420 to 695 ms.
    case notConverged(after: Duration)
    /// next or previous on radio, line-in, or TV audio.
    case unsupportedForCurrentSource
    /// The household has no linked Spotify account to play through.
    case spotifyNotLinkedOnSonos
    /// A UPnP fault, with the action name and fault code for diagnostics.
    case speakerRejected(detail: String)
}
