import Foundation
import SconeDomain

public struct FileSlot<Content: Codable & Equatable & Sendable>: Sendable {
    public let name: String
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
    public var speakers: [Speaker]
    public var rf: RFPeerMatrix
}

public struct PresetsFile: Codable, Equatable, Sendable {
    public var version = 1
    public var presets: [PresetPill]
}

public struct FloorplanPositionsFile: Codable, Equatable, Sendable {
    public var version = 1
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

    public var seedIPs: [String] { cache?.speakers.map(\.reachability.ip) ?? [] }
}

public struct SconeFiles: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func load<C>(_ slot: FileSlot<C>) -> LoadResult<C> {
        let url = fileURL(slot.name)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            return .loaded(try JSONDecoder().decode(C.self, from: data))
        } catch {
            return quarantine(slot, at: url)
        }
    }

    public func save<C>(_ content: C, to slot: FileSlot<C>) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(content)
        try data.write(to: fileURL(slot.name), options: .atomic)
    }

    public func loadAll() -> LoadedFiles {
        let cache = load(FileSlot.cachedSpeakers)
        let presets = load(FileSlot.presets)
        let positions = load(FileSlot.floorplanPositions)
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
        return LoadedFiles(
            cache: take(cache),
            presets: take(presets),
            positions: take(positions),
            quarantined: quarantined)
    }

    private func fileURL(_ name: String) -> URL { directory.appending(path: name) }

    private func quarantine<C>(_ slot: FileSlot<C>, at url: URL) -> LoadResult<C> {
        if slot.isDisposable {
            try? FileManager.default.removeItem(at: url)
            return .missing
        }
        let fileName = "\(slot.name).corrupt-\(Int(Date().timeIntervalSince1970))"
        let destination = fileURL(fileName)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return .quarantined(fileName: fileName)
        } catch {
            return .quarantined(fileName: slot.name)
        }
    }
}
