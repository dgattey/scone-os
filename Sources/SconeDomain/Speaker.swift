import Foundation

/// A visible zone player: something a person can pick, group, and set the volume of.
/// Home-theater satellites are not `Speaker`s. They live inside `SpeakerModel.beamHt`, so no list
/// of speakers can contain one and no command can target one.
public struct Speaker: Identifiable, Hashable, Sendable, Codable {
    public let id: SpeakerUUID
    /// Sonos `ZoneName`, verbatim ("Dining Room Speaker"). Display trimming lives in `RoomNaming`.
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

/// Hardware family plus the telemetry only that family has. An Era 100 cannot carry a battery
/// reading, and only a soundbar can carry satellites.
public enum SpeakerModel: Hashable, Sendable, Codable {
    case era100
    case era300
    case symfoniskBookshelf
    case beamHt(satellites: [BondedSatellite])
    /// nil until the first `/status/batterystatus` read succeeds.
    case move(battery: BatteryTelemetry?)
    /// A model number the boundary's table does not know. Kept so a new speaker shows up as a
    /// generic room instead of vanishing.
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
    /// Soundbar-side `RX Stats RSSI AVG` from `ath_rincon/status`, 0...100 scale. nil when unheard.
    public let linkQuality: Int?

    public init(id: SpeakerUUID, role: SatelliteRole, linkQuality: Int?) {
        self.id = id
        self.role = role
        self.linkQuality = linkQuality
    }
}

/// Parsed from `HTSatChanMapSet`: `LR,LTR` is rear left, `RR,RTR` is rear right, `SW` is the sub.
public enum SatelliteRole: String, Hashable, Sendable, Codable, CaseIterable {
    case rearLeft, rearRight, subwoofer
}

public struct BatteryTelemetry: Hashable, Sendable, Codable {
    /// Clamped to 0...100 at parse.
    public let levelPercent: Int
    /// True for any `PowerSource` other than `BATTERY`, e.g. `SONOS_CHARGING_RING` or `USB_POWER`.
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
    /// Present in the latest topology sweep. `rssi` and `noiseFloor` are dBm. The boundary maps the
    /// `0 dBm` "not measured" value (Beam, SYMFONISK, and Move in the probe) to nil.
    case online(ip: String, rssi: Int?, noiseFloor: Int?)
    /// Known from `cached-speakers.json` or an earlier sweep, absent now. A speaker is never
    /// offline without having been online once, so the IP and timestamp are not optional.
    case offline(lastKnownIP: String, lastSeenAt: Date)

    public var isOnline: Bool {
        if case .online = self { true } else { false }
    }

    /// The current IP when online, otherwise the last one seen. Doubles as a discovery seed.
    public var ip: String {
        switch self {
        case .online(let ip, _, _): ip
        case .offline(let ip, _): ip
        }
    }
}
