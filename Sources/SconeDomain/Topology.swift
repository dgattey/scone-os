public struct Topology: Hashable, Sendable {
    private let coordinatorOf: [SpeakerUUID: SpeakerUUID]

    package init?(coordinatorOf: [SpeakerUUID: SpeakerUUID]) {
        guard coordinatorOf.values.allSatisfy({ coordinatorOf[$0] == $0 }) else { return nil }
        self.coordinatorOf = coordinatorOf
    }

    private init(trusted coordinatorOf: [SpeakerUUID: SpeakerUUID]) { self.coordinatorOf = coordinatorOf }

    public static let empty = Topology(trusted: [:])

    public var speakers: Set<SpeakerUUID> { Set(coordinatorOf.keys) }

    public var groups: [GroupID: Set<SpeakerUUID>] {
        var membersByCoordinator: [SpeakerUUID: Set<SpeakerUUID>] = [:]
        for (speaker, coordinator) in coordinatorOf {
            var members = membersByCoordinator[coordinator] ?? []
            if speaker != coordinator { members.insert(speaker) }
            membersByCoordinator[coordinator] = members
        }
        return Dictionary(
            uniqueKeysWithValues: membersByCoordinator.map { coordinator, members in
                (GroupID(coordinator: coordinator), members)
            })
    }

    public func group(of speaker: SpeakerUUID) -> GroupID? {
        coordinatorOf[speaker].map(GroupID.init(coordinator:))
    }

    public func applying(_ step: TopologyStep) -> Topology {
        switch step {
        case .makeStandalone(let speaker):
            guard coordinatorOf[speaker] != nil else { return self }
            return Topology(coordinatorOf: coordinatorMap(makingStandalone: speaker)) ?? self
        case .delegateCoordination(let oldCoordinator, let newCoordinator, let rejoinGroup):
            guard coordinatorOf[oldCoordinator] == oldCoordinator,
                coordinatorOf[newCoordinator] == oldCoordinator,
                oldCoordinator != newCoordinator
            else {
                return self
            }
            var map = coordinatorOf
            let groupMembers = map.keys.filter { map[$0] == oldCoordinator }
            for member in groupMembers {
                map[member] = newCoordinator
            }
            map[oldCoordinator] = rejoinGroup ? newCoordinator : oldCoordinator
            return Topology(coordinatorOf: map) ?? self
        case .join(let member, coordinator: let coordinator):
            guard coordinatorOf[coordinator] == coordinator, member != coordinator, coordinatorOf[member] != nil else {
                return self
            }
            var map = coordinatorMap(makingStandalone: member)
            map[member] = coordinator
            return Topology(coordinatorOf: map) ?? self
        }
    }

    private func coordinatorMap(makingStandalone speaker: SpeakerUUID) -> [SpeakerUUID: SpeakerUUID] {
        var map = coordinatorOf
        let members = map.keys.filter { $0 != speaker && map[$0] == speaker }
        if let promoted = members.min() {
            for member in members { map[member] = promoted }
        }
        map[speaker] = speaker
        return map
    }
}

public enum TopologyStep: Hashable, Sendable {
    case makeStandalone(SpeakerUUID)
    case delegateCoordination(from: SpeakerUUID, to: SpeakerUUID, rejoinGroup: Bool)
    case join(SpeakerUUID, coordinator: SpeakerUUID)
}

public enum TopologyTarget: Hashable, Sendable {
    case memberOf(GroupID, member: SpeakerUUID)
    case standalone(SpeakerUUID)
    case exactGroup(coordinator: SpeakerUUID, members: Set<SpeakerUUID>)

    public func isSatisfied(by topology: Topology, ignoring absent: Set<SpeakerUUID> = []) -> Bool {
        switch self {
        case .memberOf(let group, let member):
            if absent.contains(member) { return topology.group(of: group.coordinator) == group }
            return topology.group(of: member) == group
        case .standalone(let speaker):
            if absent.contains(speaker) { return true }
            guard topology.group(of: speaker)?.coordinator == speaker else { return false }
            return topology.groups[GroupID(coordinator: speaker), default: []].isEmpty
        case .exactGroup(let coordinator, let members):
            guard topology.group(of: coordinator)?.coordinator == coordinator else { return false }
            let required = members.subtracting(absent).subtracting([coordinator])
            guard required.isSubset(of: topology.speakers) else { return false }
            let actual = topology.groups[GroupID(coordinator: coordinator), default: []]
            let extras = actual.subtracting(members).subtracting(absent)
            return required.isSubset(of: actual) && extras.isEmpty
        }
    }

    public func plan(from topology: Topology) -> TopologyPlan {
        switch self {
        case .memberOf(let group, let member):
            guard topology.group(of: group.coordinator) == group else {
                return .impossible(.groupDissolved(group))
            }
            if !topology.speakers.contains(member) { return .steps([], skipped: [member]) }
            if topology.group(of: member) == group { return .steps([], skipped: []) }
            return .steps([.join(member, coordinator: group.coordinator)], skipped: [])
        case .standalone(let speaker):
            if !topology.speakers.contains(speaker) { return .steps([], skipped: [speaker]) }
            if isSatisfied(by: topology) { return .steps([], skipped: []) }
            let groupID = GroupID(coordinator: speaker)
            let currentMembers = topology.groups[groupID, default: []].subtracting([speaker])
            if topology.group(of: speaker) == groupID, let promoted = currentMembers.min() {
                return .steps([.delegateCoordination(from: speaker, to: promoted, rejoinGroup: false)], skipped: [])
            }
            return .steps([.makeStandalone(speaker)], skipped: [])
        case .exactGroup(let coordinator, let members):
            guard topology.speakers.contains(coordinator) else {
                return .impossible(.coordinatorMissing(coordinator))
            }
            let desired = members.subtracting([coordinator])
            let skipped = desired.subtracting(topology.speakers)
            var steps: [TopologyStep] = []
            if topology.group(of: coordinator) != GroupID(coordinator: coordinator) {
                steps.append(.makeStandalone(coordinator))
            }
            let currentMembers = topology.groups[GroupID(coordinator: coordinator), default: []]
            for extra in currentMembers.subtracting(desired).sorted() {
                steps.append(.makeStandalone(extra))
            }
            let joining = desired.intersection(topology.speakers)
                .filter { topology.group(of: $0) != GroupID(coordinator: coordinator) }
                .sorted()
            for member in joining {
                steps.append(.join(member, coordinator: coordinator))
            }
            return .steps(steps, skipped: skipped)
        }
    }
}

public enum TopologyPlan: Hashable, Sendable {
    case steps([TopologyStep], skipped: Set<SpeakerUUID>)
    case impossible(TopologyPlanFailure)
}

public enum TopologyPlanFailure: Hashable, Sendable {
    case coordinatorMissing(SpeakerUUID)
    case groupDissolved(GroupID)
}
