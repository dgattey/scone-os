import Foundation
import SconeDomain

/// Three files, split by who writes them and how much a loss costs.
/// - `cached-speakers.json`: machine-written every sweep (throttled). Disposable.
/// - `presets.json`: written when the person saves, renames, or deletes a preset.
/// - `floorplan-positions.json`: written when the person drops a room.
/// A cache write can never clobber user data because they never share a file.
public struct FileSlot<Content: Codable & Equatable & Sendable>: Sendable {
    public let name: String
    /// A disposable file that fails to decode is deleted. A user file that fails to decode is
    /// renamed to `<name>.corrupt-<timestamp>` and the app starts with an alert, so a bad file is
    /// never overwritten before anyone has read it.
    public let isDisposable: Bool
}

extension FileSlot where Content == CachedSpeakersFile {
    public static var cachedSpeakers: Self { Self(name: "cached-speakers.json", isDisposable: true) }
}

extension FileSlot where Content == PresetsFile {
    public static var presets: Self { Self(name: "presets.json", isDisposable: false) }
}

extension FileSlot where Content == FloorplanPositionsFile {
    public static var floorplanPositions: Self { Self(name: "floorplan-positions.json", isDisposable: false) }
}

public struct CachedSpeakersFile: Codable, Equatable, Sendable {
    public var version = 1
    /// Last-known form: every reachability is `.offline`.
    public var speakers: [Speaker]
    public var rf: RFPeerMatrix
}

public struct PresetsFile: Codable, Equatable, Sendable {
    public var version = 1
    /// Order is the pill order.
    public var presets: [PresetPill]
}

public struct FloorplanPositionsFile: Codable, Equatable, Sendable {
    public var version = 1
    /// Only rooms the person dragged. Inferred positions are recomputed, never stored.
    public var pins: [SpeakerUUID: RoomCoordinate]
}

public enum LoadResult<Content: Sendable>: Sendable {
    case missing
    case loaded(Content)
    case quarantined(fileName: String)
}

public struct LoadedFiles: Sendable {
    public let cache: CachedSpeakersFile?
    public let presets: PresetsFile?
    public let positions: FloorplanPositionsFile?
    public let quarantined: [String]

    /// Last-known IPs, handed to `SonosHousehold` so a warm launch needs no multicast at all.
    public var seedIPs: [String] { cache?.speakers.map(\.reachability.ip) ?? [] }
}

/// Synchronous on purpose. Each file is a few KB, so reads at launch and atomic writes on the main
/// actor cost about a millisecond and need no writer queue to keep them ordered.
public struct SconeFiles: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func load<C>(_ slot: FileSlot<C>) -> LoadResult<C> {
        fatalError("not implemented")
    }

    /// `Data.write(to:options: .atomic)`: temp file, then rename.
    public func save<C>(_ content: C, to slot: FileSlot<C>) throws {
        fatalError("not implemented")
    }

    public func loadAll() -> LoadedFiles {
        fatalError("not implemented")
    }
}
