import DylCore
import Foundation
import SconeDomain

public actor SonosHousehold {
    public struct Configuration: Sendable {
        public var sweepInterval: Duration = .seconds(2)
        public var telemetryInterval: Duration = .seconds(60)
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
    private var modelsByHost: [String: DeviceFacts] = [:]
    private var radios: [SpeakerUUID: TelemetryService.RadioStatus] = [:]
    private var batteries: [SpeakerUUID: BatteryTelemetry] = [:]
    private var volumes: [SpeakerUUID: DiscreteVolume] = [:]
    private var groupVolumes: [SpeakerUUID: DiscreteVolume] = [:]
    private var playback: [SpeakerUUID: PlaybackState] = [:]
    private var lastActiveGroupIDs: Set<GroupID> = []
    private var lastParsed: TopologyService.Parsed?
    private var cachedSpeakers: [SpeakerUUID: Speaker] = [:]
    private var missingSince: [SpeakerUUID: Date] = [:]
    private var lastTelemetry: Date?
    private var lastTelemetryMemberCount: Int = 0
    private var unreachableSince: Date?
    private var householdPresets: [PresetPill]?
    private var householdNetworkName: String?
    private var cachedQueueKey: [SpeakerUUID: String] = [:]
    private var cachedQueueAt: [SpeakerUUID: Date] = [:]
    private var cachedQueueItems: [SpeakerUUID: [QueueItem]] = [:]

    private static let presetsVariableName = "Sconeos_Presets_v1"
    private static let systemNameVariableName = "Sconeos_SystemName"

    public init(seedIPs: [String], configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.addressBook = AddressBook(seedIPs: seedIPs)
        NetworkDebugLog.write("SonosHousehold.init seedIPs=\(seedIPs) executable=\(Bundle.main.executablePath ?? "nil")")
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
        } else if case .savePresets(let presets) = command {
            result = await topologyLane.run { await self.savePresetsOutcome(presets) }
        } else if case .setSystemName(let name) = command {
            result = await topologyLane.run { await self.setSystemNameOutcome(name) }
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
            NetworkDebugLog.write("sweepOnce gen=\(generation): fetchTopology returned nil (all seeds + discovery unreachable)")
            noteUnreachable()
            return
        }
        guard generation == sweepGeneration else { return }
        if unreachableSince != nil || lastParsed == nil {
            let rooms = parsed.members.values.map { "\($0.roomName)@\($0.endpoint.host ?? "?")" }.sorted().joined(separator: ", ")
            NetworkDebugLog.write("sweepOnce gen=\(generation): topology ONLINE with \(parsed.members.count) speakers: [\(rooms)]")
        }
        unreachableSince = nil
        addressBook.absorb(parsed)
        lastParsed = parsed
        await refreshTransport(parsed)
        let due = telemetryDue || parsed.members.count != lastTelemetryMemberCount
        await refreshDescriptions(parsed, force: due)
        if due {
            await refreshRadiosAndBatteries(parsed)
            lastTelemetry = Date()
            lastTelemetryMemberCount = parsed.members.count
        }
        if due || householdPresets == nil || householdNetworkName == nil {
            await refreshHouseholdProperties(parsed)
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
            for (id, member) in parsed.members {
                if models[id] == nil {
                    group.addTask { await self.readDescription(id, endpoint: member.endpoint) }
                }
                for satellite in member.satellites {
                    if let satEndpoint = satellite.endpoint, models[satellite.id] == nil {
                        group.addTask { await self.readDescription(satellite.id, endpoint: satEndpoint) }
                    }
                }
            }
        }
    }

    private func refreshRadiosAndBatteries(_ parsed: TopologyService.Parsed) async {
        let resolve = macResolver(for: parsed)
        await withTaskGroup(of: Void.self) { group in
            for (id, member) in parsed.members {
                group.addTask { await self.readRadio(id, endpoint: member.endpoint, resolve: resolve) }
                if let modelNumber = self.models[id]?.modelNumber,
                   SpeakerModel.isBatteryCapable(modelNumber: modelNumber) {
                    group.addTask { await self.readBattery(id, endpoint: member.endpoint) }
                }
            }
        }
    }

    private func readDescription(_ id: SpeakerUUID, endpoint: URL) async {
        let host = endpoint.host ?? endpoint.absoluteString
        if let cached = models[id] ?? modelsByHost[host] {
            models[id] = cached
            modelsByHost[host] = cached
            return
        }
        guard let data = try? await client.get("/xml/device_description.xml", at: endpoint),
              let facts = try? TelemetryService.parseDeviceDescription(data) else { return }
        let deviceFacts = DeviceFacts(modelNumber: facts.modelNumber, displayName: facts.displayName)
        models[id] = deviceFacts
        modelsByHost[host] = deviceFacts
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
                let satFacts = models[satellite.id]
                return BondedSatellite(
                    id: satellite.id,
                    parentID: id,
                    role: satellite.role,
                    modelNumber: satFacts?.modelNumber,
                    displayName: satFacts?.displayName,
                    isOnline: satellite.endpoint != nil,
                    linkQuality: radio?.satelliteLinkQuality[satellite.id]
                )
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
                volume: volumes[id] ?? .v0,
                bondedSatellites: satellites)
            speakers[id] = speaker
            cachedSpeakers[id] = speaker
        }
        let limit = seconds(configuration.offlineAfter)
        for (id, since) in missingSince where now.timeIntervalSince(since) < limit {
            if speakers[id] == nil, let cached = cachedSpeakers[id] { speakers[id] = cached }
        }
        for (id, zoneName) in parsed.vanishedNames where speakers[id] == nil {
            let facts = models[id]
            speakers[id] = Speaker(
                id: id,
                roomName: zoneName,
                model: TelemetryService.model(
                    number: facts?.modelNumber ?? "",
                    displayName: facts?.displayName ?? zoneName,
                    satellites: [],
                    battery: batteries[id]),
                reachability: .offline(lastKnownIP: "", lastSeenAt: now),
                volume: volumes[id] ?? .v0,
                bondedSatellites: [])
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
        let snapshot = HouseholdSnapshot(
            observedAt: now,
            speakers: speakers,
            topology: parsed.topology,
            groupStatus: status,
            rf: matrix,
            presets: householdPresets,
            networkName: householdNetworkName,
            preferredGroupIDs: lastActiveGroupIDs)
        var nextActive: Set<GroupID> = []
        for group in snapshot.groups {
            if case .stopped = group.playback { continue }
            nextActive.insert(group.id)
            playback[group.id.coordinator] = group.playback
        }
        for coordinator in coordinators {
            if let group = parsed.topology.group(of: coordinator), !nextActive.contains(group) {
                playback[coordinator] = .stopped
            }
        }
        lastActiveGroupIDs = nextActive
        return snapshot
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
        lhs.isSemanticallyEquivalent(to: rhs)
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
            var stepFailures = skipped
            var lastStepError: SonosCommandError?
            for step in steps {
                if case .join(let member, _) = step {
                    playback[member] = .stopped
                }
                let action = TopologyService.request(for: step)
                do {
                    _ = try await callWithEndpointRefresh(action.request, on: action.target)
                } catch {
                    lastStepError = error
                    stepFailures.insert(action.target)
                    continue
                }
                if case .delegateCoordination(let oldCoord, let newCoord, false) = step {
                    if let existingPlayback = playback[oldCoord] {
                        playback[newCoord] = existingPlayback
                    }
                    playback[oldCoord] = .stopped
                }
            }
            if let parsed = try? await waitForTopology(target, ignoring: skipped) {
                addressBook.absorb(parsed)
                lastParsed = parsed
                await refreshTransport(parsed)
                publishAssembled()
                return skipped.isEmpty ? .applied : .partiallyApplied(unreachable: skipped)
            }
            if stepFailures != skipped,
               let parsed = try? await waitForTopology(target, ignoring: stepFailures) {
                addressBook.absorb(parsed)
                lastParsed = parsed
                await refreshTransport(parsed)
                publishAssembled()
                return .partiallyApplied(unreachable: stepFailures)
            }
            if let lastStepError { throw lastStepError }
            throw .notConverged(after: configuration.convergenceTimeout)
        }
    }

    private func waitForTopology(_ target: TopologyTarget, ignoring skipped: Set<SpeakerUUID>) async throws(SonosCommandError) -> TopologyService.Parsed {
        let deadline = ContinuousClock.now.advanced(by: configuration.convergenceTimeout)
        while true {
            if let parsed = await fetchTopology(), target.isSatisfied(by: parsed.topology, ignoring: skipped) {
                return parsed
            }
            if ContinuousClock.now >= deadline { throw .notConverged(after: configuration.convergenceTimeout) }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                throw .notConverged(after: configuration.convergenceTimeout)
            }
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
        case .seekToQueueTrack(let number, let group):
            return try await seekToQueueTrack(number, group: group)
        case .enqueueAndPlaySpotify(let uri, let metadata, let group, let startingAt, let contextURI, let upNext):
            return try await enqueueSpotify(
                uri,
                metadata: metadata,
                group: group,
                startingAt: startingAt,
                contextURI: contextURI,
                upNext: upNext
            )
        case .savePresets(let presets):
            return try await writePresetsToSonos(presets)
        case .setSystemName(let name):
            return try await writeSystemNameToSonos(name)
        }
    }

    private func savePresetsOutcome(_ presets: [PresetPill]) async -> Result<CommandOutcome, SonosCommandError> {
        do { return .success(try await writePresetsToSonos(presets)) } catch { return .failure(error) }
    }

    private func setSystemNameOutcome(_ name: String) async -> Result<CommandOutcome, SonosCommandError> {
        do { return .success(try await writeSystemNameToSonos(name)) } catch { return .failure(error) }
    }

    private func writeSystemNameToSonos(_ name: String) async throws(SonosCommandError) -> CommandOutcome {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .alreadySatisfied }
        householdNetworkName = trimmed
        publishAssembled()
        guard let targetEndpoint = lastParsed?.members.values.first?.endpoint ?? addressBook.seeds.first else {
            return .applied
        }
        let req = SOAPRequest(
            service: .systemProperties,
            action: "SetString",
            arguments: [
                ("VariableName", Self.systemNameVariableName),
                ("StringValue", trimmed),
            ]
        )
        _ = try? await client.call(req, at: targetEndpoint)
        return .applied
    }

    private func writePresetsToSonos(_ presets: [PresetPill]) async throws(SonosCommandError) -> CommandOutcome {
        householdPresets = presets
        publishAssembled()
        guard let targetEndpoint = lastParsed?.members.values.first?.endpoint ?? addressBook.seeds.first else {
            return .applied
        }
        guard let data = try? JSONEncoder().encode(presets),
              let jsonString = String(data: data, encoding: .utf8) else {
            return .applied
        }
        let req = SOAPRequest(
            service: .systemProperties,
            action: "SetString",
            arguments: [
                ("VariableName", Self.presetsVariableName),
                ("StringValue", jsonString),
            ]
        )
        _ = try await client.call(req, at: targetEndpoint)
        return .applied
    }

    private func refreshHouseholdProperties(_ parsed: TopologyService.Parsed) async {
        guard let endpoint = parsed.members.values.first?.endpoint else { return }
        let validSpeakerIDs = Set(parsed.members.keys)

        // 1. Query native Sonos Saved Groups (`areas`) via Muse WebSocket API on port 1443
        let museAreas = await SonosMuseClient.fetchAreas(at: endpoint, validSpeakers: validSpeakerIDs)

        // 2. Read any Sconeos custom presets stored in SystemProperties:1
        var storedCustomPresets: [PresetPill]?
        let getPresetsReq = SOAPRequest(
            service: .systemProperties,
            action: "GetString",
            arguments: [("VariableName", Self.presetsVariableName)]
        )
        if let node = try? await client.call(getPresetsReq, at: endpoint) {
            let raw = node.value("StringValue").trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = raw.data(using: .utf8),
               let decoded = JSONDecoder().decodeOrLog([PresetPill].self, from: data) {
                storedCustomPresets = decoded
            }
        }

        if let museAreas {
            var combined = museAreas
            var seenNames = Set(museAreas.map { $0.name.lowercased() })
            var seenIDs = Set(museAreas.map(\.id))
            if let storedCustomPresets {
                for custom in storedCustomPresets {
                    let lower = custom.name.lowercased()
                    if !seenNames.contains(lower),
                       !seenIDs.contains(custom.id) {
                        combined.append(custom)
                        seenNames.insert(lower)
                        seenIDs.insert(custom.id)
                    }
                }
            }
            householdPresets = combined
        } else if let storedCustomPresets {
            householdPresets = storedCustomPresets
        } else {
            householdPresets = []
        }

        // 3. Resolve Sonos system name from SystemProperties:1 if set (real data or nil)
        if householdNetworkName == nil {
            let getNameReq = SOAPRequest(
                service: .systemProperties,
                action: "GetString",
                arguments: [("VariableName", Self.systemNameVariableName)]
            )
            if let node = try? await client.call(getNameReq, at: endpoint) {
                let stored = node.value("StringValue").trimmingCharacters(in: .whitespacesAndNewlines)
                if !stored.isEmpty {
                    householdNetworkName = stored
                }
            }
        }
    }

    private func setSpeakerVolume(_ volume: DiscreteVolume, speaker: SpeakerUUID) async throws(SonosCommandError) -> CommandOutcome {
        if volumes[speaker] == volume, addressBook.endpoint(for: speaker) != nil {
            return .alreadySatisfied
        }
        let targetEndpoint: URL
        if let cached = addressBook.endpoint(for: speaker) {
            targetEndpoint = cached
        } else {
            try await refreshBook(anchor: speaker)
            targetEndpoint = try endpoint(for: speaker)
        }
        do {
            _ = try await client.call(TransportService.setVolume(volume), on: speaker, at: targetEndpoint)
        } catch {
            try await refreshBook(anchor: speaker)
            let refreshedEndpoint = try endpoint(for: speaker)
            _ = try await client.call(TransportService.setVolume(volume), on: speaker, at: refreshedEndpoint)
        }
        volumes[speaker] = volume
        publishAssembled()
        return .applied
    }

    private func setGroupVolume(_ volume: DiscreteVolume, group: GroupID) async throws(SonosCommandError) -> CommandOutcome {
        let coordinator = group.coordinator
        if groupVolumes[coordinator] == volume, addressBook.endpoint(for: coordinator) != nil {
            return .alreadySatisfied
        }
        let targetEndpoint: URL
        if let cached = addressBook.endpoint(for: coordinator) {
            targetEndpoint = cached
        } else {
            try await refreshBook(anchor: coordinator)
            targetEndpoint = try endpoint(for: coordinator)
        }
        do {
            _ = try await client.call(TransportService.setGroupVolume(volume), on: coordinator, at: targetEndpoint)
        } catch {
            try await refreshBook(anchor: coordinator)
            let refreshedEndpoint = try endpoint(for: coordinator)
            _ = try await client.call(TransportService.setGroupVolume(volume), on: coordinator, at: refreshedEndpoint)
        }
        groupVolumes[coordinator] = volume
        await rereadMemberVolumes(of: coordinator)
        publishAssembled()
        return .applied
    }

    private func resolvedEndpoint(for speaker: SpeakerUUID) async throws(SonosCommandError) -> URL {
        if let cached = addressBook.endpoint(for: speaker) {
            return cached
        }
        try await refreshBook(anchor: speaker)
        return try endpoint(for: speaker)
    }

    @discardableResult
    private func callWithEndpointRefresh(_ request: SOAPRequest, on speaker: SpeakerUUID) async throws(SonosCommandError) -> XMLNode {
        let targetEndpoint = try await resolvedEndpoint(for: speaker)
        do {
            return try await client.call(request, on: speaker, at: targetEndpoint)
        } catch .speakerUnreachable {
            try await refreshBook(anchor: speaker)
            let refreshedEndpoint = try endpoint(for: speaker)
            return try await client.call(request, on: speaker, at: refreshedEndpoint)
        }
    }

    private func setTransport(_ desired: PlayPause, group: GroupID) async throws(SonosCommandError) -> CommandOutcome {
        let coordinator = group.coordinator
        let targetEndpoint = try await resolvedEndpoint(for: coordinator)
        let priorState = (try? await playbackState(of: coordinator, at: targetEndpoint)) ?? playback[coordinator]
        if let priorState {
            playback[coordinator] = priorState
            if transportMatches(priorState, desired) {
                publishAssembled()
                return .alreadySatisfied
            }
        }
        do {
            _ = try await callWithEndpointRefresh(TransportService.transport(desired), on: coordinator)
        } catch .speakerUnreachable(let unreachableSpeaker) {
            if let currentEndpoint = addressBook.endpoint(for: coordinator),
               let postState = try? await playbackState(of: coordinator, at: currentEndpoint),
               transportMatches(postState, desired) {
                playback[coordinator] = postState
                publishAssembled()
                return .applied
            }
            throw .speakerUnreachable(unreachableSpeaker)
        }
        if let currentEndpoint = addressBook.endpoint(for: coordinator),
           let updatedState = try? await playbackState(of: coordinator, at: currentEndpoint) {
            playback[coordinator] = updatedState
        }
        publishAssembled()
        return .applied
    }

    private func skipNext(_ group: GroupID) async throws(SonosCommandError) -> CommandOutcome {
        let coordinator = group.coordinator
        let targetEndpoint = try await resolvedEndpoint(for: coordinator)
        let state = (try? await playbackState(of: coordinator, at: targetEndpoint)) ?? playback[coordinator] ?? .stopped
        if let position = queuePosition(state) {
            _ = try await callWithEndpointRefresh(TransportService.seek(toTrack: position + 1), on: coordinator)
        } else {
            _ = try await callWithEndpointRefresh(TransportService.next, on: coordinator)
        }
        if let currentEndpoint = addressBook.endpoint(for: coordinator) {
            playback[coordinator] = (try? await playbackState(of: coordinator, at: currentEndpoint)) ?? state
        }
        publishAssembled()
        return .applied
    }

    private func skipPrevious(_ group: GroupID) async throws(SonosCommandError) -> CommandOutcome {
        let coordinator = group.coordinator
        let targetEndpoint = try await resolvedEndpoint(for: coordinator)
        let state = (try? await playbackState(of: coordinator, at: targetEndpoint)) ?? playback[coordinator] ?? .stopped
        let elapsed = elapsedTime(state) ?? .zero
        if let position = queuePosition(state) {
            let request = elapsed > .seconds(3) || position <= 1
                ? TransportService.seek(to: .zero)
                : TransportService.seek(toTrack: position - 1)
            _ = try await callWithEndpointRefresh(request, on: coordinator)
        } else {
            let request = elapsed > .seconds(3)
                ? TransportService.seek(to: .zero)
                : TransportService.previous
            _ = try await callWithEndpointRefresh(request, on: coordinator)
        }
        if let currentEndpoint = addressBook.endpoint(for: coordinator) {
            playback[coordinator] = (try? await playbackState(of: coordinator, at: currentEndpoint)) ?? state
        }
        publishAssembled()
        return .applied
    }

    private func seekToQueueTrack(_ number: Int, group: GroupID) async throws(SonosCommandError) -> CommandOutcome {
        let coordinator = group.coordinator
        _ = try await callWithEndpointRefresh(TransportService.seek(toTrack: max(1, number)), on: coordinator)
        _ = try? await callWithEndpointRefresh(TransportService.transport(.play), on: coordinator)
        if let currentEndpoint = addressBook.endpoint(for: coordinator) {
            playback[coordinator] = (try? await playbackState(of: coordinator, at: currentEndpoint)) ?? .stopped
        }
        publishAssembled()
        return .applied
    }

    private func enqueueSpotify(
        _ uri: SpotifyURI,
        metadata: SpotifyTrackMetadata,
        group: GroupID,
        startingAt: Duration?,
        contextURI: SpotifyURI? = nil,
        upNext: [QueueItem] = []
    ) async throws(SonosCommandError) -> CommandOutcome {
        let coordinator = group.coordinator
        let endpoint = try await resolvedEndpoint(for: coordinator)
        let state = (try? await playbackState(of: coordinator, at: endpoint)) ?? playback[coordinator] ?? .stopped
        playback[coordinator] = state

        let media = try await callWithEndpointRefresh(TransportService.getMediaInfo, on: coordinator)
        let currentURI = media.value("CurrentURI")
        let queuePrefix = "x-rincon-queue:\(coordinator.rawValue)"
        let alreadyQueued = currentURI.hasPrefix(queuePrefix)

        if case .playing(.track(let track), _, _) = state, track.spotifyURI == uri {
            publishAssembled()
            return .alreadySatisfied
        }
        if alreadyQueued,
           case .paused(.track(let track), _) = state,
           track.spotifyURI == uri,
           !track.upNext.isEmpty {
            _ = try await callWithEndpointRefresh(TransportService.transport(.play), on: coordinator)
            if let startingAt, startingAt > .seconds(1) {
                _ = try? await client.call(TransportService.seek(to: startingAt), on: coordinator, at: endpoint)
            }
            playback[coordinator] = (try? await playbackState(of: coordinator, at: endpoint)) ?? state
            publishAssembled()
            return .applied
        }

        let account = try await spotifyAccount(for: coordinator, at: endpoint)
        if !alreadyQueued {
            _ = try? await client.call(SOAPRequest(
                service: .avTransport,
                action: "RemoveAllTracksFromQueue",
                arguments: [("InstanceID", "0")]
            ), on: coordinator, at: endpoint)
            // AddURIToQueue is rejected unless AVTransport is already this coordinator's queue.
            _ = try await callWithEndpointRefresh(SOAPRequest(
                service: .avTransport,
                action: "SetAVTransportURI",
                arguments: [
                    ("InstanceID", "0"),
                    ("CurrentURI", "\(queuePrefix)#0"),
                    ("CurrentURIMetaData", ""),
                ]), on: coordinator)
        }
        let enqueued = SpotifyOnSonos.enqueueURI(for: uri, account: account)
        let didl = SpotifyOnSonos.didl(for: metadata, uri: uri, account: account)
        let position = alreadyQueued ? queuePosition(state) : nil
        let targetPosition = (position ?? 0) + 1
        let addRequest = SOAPRequest(
            service: .avTransport,
            action: "AddURIToQueue",
            arguments: [
                ("InstanceID", "0"),
                ("EnqueuedURI", enqueued),
                ("EnqueuedURIMetaData", didl),
                ("DesiredFirstTrackNumberEnqueued", String(targetPosition)),
                ("EnqueueAsNext", "1"),
            ]
        )
        let response = try await callWithEndpointRefresh(addRequest, on: coordinator)
        let actualTrack = Int(response.value("FirstTrackNumberEnqueued")).flatMap { $0 > 0 ? $0 : nil } ?? targetPosition
        _ = try await callWithEndpointRefresh(TransportService.seek(toTrack: actualTrack), on: coordinator)
        _ = try await callWithEndpointRefresh(TransportService.transport(.play), on: coordinator)
        if let startingAt, startingAt > .seconds(1) {
            _ = try? await client.call(TransportService.seek(to: startingAt), on: coordinator, at: endpoint)
        }

        // Enqueue upcoming Spotify queue tracks behind the current track so playback continues seamlessly.
        let upcomingTracks = upNext.prefix(15).compactMap { item -> (SpotifyURI, SpotifyTrackMetadata)? in
            guard let itemURI = item.spotifyURI, itemURI != uri else { return nil }
            let meta = SpotifyTrackMetadata(
                title: item.title,
                artist: item.artist ?? "",
                album: item.album,
                artworkURL: item.artworkURL,
                duration: item.duration
            )
            return (itemURI, meta)
        }
        if !upcomingTracks.isEmpty {
            for (nextURI, nextMeta) in upcomingTracks {
                let nextEnqueued = SpotifyOnSonos.enqueueURI(for: nextURI, account: account)
                let nextDIDL = SpotifyOnSonos.didl(for: nextMeta, uri: nextURI, account: account)
                let appendReq = SOAPRequest(
                    service: .avTransport,
                    action: "AddURIToQueue",
                    arguments: [
                        ("InstanceID", "0"),
                        ("EnqueuedURI", nextEnqueued),
                        ("EnqueuedURIMetaData", nextDIDL),
                        ("DesiredFirstTrackNumberEnqueued", "0"),
                        ("EnqueueAsNext", "0"),
                    ]
                )
                _ = try? await client.call(appendReq, on: coordinator, at: endpoint)
            }
        } else if let contextURI, contextURI.kind == .playlist || contextURI.kind == .album {
            let containerURI = SpotifyOnSonos.enqueueURI(for: contextURI, account: account)
            let containerMeta = SpotifyTrackMetadata(
                title: metadata.album ?? metadata.title,
                artist: metadata.artist,
                album: metadata.album,
                artworkURL: metadata.artworkURL,
                duration: nil
            )
            let containerDIDL = SpotifyOnSonos.didl(for: containerMeta, uri: contextURI, account: account)
            let appendContainer = SOAPRequest(
                service: .avTransport,
                action: "AddURIToQueue",
                arguments: [
                    ("InstanceID", "0"),
                    ("EnqueuedURI", containerURI),
                    ("EnqueuedURIMetaData", containerDIDL),
                    ("DesiredFirstTrackNumberEnqueued", "0"),
                    ("EnqueueAsNext", "0"),
                ]
            )
            _ = try? await client.call(appendContainer, on: coordinator, at: endpoint)
        }

        cachedQueueKey[coordinator] = nil
        cachedQueueItems[coordinator] = nil
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
        async let transportCall = client.call(TransportService.getTransportInfo, on: speaker, at: endpoint)
        async let positionCall = client.call(TransportService.getPositionInfo, on: speaker, at: endpoint)
        async let mediaCall = client.call(TransportService.getMediaInfo, on: speaker, at: endpoint)
        let transport: XMLNode
        let position: XMLNode
        let media: XMLNode
        do {
            (transport, position, media) = try await (transportCall, positionCall, mediaCall)
        } catch let error as SonosCommandError {
            throw error
        } catch {
            throw .speakerUnreachable(speaker)
        }
        let currentURI = media.value("CurrentURI")
        let transportState = transport.value("CurrentTransportState")
        let isStopped = transportState != "PLAYING"
            && transportState != "TRANSITIONING"
            && transportState != "PAUSED_PLAYBACK"
        let trackNumber = Int(position.value("Track")) ?? 0
        var queueItems: [QueueItem] = []
        if !isStopped, currentURI.hasPrefix("x-rincon-queue:") {
            let now = Date()
            let browseKey = "\(currentURI)|\(trackNumber)"
            let ttl: TimeInterval = (transportState == "PAUSED_PLAYBACK") ? 120 : 30
            if cachedQueueKey[speaker] == browseKey,
               let lastAt = cachedQueueAt[speaker],
               now.timeIntervalSince(lastAt) < ttl,
               let existing = cachedQueueItems[speaker] {
                queueItems = existing
            } else {
                let startIdx = max(0, trackNumber)
                if let qNode = try? await client.call(TransportService.browseQueue(startingAt: startIdx, count: 25), on: speaker, at: endpoint) {
                    queueItems = TransportService.parseQueueBrowseResponse(qNode, startingIndex: startIdx, coordinatorEndpoint: endpoint)
                }
                if queueItems.isEmpty,
                   let cdNode = try? await client.call(TransportService.browseContentDirectoryQueue(startingAt: startIdx, count: 25), on: speaker, at: endpoint) {
                    queueItems = TransportService.parseQueueBrowseResponse(cdNode, startingIndex: startIdx, coordinatorEndpoint: endpoint)
                }
                cachedQueueKey[speaker] = browseKey
                cachedQueueAt[speaker] = now
                cachedQueueItems[speaker] = queueItems
            }
        } else if isStopped || !currentURI.hasPrefix("x-rincon-queue:") {
            cachedQueueKey[speaker] = nil
            cachedQueueItems[speaker] = nil
        }
        let parsed = TransportService.parsePlayback(
            transportInfo: transport,
            positionInfo: position,
            mediaInfo: media,
            queueItems: queueItems,
            coordinatorEndpoint: endpoint,
            sampledAt: Date()
        )
        return parsed
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
        case .playPause(_, let group), .nextTrack(let group), .previousTrack(let group), .seekToQueueTrack(_, let group): group.coordinator
        case .enqueueAndPlaySpotify(_, _, let group, _, _, _): group.coordinator
        case .group(let member, _), .ungroup(let member): member
        case .applyPreset(let preset): preset.coordinatorUUID
        case .savePresets(let presets): presets.first?.coordinatorUUID ?? lastParsed?.members.keys.first ?? SpeakerUUID(rawValue: "RINCON_00000000000001400")!
        case .setSystemName: lastParsed?.members.keys.first ?? SpeakerUUID(rawValue: "RINCON_00000000000001400")!
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

private final class SonosLocalTLSDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

package enum SonosMuseClient {
    private static let apiKey = "123e4567-e89b-12d3-a456-426655440000"
    private static let subprotocol = "v1.api.smartspeaker.audio"

    private struct PlayerInfoPayload: Decodable, Sendable {
        let householdId: String?
    }

    private struct CommandHeader: Encodable, Sendable {
        let namespace: String
        let command: String
        let householdId: String
        let cmdId: String
    }

    private struct EmptyObject: Codable, Sendable {}

    private struct OutboundCommandEnvelope: Encodable, Sendable {
        let header: CommandHeader

        func encode(to encoder: any Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(header)
            try container.encode(EmptyObject())
        }
    }

    private struct AreaPayload: Decodable, Sendable {
        let id: String?
        let name: String?
        let isReadOnly: Bool?
        let playerIds: [String]?
    }

    private struct AreasBodyPayload: Decodable, Sendable {
        let areas: [AreaPayload]?
    }

    private struct AreasResponseEnvelope: Decodable, Sendable {
        let body: AreasBodyPayload

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            _ = try container.decode(EmptyObject.self)
            self.body = try container.decode(AreasBodyPayload.self)
        }
    }

    package static func parsePlayerHouseholdID(_ data: Data) -> String? {
        guard let info = JSONDecoder().decodeOrLog(PlayerInfoPayload.self, from: data),
              let householdId = info.householdId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !householdId.isEmpty else {
            return nil
        }
        return householdId
    }

    package static func encodeGetAreasCommand(householdId: String) -> String? {
        let envelope = OutboundCommandEnvelope(
            header: CommandHeader(
                namespace: "areas",
                command: "getAreas",
                householdId: householdId,
                cmdId: "1"
            )
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func fetchAreas(at endpoint: URL, validSpeakers: Set<SpeakerUUID>) async -> [PresetPill]? {
        guard let host = endpoint.host,
              let infoURL = URL(string: "https://\(host):1443/api/v1/players/local/info"),
              let wsURL = URL(string: "wss://\(host):1443/websocket/api") else {
            return nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config, delegate: SonosLocalTLSDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var infoRequest = URLRequest(url: infoURL, timeoutInterval: 4)
        infoRequest.setValue(apiKey, forHTTPHeaderField: "X-Sonos-Api-Key")
        guard let (infoData, _) = try? await session.data(for: infoRequest),
              let householdId = parsePlayerHouseholdID(infoData),
              let payload = encodeGetAreasCommand(householdId: householdId) else {
            return nil
        }

        var wsRequest = URLRequest(url: wsURL, timeoutInterval: 4)
        wsRequest.setValue(apiKey, forHTTPHeaderField: "X-Sonos-Api-Key")
        wsRequest.setValue(subprotocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")

        let ws = session.webSocketTask(with: wsRequest)
        ws.resume()
        defer { ws.cancel(with: .normalClosure, reason: nil) }

        do {
            try await ws.send(.string(payload))
            let message = try await ws.receive()
            guard case .string(let text) = message else { return nil }
            return parseAreasMessage(text, validSpeakers: validSpeakers)
        } catch {
            return nil
        }
    }

    package static func parseAreasMessage(_ text: String, validSpeakers: Set<SpeakerUUID>) -> [PresetPill]? {
        guard let data = text.data(using: .utf8),
              let envelope = JSONDecoder().decodeOrLog(AreasResponseEnvelope.self, from: data),
              let areas = envelope.body.areas else {
            return nil
        }

        var pills: [PresetPill] = []
        for area in areas {
            if area.isReadOnly == true { continue }
            guard let name = area.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  let playerStrings = area.playerIds else {
                continue
            }
            let allIDs = playerStrings.compactMap(SpeakerUUID.init(rawValue:))
            let onlineMatched = allIDs.filter { validSpeakers.contains($0) }
            let effectiveIDs = onlineMatched.isEmpty ? allIDs : onlineMatched
            guard let coordinator = effectiveIDs.first else { continue }
            let members = Set(effectiveIDs.dropFirst())
            let presetID: PresetID = if let idStr = area.id, let uuid = UUID(uuidString: idStr) {
                PresetID(rawValue: uuid)
            } else {
                PresetID()
            }
            pills.append(
                PresetPill(
                    id: presetID,
                    name: name,
                    coordinatorUUID: coordinator,
                    memberUUIDs: members
                )
            )
        }
        return pills
    }
}
