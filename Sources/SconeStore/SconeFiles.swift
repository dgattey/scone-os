import Foundation
import SconeDomain

public struct FileSlot<Content: Codable & Equatable & Sendable>: Sendable {
    public let name: String
    public let isDisposable: Bool
}

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

public enum LoadResult<Content: Sendable>: Sendable {
    case missing
    case loaded(Content)
    case quarantined(fileName: String)
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
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func migrateLegacyDirectoryIfNeeded(from legacyDir: URL, to targetDir: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyDir.path) else { return }
        try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        for fileName in ["cached-speakers.json", "floorplan-positions.json", "spotify-vault.enc"] {
            let src = legacyDir.appending(path: fileName)
            let dst = targetDir.appending(path: fileName)
            guard fm.fileExists(atPath: src.path) else { continue }
            if !fm.fileExists(atPath: dst.path) {
                try? fm.copyItem(at: src, to: dst)
            } else if let srcAttrs = try? fm.attributesOfItem(atPath: src.path),
                      let dstAttrs = try? fm.attributesOfItem(atPath: dst.path),
                      let srcDate = srcAttrs[.modificationDate] as? Date,
                      let dstDate = dstAttrs[.modificationDate] as? Date,
                      srcDate > dstDate {
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: src, to: dst)
            }
        }
    }

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

    public nonisolated func saveAsync<C>(_ content: C, to slot: FileSlot<C>) async throws {
        try await SconeFilesWriter.shared.write(content, to: slot, in: self)
    }

    public func loadAll() -> LoadedFiles {
        try? FileManager.default.removeItem(at: fileURL("presets.json"))
        let cache = load(FileSlot.cachedSpeakers)
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

private actor SconeFilesWriter {
    static let shared = SconeFilesWriter()

    func write<C>(_ content: C, to slot: FileSlot<C>, in files: SconeFiles) throws {
        try files.save(content, to: slot)
    }
}
