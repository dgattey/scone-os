import Foundation

public struct Speaker: Identifiable, Hashable, Sendable, Codable {
    public let id: SpeakerUUID
    public let roomName: String
    public let model: SpeakerModel
    public let reachability: ReachabilityState
    public let volume: DiscreteVolume

    public init(
        id: SpeakerUUID, roomName: String, model: SpeakerModel,
        reachability: ReachabilityState, volume: DiscreteVolume
    ) {
        self.id = id
        self.roomName = roomName
        self.model = model
        self.reachability = reachability
        self.volume = volume
    }

    public func with(volume: DiscreteVolume) -> Speaker {
        Speaker(id: id, roomName: roomName, model: model, reachability: reachability, volume: volume)
    }

    public func with(reachability: ReachabilityState) -> Speaker {
        Speaker(id: id, roomName: roomName, model: model, reachability: reachability, volume: volume)
    }
}

public enum SpeakerModel: Hashable, Sendable, Codable {
    case era100
    case era300
    case symfoniskBookshelf
    case beamHt(satellites: [BondedSatellite])
    case move(battery: BatteryTelemetry?)
    case unrecognized(modelNumber: String, displayName: String)

    public var battery: BatteryTelemetry? {
        if case .move(let battery) = self { battery } else { nil }
    }

    public var satellites: [BondedSatellite] {
        if case .beamHt(let satellites) = self { satellites } else { [] }
    }
}

public struct BondedSatellite: Identifiable, Hashable, Sendable, Codable {
    public let id: SpeakerUUID
    public let role: SatelliteRole
    public let linkQuality: Int?

    public init(id: SpeakerUUID, role: SatelliteRole, linkQuality: Int?) {
        self.id = id
        self.role = role
        self.linkQuality = linkQuality
    }
}

public enum SatelliteRole: String, Hashable, Sendable, Codable, CaseIterable {
    case rearLeft, rearRight, subwoofer
}

public struct BatteryTelemetry: Hashable, Sendable, Codable {
    public let levelPercent: Int
    public let isOnCharger: Bool
    public let temperatureCelsius: Int?
    public let sampledAt: Date

    public init(levelPercent: Int, isOnCharger: Bool, temperatureCelsius: Int?, sampledAt: Date) {
        self.levelPercent = levelPercent
        self.isOnCharger = isOnCharger
        self.temperatureCelsius = temperatureCelsius
        self.sampledAt = sampledAt
    }
}

public enum ReachabilityState: Hashable, Sendable, Codable {
    case online(ip: String, rssi: Int?, noiseFloor: Int?)
    case offline(lastKnownIP: String, lastSeenAt: Date)

    public var isOnline: Bool {
        if case .online = self { true } else { false }
    }

    public var ip: String {
        switch self {
        case .online(let ip, _, _): ip
        case .offline(let ip, _): ip
        }
    }
}
