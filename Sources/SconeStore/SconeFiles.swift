import DylCore
import Foundation
import SconeDomain

extension FileSlot where Content == CachedSpeakersFile {
    public static var cachedSpeakers: Self { Self(name: "cached-speakers.json", isDisposable: true) }
}

extension FileSlot where Content == FloorplanPositionsFile {
    public static var floorplanPositions: Self { Self(name: "floorplan-positions.json", isDisposable: false) }
}

public struct CachedSpeakersFile: Codable, Equatable, Sendable {
    public var speakers: [Speaker]
    public var rf: RFPeerMatrix
    public var networkName: String?

    public init(speakers: [Speaker], rf: RFPeerMatrix, networkName: String? = nil) {
        self.speakers = speakers
        self.rf = rf
        self.networkName = networkName
    }
}

public struct FloorplanPositionsFile: Codable, Equatable, Sendable {
    public var pins: [SpeakerUUID: RoomCoordinate]
}

public struct LoadedFiles: Sendable {
    public let cache: CachedSpeakersFile?
    public let positions: FloorplanPositionsFile?
    public let quarantined: [String]

    public init(
        cache: CachedSpeakersFile? = nil,
        positions: FloorplanPositionsFile? = nil,
        quarantined: [String] = []
    ) {
        self.cache = cache
        self.positions = positions
        self.quarantined = quarantined
    }

    public var seedIPs: [String] { cache?.speakers.map(\.reachability.ip) ?? [] }
}

public struct SconeFiles: Sendable {
    public static let folder = "Sconeos"
    public static let fileNames = ["cached-speakers.json", "floorplan-positions.json", "spotify-vault.enc"]

    private let store: CodableFileStore

    public init(directory: URL) { store = CodableFileStore(directory: directory) }

    public var directory: URL { store.directory }

    /// - Blocking: reads files.
    public func load<C>(_ slot: FileSlot<C>) -> LoadResult<C> { store.load(slot) }

    /// - Blocking: writes a file.
    public func save<C>(_ content: C, to slot: FileSlot<C>) throws { try store.save(content, to: slot) }

    public func saveAsync<C>(_ content: C, to slot: FileSlot<C>) async throws {
        try await store.saveAsync(content, to: slot)
    }

    /// - Blocking: reads every slot and deletes the retired presets file.
    public func loadAll() -> LoadedFiles {
        store.remove("presets.json")
        var quarantined: [String] = []
        func take<C>(_ result: LoadResult<C>) -> C? {
            switch result {
            case .missing:
                return nil
            case .loaded(let content):
                return content
            case .quarantined(let fileName):
                quarantined.append(fileName)
                return nil
            }
        }
        let cache = take(load(FileSlot.cachedSpeakers))
        let positions = take(load(FileSlot.floorplanPositions))
        return LoadedFiles(cache: cache, positions: positions, quarantined: quarantined)
    }
}
