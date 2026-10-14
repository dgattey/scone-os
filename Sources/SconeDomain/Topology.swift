/// Who is grouped with whom, among visible speakers present in the latest sweep.
///
/// Stored as member -> coordinator, with each coordinator mapping to itself. A dictionary key
/// cannot repeat, so no speaker can sit in two groups. The initializer rejects a value that does
/// not map to itself, so no group can point at a missing coordinator.
public struct Topology: Hashable, Sendable {
    private let coordinatorOf: [SpeakerUUID: SpeakerUUID]

    package init?(coordinatorOf: [SpeakerUUID: SpeakerUUID]) {
        guard coordinatorOf.values.allSatisfy({ coordinatorOf[$0] == $0 }) else { return nil }
        self.coordinatorOf = coordinatorOf
    }

    private init(trusted coordinatorOf: [SpeakerUUID: SpeakerUUID]) { self.coordinatorOf = coordinatorOf }

    public static let empty = Topology(trusted: [:])

    public var speakers: Set<SpeakerUUID> { Set(coordinatorOf.keys) }

    /// Members exclude the coordinator.
    public var groups: [GroupID: Set<SpeakerUUID>] {
        fatalError("not implemented")
    }

    public func group(of speaker: SpeakerUUID) -> GroupID? {
        coordinatorOf[speaker].map(GroupID.init(coordinator:))
    }

    /// Total: a step that cannot apply (unknown speaker, join into a non-coordinator) returns `self`.
    ///
    /// When a coordinator with members leaves, Sonos picks the remaining members' new coordinator.
    /// This simulation picks the lowest UUID. Callers verify targets with `isSatisfied(by:)`, which
    /// never depends on that choice.
    public func applying(_ step: TopologyStep) -> Topology {
        // TODO:
        // .makeStandalone(s): if s coordinates others, remap them to min(others); coordinatorOf[s] = s
        // .join(m, c): guard coordinatorOf[c] == c, m != c, m present; promote as above if m
        //   coordinates others; coordinatorOf[m] = c
        fatalError("not implemented")
    }
}

/// One SOAP call's worth of regrouping. The boundary maps these one-to-one onto
/// `BecomeCoordinatorOfStandaloneGroup` and `SetAVTransportURI(x-rincon:<coordinator>)`, both sent to `member`.
public enum TopologyStep: Hashable, Sendable {
    case makeStandalone(SpeakerUUID)
    case join(SpeakerUUID, coordinator: SpeakerUUID)
}

/// A desired end state, not a sequence of moves. Every topology command reduces to one, which
/// is what makes them idempotent: planning against a topology that already satisfies the target
/// yields no steps.
public enum TopologyTarget: Hashable, Sendable {
    /// `group(member:intoCoordinator:)`. Joins an existing group and fails if it has dissolved.
    case memberOf(GroupID, member: SpeakerUUID)
    /// `ungroup(member:)`. The speaker shares a group with nobody.
    case standalone(SpeakerUUID)
    /// `applyPreset`. The coordinator leads exactly these members. The coordinator leaves its
    /// current group if needed, and speakers in its group that are not in the preset are released.
    case exactGroup(coordinator: SpeakerUUID, members: Set<SpeakerUUID>)

    /// `absent` holds speakers that are offline right now. The boundary passes the plan's
    /// `skipped` set when verifying a partial application. Preset pills pass nothing, so a pill only
    /// lights up when every room is actually there.
    public func isSatisfied(by topology: Topology, ignoring absent: Set<SpeakerUUID> = []) -> Bool {
        fatalError("not implemented")
    }

    /// Pure. Invariants, checked by property tests over generated topologies:
    /// - applying every planned step yields a topology where `isSatisfied(by:ignoring: skipped)` holds;
    /// - planning again from that result yields `.steps([], skipped:)`.
    public func plan(from topology: Topology) -> TopologyPlan {
        // TODO for .exactGroup(c, M):
        //   guard topology.speakers.contains(c) else .impossible(.coordinatorMissing(c))
        //   skipped = M - topology.speakers
        //   steps = []
        //   if group(of: c) != c                         -> .makeStandalone(c)
        //   for x in current members of c not in M        -> .makeStandalone(x)   // c keeps its queue
        //   for m in (M ∩ present) where group(of: m) != c -> .join(m, coordinator: c)
        // .memberOf(g, m): guard coordinator still coordinates, else .impossible(.groupDissolved(g))
        // .standalone(s): absent -> skipped; already alone -> []; otherwise [.makeStandalone(s)]
        fatalError("not implemented")
    }
}

public enum TopologyPlan: Hashable, Sendable {
    /// Empty `steps` means the target already holds.
    case steps([TopologyStep], skipped: Set<SpeakerUUID>)
    case impossible(TopologyPlanFailure)
}

public enum TopologyPlanFailure: Hashable, Sendable {
    case coordinatorMissing(SpeakerUUID)
    case groupDissolved(GroupID)
}
