import Foundation
import SconeDomain

public actor SonosHousehold {
    public struct Configuration: Sendable {
        public var sweepInterval: Duration = .seconds(2)
        public var telemetryInterval: Duration = .seconds(30)
        public var offlineAfter: Duration = .seconds(10)
        public var convergenceTimeout: Duration = .seconds(8)
        public init() {}
    }

    private struct DeviceFacts: Sendable {
        var modelNumber: String
        var displayName: String
    }

    private let configuration: Configuration
    private let client = SOAPClient()
    private var addressBook: AddressBook
    private var latest: HouseholdSnapshot?
    private var subscribers: [UUID: AsyncStream<HouseholdSnapshot>.Continuation] = [:]
    private var sweepTask: Task<Void, Never>?
    private var sweepGeneration = 0
    private var commandDepth = 0
    private var lanes: [SpeakerUUID: CommandLane] = [:]
    private let topologyLane = CommandLane()
    private var spotifyAccount: SpotifyOnSonos.Account?

    private var models: [SpeakerUUID: DeviceFacts] = [:]
    private var radios: [SpeakerUUID: TelemetryService.RadioStatus] = [:]
    private var batteries: [SpeakerUUID: BatteryTelemetry] = [:]
    private var volumes: [SpeakerUUID: DiscreteVolume] = [:]
    private var groupVolumes: [SpeakerUUID: DiscreteVolume] = [:]
    private var playback: [SpeakerUUID: PlaybackState] = [:]
    private var lastParsed: TopologyService.Parsed?
    private var cachedSpeakers: [SpeakerUUID: Speaker] = [:]
    private var missingSince: [SpeakerUUID: Date] = [:]
    private var lastTelemetry: Date?
    private var unreachableSince: Date?

    public init(seedIPs: [String], configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.addressBook = AddressBook(seedIPs: seedIPs)
    }

    public nonisolated func snapshots() -> AsyncStream<HouseholdSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            let task = Task { await self.register(id, continuation) }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.unregister(id) }
            }
        }
    }

    public func send(_ command: SonosCommand) async throws(SonosCommandError) -> CommandOutcome {
        commandDepth += 1
        defer { commandDepth -= 1 }
        let result: Result<CommandOutcome, SonosCommandError>
        if let target = command.topologyTarget {
            result = await topologyLane.run { await self.topologyOutcome(target) }
        } else {
            result = await lane(for: laneSpeaker(for: command)).run { await self.commandOutcome(command) }
        }
        switch result {
        case .success(let outcome): return outcome
        case .failure(let error): throw error
        }
    }

    private func topologyOutcome(_ target: TopologyTarget) async -> Result<CommandOutcome, SonosCommandError> {
        do { return .success(try await applyTopology(target)) } catch { return .failure(error) }
    }

    private func commandOutcome(_ command: SonosCommand) async -> Result<CommandOutcome, SonosCommandError> {
        do { return .success(try await apply(command)) } catch { return .failure(error) }
    }

    private func register(_ id: UUID, _ continuation: AsyncStream<HouseholdSnapshot>.Continuation) {
        if Task.isCancelled { return }
        subscribers[id] = continuation
        if let latest { continuation.yield(latest) }
        guard sweepTask == nil else { return }
        sweepGeneration += 1
        let generation = sweepGeneration
        sweepTask = Task { await self.sweepLoop(generation) }
    }

    private func unregister(_ id: UUID) {
        subscribers.removeValue(forKey: id)
        guard subscribers.isEmpty else { return }
        sweepGeneration += 1
        sweepTask?.cancel()
        sweepTask = nil
    }

    private func sweepLoop(_ generation: Int) async {
        while generation == sweepGeneration, !Task.isCancelled, !subscribers.isEmpty {
            let started = ContinuousClock.now
            if commandDepth == 0 { await sweepOnce(generation) }
            guard generation == sweepGeneration else { return }
            let pause: Duration = commandDepth == 0 ? configuration.sweepInterval : .milliseconds(200)
            let elapsed = started.duration(to: .now)
            if pause > elapsed { try? await Task.sleep(for: pause - elapsed) }
        }
    }

    private func sweepOnce(_ generation: Int) async {
        guard generation == sweepGeneration else { return }
        guard let parsed = await fetchTopology() else {
            guard generation == sweepGeneration else { return }
            noteUnreachable()
            return
        }
        guard generation == sweepGeneration else { return }
        unreachableSince = nil
        addressBook.absorb(parsed)
        lastParsed = parsed
        await refreshTransport(parsed)
        let due = telemetryDue
        await refreshDescriptions(parsed, force: due)
        if due {
            await refreshRadiosAndBatteries(parsed)
            lastTelemetry = Date()
        }
        guard generation == sweepGeneration else { return }
        rememberAbsence(parsed, now: Date())
        if let snapshot = assemble(now: Date()) { publish(snapshot) }
    }

    private func noteUnreachable() {
        let now = Date()
        if unreachableSince == nil { unreachableSince = now }
        let elapsed = now.timeIntervalSince(unreachableSince ?? now)
        guard elapsed >= seconds(configuration.offlineAfter), latest?.speakers.isEmpty != true else { return }
        publish(HouseholdSnapshot(observedAt: now, speakers: [:], topology: .empty, groupStatus: [:], rf: .empty))
    }

    private var telemetryDue: Bool {
        guard let lastTelemetry else { return true }
        return Date().timeIntervalSince(lastTelemetry) >= seconds(configuration.telemetryInterval)
    }

    private func fetchTopology() async -> TopologyService.Parsed? {
        if let parsed = await firstTopology(among: addressBook.seeds) { return parsed }
        return await withTaskGroup(of: TopologyService.Parsed?.self) { group in
            group.addTask {
                for await endpoint in Discovery.seeds() {
                    if Task.isCancelled { return nil }
                    if let parsed = await self.parseTopology(at: endpoint) { return parsed }
                }
                return nil
            }
            var found: TopologyService.Parsed?
            for await parsed in group {
                if let parsed {
                    found = parsed
                    group.cancelAll()
                }
            }
            return found
        }
    }

    private func firstTopology(among endpoints: [URL]) async -> TopologyService.Parsed? {
        let unique = endpoints.reduce(into: [URL]()) { list, endpoint in
            if !list.contains(endpoint) { list.append(endpoint) }
        }
        guard !unique.isEmpty else { return nil }
        return await withTaskGroup(of: TopologyService.Parsed?.self) { group in
            for endpoint in unique {
                group.addTask { await self.parseTopology(at: endpoint) }
            }
            for await parsed in group {
                if let parsed {
                    group.cancelAll()
                    return parsed
                }
            }
            return nil
        }
    }

    private func parseTopology(at endpoint: URL) async -> TopologyService.Parsed? {
        do {
            let node = try await client.call(TopologyService.getZoneGroupState, at: endpoint)
            let xml = node.value("ZoneGroupState")
            guard !xml.isEmpty else { return nil }
            return try TopologyService.parse(zoneGroupState: xml)
        } catch {
            return nil
        }
    }

    private func refreshTransport(_ parsed: TopologyService.Parsed) async {
        let coordinators = Set(parsed.members.keys.compactMap { parsed.topology.group(of: $0)?.coordinator })
        let reads = await withTaskGroup(of: TransportRead?.self) { group in
            for (id, member) in parsed.members {
                group.addTask {
                    guard let volume = try? await self.volume(of: id, at: member.endpoint) else { return nil }
                    return .volume(id, volume)
                }
            }
            for id in coordinators {
                guard let endpoint = parsed.members[id]?.endpoint else { continue }
                group.addTask {
                    guard let state = try? await self.playbackState(of: id, at: endpoint) else { return nil }
                    return .playback(id, state)
                }
                group.addTask {
                    guard let volume = try? await self.groupVolume(of: id, at: endpoint) else { return nil }
                    return .groupVolume(id, volume)
                }
            }
            var found: [TransportRead] = []
            for await read in group {
                if let read { found.append(read) }
            }
            return found
        }
        for read in reads {
            switch read {
            case .volume(let id, let volume): volumes[id] = volume
            case .groupVolume(let id, let volume): groupVolumes[id] = volume
            case .playback(let id, let state): playback[id] = state
            }
        }
    }

    private func refreshDescriptions(_ parsed: TopologyService.Parsed, force: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            for (id, member) in parsed.members where force || models[id] == nil {
                group.addTask { await self.readDescription(id, endpoint: member.endpoint) }
            }
        }
    }

    private func refreshRadiosAndBatteries(_ parsed: TopologyService.Parsed) async {
        let resolve = macResolver(for: parsed)
        await withTaskGroup(of: Void.self) { group in
            for (id, member) in parsed.members {
                group.addTask { await self.readRadio(id, endpoint: member.endpoint, resolve: resolve) }
                if self.models[id]?.modelNumber == "S17" {
                    group.addTask { await self.readBattery(id, endpoint: member.endpoint) }
                }
            }
        }
    }

    private func readDescription(_ id: SpeakerUUID, endpoint: URL) async {
        guard let data = try? await client.get("/xml/device_description.xml", at: endpoint),
              let facts = try? TelemetryService.parseDeviceDescription(data) else { return }
        models[id] = DeviceFacts(modelNumber: facts.modelNumber, displayName: facts.displayName)
    }

    private func readRadio(
        _ id: SpeakerUUID, endpoint: URL, resolve: @escaping @Sendable (String) -> SpeakerUUID?
    ) async {
        guard let data = try? await client.get("/status/proc/ath_rincon/status", at: endpoint),
              let text = String(data: data, encoding: .utf8) else { return }
        radios[id] = TelemetryService.parseRadioStatus(text, resolve: resolve)
    }

    private func readBattery(_ id: SpeakerUUID, endpoint: URL) async {
        guard let data = try? await client.get("/status/batterystatus", at: endpoint),
              let battery = try? TelemetryService.parseBatteryStatus(data, sampledAt: Date()) else { return }
        batteries[id] = battery
    }

    private func macResolver(for parsed: TopologyService.Parsed) -> @Sendable (String) -> SpeakerUUID? {
        var entries: [String: SpeakerUUID] = [:]
        func add(_ id: SpeakerUUID) { entries[String(id.macHex).uppercased()] = id }
        for id in parsed.members.keys { add(id) }
        for member in parsed.members.values {
            for satellite in member.satellites { add(satellite.id) }
        }
        let table = entries
        return { table[$0.uppercased()] }
    }

    private func rememberAbsence(_ parsed: TopologyService.Parsed, now: Date) {
        let present = Set(parsed.members.keys)
        for id in present { missingSince[id] = nil }
        for id in cachedSpeakers.keys where !present.contains(id) && missingSince[id] == nil {
            missingSince[id] = now
        }
        let limit = seconds(configuration.offlineAfter)
        for (id, since) in missingSince where now.timeIntervalSince(since) >= limit {
            missingSince[id] = nil
            cachedSpeakers[id] = nil
            volumes[id] = nil
        }
    }

    private func assemble(now: Date) -> HouseholdSnapshot? {
        guard let parsed = lastParsed else { return nil }
        var speakers: [SpeakerUUID: Speaker] = [:]
        for (id, member) in parsed.members {
            let radio = radios[id]
            let satellites = member.satellites.map { satellite in
                BondedSatellite(id: satellite.id, role: satellite.role, linkQuality: radio?.satelliteLinkQuality[satellite.id])
            }
            let facts = models[id]
            let speaker = Speaker(
                id: id,
                roomName: member.roomName,
                model: TelemetryService.model(
                    number: facts?.modelNumber ?? "",
                    displayName: facts?.displayName ?? member.roomName,
                    satellites: satellites,
                    battery: batteries[id]),
                reachability: .online(ip: member.endpoint.host ?? "", rssi: radio?.rssi, noiseFloor: radio?.noiseFloor),
                volume: volumes[id] ?? .v0)
            speakers[id] = speaker
            cachedSpeakers[id] = speaker
        }
        let limit = seconds(configuration.offlineAfter)
        for (id, since) in missingSince where now.timeIntervalSince(since) < limit {
            if speakers[id] == nil, let cached = cachedSpeakers[id] { speakers[id] = cached }
        }

        var status: [GroupID: GroupStatus] = [:]
        let coordinators = Set(parsed.members.keys.compactMap { parsed.topology.group(of: $0)?.coordinator })
        for coordinator in coordinators {
            guard let group = parsed.topology.group(of: coordinator) else { continue }
            status[group] = GroupStatus(
                playback: playback[coordinator] ?? .stopped,
                volume: groupVolumes[coordinator] ?? volumes[coordinator] ?? .v0)
        }

        var matrix = RFPeerMatrix.empty
        for id in radios.keys.sorted() {
            guard speakers[id] != nil, let radio = radios[id] else { continue }
            for peer in radio.peers.sorted(by: { $0.peer < $1.peer }) where speakers[peer.peer] != nil {
                matrix.record(id, peer.peer, from: peer.from, to: peer.to)
            }
        }
        return HouseholdSnapshot(
            observedAt: now, speakers: speakers, topology: parsed.topology, groupStatus: status, rf: matrix)
    }

    private func publish(_ snapshot: HouseholdSnapshot) {
        if let latest, sameHouse(latest, snapshot) { return }
        latest = snapshot
        for continuation in subscribers.values { continuation.yield(snapshot) }
    }

    private func publishAssembled() {
        if let snapshot = assemble(now: Date()) { publish(snapshot) }
    }

    private func sameHouse(_ lhs: HouseholdSnapshot, _ rhs: HouseholdSnapshot) -> Bool {
        guard lhs.speakers == rhs.speakers, lhs.topology == rhs.topology, lhs.rf == rhs.rf else { return false }
        let groups = Set(lhs.topology.speakers.compactMap { lhs.topology.group(of: $0) })
            .union(rhs.topology.speakers.compactMap { rhs.topology.group(of: $0) })
        return groups.allSatisfy { lhs.status(of: $0) == rhs.status(of: $0) }
    }

    private func applyTopology(_ target: TopologyTarget) async throws(SonosCommandError) -> CommandOutcome {
        let anchor = anchorSpeaker(target)
        try await refreshBook(anchor: anchor)
        guard let topology = lastParsed?.topology else { throw .speakerUnreachable(anchor) }
        switch target.plan(from: topology) {
        case .impossible(.coordinatorMissing(let speaker)):
            throw .speakerUnreachable(speaker)
        case .impossible(.groupDissolved(let group)):
            throw .groupDissolved(group)
        case .steps(let steps, let skipped):
            if steps.isEmpty { return .alreadySatisfied }
            for step in steps {
                let action = TopologyService.request(for: step)
                let endpoint = try endpoint(for: action.target)
                _ = try await client.call(action.request, on: action.target, at: endpoint)
            }
            let parsed = try await waitForTopology(target, ignoring: skipped)
            addressBook.absorb(parsed)
            lastParsed = parsed
            await refreshTransport(parsed)
            publishAssembled()
            return skipped.isEmpty ? .applied : .partiallyApplied(unreachable: skipped)
        }
    }

    private func waitForTopology(_ target: TopologyTarget, ignoring skipped: Set<SpeakerUUID>) async throws(SonosCommandError) -> TopologyService.Parsed {
        let deadline = ContinuousClock.now.advanced(by: configuration.convergenceTimeout)
        while true {
            if let parsed = await fetchTopology(), target.isSatisfied(by: parsed.topology, ignoring: skipped) {
                return parsed
            }
            if ContinuousClock.now >= deadline { throw .notConverged(after: configuration.convergenceTimeout) }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func apply(_ command: SonosCommand) async throws(SonosCommandError) -> CommandOutcome {
        switch command {
        case .group, .ungroup, .applyPreset:
            guard let target = command.topologyTarget else { return .alreadySatisfied }
            return try await applyTopology(target)
        case .setVolume(let volume, .speaker(let speaker)):
            return try await setSpeakerVolume(volume, speaker: speaker)
        case .setVolume(let volume, .group(let group)):
            return try await setGroupVolume(volume, group: group)
        case .playPause(let desired, let group):
            return try await setTransport(desired, group: group)
        case .nextTrack(let group):
            return try await skipNext(group)
        case .previousTrack(let group):
            return try await skipPrevious(group)
        case .enqueueAndPlaySpotify(let uri, let metadata, let group, let startingAt):
            return try await enqueueSpotify(uri, metadata: metadata, group: group, startingAt: startingAt)
        }
    }

    private func setSpeakerVolume(_ volume: DiscreteVolume, speaker: SpeakerUUID) async throws(SonosCommandError) -> CommandOutcome {
        try await refreshBook(anchor: speaker)
        let endpoint = try endpoint(for: speaker)
        let current = try await self.volume(of: speaker, at: endpoint)
        volumes[speaker] = current
        if current == volume {
            publishAssembled()
            return .alreadySatisfied
        }
        _ = try await client.call(TransportService.setVolume(volume), on: speaker, at: endpoint)
        volumes[speaker] = await readBackVolume(speaker, at: endpoint, fallback: volume)
        publishAssembled()
        return .applied
    }

    private func setGroupVolume(_ volume: DiscreteVolume, group: GroupID) async throws(SonosCommandError) -> CommandOutcome {
        let coordinator = group.coordinator
        try await refreshBook(anchor: coordinator)
        let endpoint = try endpoint(for: coordinator)
        let current = try await groupVolume(of: coordinator, at: endpoint)
        groupVolumes[coordinator] = current
        if current == volume {
            publishAssembled()
            return .alreadySatisfied
        }
        _ = try await client.call(TransportService.setGroupVolume(volume), on: coordinator, at: endpoint)
        try? await Task.sleep(for: .milliseconds(200))
        groupVolumes[coordinator] = (try? await groupVolume(of: coordinator, at: endpoint)) ?? volume
        await rereadMemberVolumes(of: coordinator)
        publishAssembled()
        return .applied
    }

    private func setTransport(_ desired: PlayPause, group: GroupID) async throws(SonosCommandError) -> CommandOutcome {
        let coordinator = group.coordinator
        try await refreshBook(anchor: coordinator)
        let endpoint = try endpoint(for: coordinator)
        let state = try await playbackState(of: coordinator, at: endpoint)
        playback[coordinator] = state
        if transportMatches(state, desired) {
            publishAssembled()
            return .alreadySatisfied
        }
        _ = try await client.call(TransportService.transport(desired), on: coordinator, at: endpoint)
        playback[coordinator] = (try? await playbackState(of: coordinator, at: endpoint)) ?? state
        publishAssembled()
        return .applied
    }

    private func skipNext(_ group: GroupID) async throws(SonosCommandError) -> CommandOutcome {
        let coordinator = group.coordinator
        try await refreshBook(anchor: coordinator)
        let endpoint = try endpoint(for: coordinator)
        let state = try await playbackState(of: coordinator, at: endpoint)
        guard let position = queuePosition(state) else { throw .unsupportedForCurrentSource }
        _ = try await client.call(TransportService.seek(toTrack: position + 1), on: coordinator, at: endpoint)
        playback[coordinator] = (try? await playbackState(of: coordinator, at: endpoint)) ?? state
        publishAssembled()
        return .applied
    }

    private func skipPrevious(_ group: GroupID) async throws(SonosCommandError) -> CommandOutcome {
        let coordinator = group.coordinator
        try await refreshBook(anchor: coordinator)
        let endpoint = try endpoint(for: coordinator)
        let state = try await playbackState(of: coordinator, at: endpoint)
        guard let position = queuePosition(state) else { throw .unsupportedForCurrentSource }
        let elapsed = elapsedTime(state) ?? .zero
        let request = elapsed > .seconds(3) || position <= 1
            ? TransportService.seek(to: .zero)
            : TransportService.seek(toTrack: position - 1)
        _ = try await client.call(request, on: coordinator, at: endpoint)
        playback[coordinator] = (try? await playbackState(of: coordinator, at: endpoint)) ?? state
        publishAssembled()
        return .applied
    }

    private func enqueueSpotify(
        _ uri: SpotifyURI, metadata: SpotifyTrackMetadata, group: GroupID, startingAt: Duration?
    ) async throws(SonosCommandError) -> CommandOutcome {
        let coordinator = group.coordinator
        try await refreshBook(anchor: coordinator)
        let endpoint = try endpoint(for: coordinator)
        let state = try await playbackState(of: coordinator, at: endpoint)
        playback[coordinator] = state
        if case .playing(.track(let track), _, _) = state, track.spotifyURI == uri {
            publishAssembled()
            return .alreadySatisfied
        }
        if case .paused(.track(let track), _) = state, track.spotifyURI == uri {
            _ = try await client.call(TransportService.transport(.play), on: coordinator, at: endpoint)
            if let startingAt {
                _ = try await client.call(TransportService.seek(to: startingAt), on: coordinator, at: endpoint)
            }
            playback[coordinator] = (try? await playbackState(of: coordinator, at: endpoint)) ?? state
            publishAssembled()
            return .applied
        }
        let account = try await spotifyAccount(for: coordinator, at: endpoint)
        let media = try await client.call(TransportService.getMediaInfo, on: coordinator, at: endpoint)
        let currentURI = media.value("CurrentURI")
        let queuePrefix = "x-rincon-queue:\(coordinator.rawValue)"
        let alreadyQueued = currentURI.hasPrefix(queuePrefix)
        if !alreadyQueued {
            // AddURIToQueue is rejected unless AVTransport is already this coordinator's queue.
            _ = try await client.call(SOAPRequest(
                service: .avTransport, action: "SetAVTransportURI",
                arguments: [
                    ("InstanceID", "0"),
                    ("CurrentURI", "\(queuePrefix)#0"),
                    ("CurrentURIMetaData", ""),
                ]), on: coordinator, at: endpoint)
        }
        let enqueued = SpotifyOnSonos.enqueueURI(for: uri, account: account)
        let didl = SpotifyOnSonos.didl(for: metadata, uri: uri, account: account)
        let position = alreadyQueued ? queuePosition(state) : nil
        var planned = SpotifyOnSonos.requests(
            uri: enqueued, didl: didl, currentQueuePosition: position, startingAt: startingAt)
        guard let add = planned.first else { return .alreadySatisfied }
        let response = try await client.call(add, on: coordinator, at: endpoint)
        planned.removeFirst()
        if let actual = Int(response.value("FirstTrackNumberEnqueued")), actual > 0 {
            for index in planned.indices where planned[index].action == "Seek"
                && planned[index].arguments.contains(where: { $0.0 == "Unit" && $0.1 == "TRACK_NR" }) {
                planned[index] = TransportService.seek(toTrack: actual)
                break
            }
        }
        for request in planned {
            _ = try await client.call(request, on: coordinator, at: endpoint)
        }
        playback[coordinator] = (try? await playbackState(of: coordinator, at: endpoint)) ?? state
        publishAssembled()
        return .applied
    }

    private func spotifyAccount(for coordinator: SpeakerUUID, at endpoint: URL) async throws(SonosCommandError) -> SpotifyOnSonos.Account {
        if let spotifyAccount { return spotifyAccount }
        let account = try await SpotifyOnSonos.discoverAccount(using: client, coordinator: coordinator, at: endpoint)
        spotifyAccount = account
        return account
    }

    private func refreshBook(anchor: SpeakerUUID) async throws(SonosCommandError) {
        guard let parsed = await fetchTopology() else { throw .speakerUnreachable(anchor) }
        addressBook.absorb(parsed)
        lastParsed = parsed
    }

    private func rereadMemberVolumes(of coordinator: SpeakerUUID) async {
        guard let parsed = lastParsed else { return }
        let members = parsed.members.filter { parsed.topology.group(of: $0.key)?.coordinator == coordinator }
        let reads = await withTaskGroup(of: (SpeakerUUID, DiscreteVolume)?.self) { group in
            for (id, member) in members {
                group.addTask {
                    guard let volume = try? await self.volume(of: id, at: member.endpoint) else { return nil }
                    return (id, volume)
                }
            }
            var found: [(SpeakerUUID, DiscreteVolume)] = []
            for await read in group {
                if let read { found.append(read) }
            }
            return found
        }
        for (id, volume) in reads { volumes[id] = volume }
    }

    private func readBackVolume(_ speaker: SpeakerUUID, at endpoint: URL, fallback: DiscreteVolume) async -> DiscreteVolume {
        if let volume = try? await volume(of: speaker, at: endpoint), volume == fallback { return volume }
        try? await Task.sleep(for: .milliseconds(200))
        return (try? await volume(of: speaker, at: endpoint)) ?? fallback
    }

    private func volume(of speaker: SpeakerUUID, at endpoint: URL) async throws(SonosCommandError) -> DiscreteVolume {
        TransportService.parseVolume(try await client.call(TransportService.getVolume, on: speaker, at: endpoint))
    }

    private func groupVolume(of speaker: SpeakerUUID, at endpoint: URL) async throws(SonosCommandError) -> DiscreteVolume {
        TransportService.parseVolume(try await client.call(TransportService.getGroupVolume, on: speaker, at: endpoint))
    }

    private func playbackState(of speaker: SpeakerUUID, at endpoint: URL) async throws(SonosCommandError) -> PlaybackState {
        let transport = try await client.call(TransportService.getTransportInfo, on: speaker, at: endpoint)
        let position = try await client.call(TransportService.getPositionInfo, on: speaker, at: endpoint)
        let media = try await client.call(TransportService.getMediaInfo, on: speaker, at: endpoint)
        return TransportService.parsePlayback(
            transportInfo: transport, positionInfo: position, mediaInfo: media,
            coordinatorEndpoint: endpoint, sampledAt: Date())
    }

    private func endpoint(for speaker: SpeakerUUID) throws(SonosCommandError) -> URL {
        guard let endpoint = addressBook.endpoint(for: speaker) else { throw .speakerUnreachable(speaker) }
        return endpoint
    }

    private func lane(for speaker: SpeakerUUID) -> CommandLane {
        if let lane = lanes[speaker] { return lane }
        let lane = CommandLane()
        lanes[speaker] = lane
        return lane
    }

    private func laneSpeaker(for command: SonosCommand) -> SpeakerUUID {
        switch command {
        case .setVolume(_, .speaker(let speaker)): speaker
        case .setVolume(_, .group(let group)): group.coordinator
        case .playPause(_, let group), .nextTrack(let group), .previousTrack(let group): group.coordinator
        case .enqueueAndPlaySpotify(_, _, let group, _): group.coordinator
        case .group(let member, _), .ungroup(let member): member
        case .applyPreset(let preset): preset.coordinatorUUID
        }
    }

    private func anchorSpeaker(_ target: TopologyTarget) -> SpeakerUUID {
        switch target {
        case .memberOf(_, let member), .standalone(let member): member
        case .exactGroup(let coordinator, _): coordinator
        }
    }

    private func transportMatches(_ state: PlaybackState, _ desired: PlayPause) -> Bool {
        switch (state, desired) {
        case (.playing, .play), (.paused, .pause), (.stopped, .pause): true
        default: false
        }
    }

    private func queuePosition(_ state: PlaybackState) -> Int? {
        guard case .track(let track) = state.nowPlaying else { return nil }
        return track.queuePosition
    }

    private func elapsedTime(_ state: PlaybackState) -> Duration? {
        switch state {
        case .stopped: nil
        case .paused(_, let elapsed), .playing(_, let elapsed, _): elapsed
        }
    }

    private func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

private enum TransportRead: Sendable {
    case volume(SpeakerUUID, DiscreteVolume)
    case groupVolume(SpeakerUUID, DiscreteVolume)
    case playback(SpeakerUUID, PlaybackState)
}

private actor CommandLane {
    private var tail: Task<Void, Never>?

    func run(
        _ body: @escaping @Sendable () async -> Result<CommandOutcome, SonosCommandError>
    ) async -> Result<CommandOutcome, SonosCommandError> {
        let previous = tail
        let task = Task { () -> Result<CommandOutcome, SonosCommandError> in
            await previous?.value
            return await body()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }
}

struct AddressBook: Sendable {
    private var endpoints: [SpeakerUUID: URL] = [:]
    private(set) var seeds: [URL]

    init(seedIPs: [String]) {
        seeds = seedIPs.compactMap { URL(string: "http://\($0):1400") }
    }

    func endpoint(for speaker: SpeakerUUID) -> URL? { endpoints[speaker] }

    mutating func absorb(_ parsed: TopologyService.Parsed) {
        for id in parsed.vanished where parsed.members[id] == nil { endpoints[id] = nil }
        for (id, member) in parsed.members { endpoints[id] = member.endpoint }
        var seen = Set<URL>()
        let live = parsed.members.values.map(\.endpoint).sorted { $0.absoluteString < $1.absoluteString }
        seeds = (live + seeds).filter { seen.insert($0).inserted }
    }
}
