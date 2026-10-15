import Foundation

public struct Speaker: Identifiable, Hashable, Sendable, Codable {
    public let id: SpeakerUUID
    public let roomName: String
    public let model: SpeakerModel
    public let reachability: ReachabilityState
    public let volume: DiscreteVolume
    public let bondedSatellites: [BondedSatellite]

    public init(
        id: SpeakerUUID,
        roomName: String,
        model: SpeakerModel,
        reachability: ReachabilityState,
        volume: DiscreteVolume,
        bondedSatellites: [BondedSatellite] = []
    ) {
        self.id = id
        self.roomName = roomName
        self.model = model
        self.reachability = reachability
        self.volume = volume
        self.bondedSatellites = bondedSatellites
    }

    public func with(volume: DiscreteVolume) -> Speaker {
        Speaker(
            id: id,
            roomName: roomName,
            model: model,
            reachability: reachability,
            volume: volume,
            bondedSatellites: bondedSatellites
        )
    }

    public func with(reachability: ReachabilityState) -> Speaker {
        Speaker(
            id: id,
            roomName: roomName,
            model: model,
            reachability: reachability,
            volume: volume,
            bondedSatellites: bondedSatellites
        )
    }

    public func isSemanticallyEquivalent(to other: Speaker) -> Bool {
        id == other.id
            && roomName == other.roomName
            && model.isSemanticallyEquivalent(to: other.model)
            && reachability == other.reachability
            && volume == other.volume
            && bondedSatellites == other.bondedSatellites
    }
}

public enum SpeakerModel: Hashable, Sendable, Codable {
    // Soundbars
    case arc
    case beam
    case ray
    case playbar
    case playbase

    // Smart & Room Speakers
    case era100
    case era300
    case one
    case five
    case play1
    case play3

    // Portables (Battery-capable)
    case move(battery: BatteryTelemetry? = nil)
    case roam(battery: BatteryTelemetry? = nil)

    // Subwoofers
    case sub
    case subMini

    // IKEA SYMFONISK
    case symfoniskBookshelf
    case symfoniskLamp
    case symfoniskFrame

    // Components / Amps
    case amp
    case port

    // Fallback
    case unrecognized(modelNumber: String, displayName: String)

    public var battery: BatteryTelemetry? {
        switch self {
        case .move(let battery), .roam(let battery):
            return battery
        default:
            return nil
        }
    }

    public func isSemanticallyEquivalent(to other: SpeakerModel) -> Bool {
        switch (self, other) {
        case (.move(let lhs), .move(let rhs)),
             (.roam(let lhs), .roam(let rhs)):
            switch (lhs, rhs) {
            case (nil, nil): return true
            case (let l?, let r?): return l.isSemanticallyEquivalent(to: r)
            default: return false
            }
        default:
            return self == other
        }
    }

    public static func isBatteryCapable(modelNumber: String) -> Bool {
        let code = modelNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch code {
        case "S17", "S44", "S27", "S35", "S43":
            return true
        default:
            return false
        }
    }

    public static func classify(
        modelName: String,
        modelNumber: String,
        satellites: [BondedSatellite] = [],
        battery: BatteryTelemetry? = nil
    ) -> SpeakerModel {
        let _ = satellites
        let code = modelNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let lowered = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch code {
        case "S19", "S45":
            return .arc
        case "S14", "S31":
            return .beam
        case "S36":
            return .ray
        case "S9":
            return .playbar
        case "S11":
            return .playbase
        case "S39":
            return .era100
        case "S41":
            return .era300
        case "S13", "S18", "S22", "S38":
            return .one
        case "S5", "S6":
            return .five
        case "S23":
            if lowered.contains("five") || lowered.contains("play:5") || lowered.contains("play 5") {
                return .five
            }
            return .port
        case "S1", "S12":
            return .play1
        case "S3":
            return .play3
        case "S17", "S44":
            return .move(battery: battery)
        case "S27", "S35", "S43":
            return .roam(battery: battery)
        case "S10", "S15", "S24", "S37", "S42", "SUB":
            return .sub
        case "S34":
            return .subMini
        case "S21", "S33":
            return .symfoniskBookshelf
        case "S20", "S29", "S40":
            return .symfoniskLamp
        case "S30":
            return .symfoniskFrame
        case "S16", "ZP100", "ZP120":
            return .amp
        case "ZP80", "ZP90":
            return .port
        default:
            break
        }

        if lowered.contains("arc") { return .arc }
        if lowered.contains("beam") { return .beam }
        if lowered.contains("ray") { return .ray }
        if lowered.contains("playbar") { return .playbar }
        if lowered.contains("playbase") { return .playbase }
        if lowered.contains("era 100") || lowered.contains("era100") { return .era100 }
        if lowered.contains("era 300") || lowered.contains("era300") { return .era300 }
        if lowered.contains("sub mini") { return .subMini }
        if lowered == "sub" || lowered.contains("sonos sub") || lowered.hasPrefix("sub ") || lowered.hasSuffix(" sub") {
            return .sub
        }
        if lowered.contains("move") { return .move(battery: battery) }
        if lowered.contains("roam") { return .roam(battery: battery) }
        if lowered.contains("symfonisk") || lowered.contains("bookshelf") || lowered.contains("picture frame") || lowered.contains("table lamp") || lowered.contains("floor lamp") {
            if lowered.contains("lamp") { return .symfoniskLamp }
            if lowered.contains("frame") { return .symfoniskFrame }
            return .symfoniskBookshelf
        }
        if lowered.contains("play:5") || lowered.contains("play 5") || lowered.contains("sonos five") || lowered == "five" {
            return .five
        }
        if lowered.contains("play:3") || lowered.contains("play 3") { return .play3 }
        if lowered.contains("play:1") || lowered.contains("play 1") { return .play1 }
        if lowered.contains("sonos one") || lowered.contains("one sl") || lowered == "one" { return .one }
        if lowered.contains("connect:amp") || lowered.contains("sonos amp") || lowered == "amp" { return .amp }
        if lowered.contains("sonos port") || lowered == "port" || lowered.contains("sonos connect") || lowered == "connect" {
            return .port
        }
        return .unrecognized(modelNumber: modelNumber, displayName: modelName)
    }

    public var displayName: String {
        switch self {
        case .arc: return "Sonos Arc"
        case .beam: return "Sonos Beam"
        case .ray: return "Sonos Ray"
        case .playbar: return "Sonos Playbar"
        case .playbase: return "Sonos Playbase"
        case .era100: return "Sonos Era 100"
        case .era300: return "Sonos Era 300"
        case .one: return "Sonos One"
        case .five: return "Sonos Five"
        case .play1: return "Sonos Play:1"
        case .play3: return "Sonos Play:3"
        case .move: return "Sonos Move"
        case .roam: return "Sonos Roam"
        case .sub: return "Sonos Sub"
        case .subMini: return "Sonos Sub Mini"
        case .symfoniskBookshelf: return "SYMFONISK Bookshelf"
        case .symfoniskLamp: return "SYMFONISK Lamp"
        case .symfoniskFrame: return "SYMFONISK Picture Frame"
        case .amp: return "Sonos Amp"
        case .port: return "Sonos Port"
        case .unrecognized(let code, let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            return code.isEmpty ? "Sonos Speaker" : "Sonos (\(code))"
        }
    }

    public var shortName: String {
        switch self {
        case .arc: return "Arc"
        case .beam: return "Beam"
        case .ray: return "Ray"
        case .playbar: return "Playbar"
        case .playbase: return "Playbase"
        case .era100: return "Era 100"
        case .era300: return "Era 300"
        case .one: return "One"
        case .five: return "Five"
        case .play1: return "Play:1"
        case .play3: return "Play:3"
        case .move: return "Move"
        case .roam: return "Roam"
        case .sub: return "Sub"
        case .subMini: return "Sub Mini"
        case .symfoniskBookshelf: return "SYMFONISK"
        case .symfoniskLamp: return "Lamp"
        case .symfoniskFrame: return "Frame"
        case .amp: return "Amp"
        case .port: return "Port"
        case .unrecognized(let code, let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            return code.isEmpty ? "Sonos" : code
        }
    }
}

public struct BondedSatellite: Identifiable, Hashable, Sendable, Codable {
    public let id: SpeakerUUID
    public let parentID: SpeakerUUID?
    public let role: SatelliteRole
    public let modelNumber: String?
    public let displayName: String?
    public let isOnline: Bool
    public let linkQuality: Int?

    public init(
        id: SpeakerUUID,
        parentID: SpeakerUUID? = nil,
        role: SatelliteRole,
        modelNumber: String? = nil,
        displayName: String? = nil,
        isOnline: Bool = true,
        linkQuality: Int?
    ) {
        self.id = id
        self.parentID = parentID
        self.role = role
        self.modelNumber = modelNumber
        self.displayName = displayName
        self.isOnline = isOnline
        self.linkQuality = linkQuality
    }

    public var speakerModel: SpeakerModel {
        let classified = SpeakerModel.classify(
            modelName: displayName ?? "",
            modelNumber: modelNumber ?? ""
        )
        if case .unrecognized = classified, role == .subwoofer {
            return .sub
        }
        return classified
    }

    public var modelLabel: String {
        if case .unrecognized(_, let name) = speakerModel,
           name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return role == .subwoofer ? "Sonos Sub" : "Sonos Surround"
        }
        return speakerModel.displayName
    }

    public var shortModelLabel: String {
        if case .unrecognized(_, let name) = speakerModel,
           name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return role == .subwoofer ? "Sub" : "Surround"
        }
        return speakerModel.shortName
    }
}

public enum SatelliteRole: String, Hashable, Sendable, Codable, CaseIterable {
    case rearLeft, rearRight, subwoofer, stereoRight

    public var label: String {
        switch self {
        case .rearLeft: "Left Surround"
        case .rearRight: "Right Surround"
        case .subwoofer: "Subwoofer"
        case .stereoRight: "Right Channel"
        }
    }

    public var shortBadge: String {
        switch self {
        case .rearLeft: "L"
        case .rearRight: "R"
        case .subwoofer: "SUB"
        case .stereoRight: "R"
        }
    }
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

    public func isSemanticallyEquivalent(to other: BatteryTelemetry) -> Bool {
        levelPercent == other.levelPercent
            && isOnCharger == other.isOnCharger
            && temperatureCelsius == other.temperatureCelsius
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
