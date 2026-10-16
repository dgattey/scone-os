import CryptoKit
import Foundation
import SconeDomain
import Security
#if os(macOS)
import IOKit
import SystemConfiguration
#endif

@_silgen_name("gethostuuid")
private func _scone_gethostuuid(_ uuid: UnsafeMutablePointer<UInt8>, _ wait: UnsafePointer<timespec>) -> Int32

enum PKCE {
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        }
        defer {
            for index in bytes.indices { bytes[index] = 0 }
        }
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}

enum SealedClientStore {
    // 256-bit XOR-masked public OAuth 2.0 PKCE client identifier.
    // PKCE uses no client_secret; XOR masking prevents plaintext string scraping in git or Mach-O binaries
    // while working zero-config on any new Mac or iOS device after git clone.
    private static let cipher: [UInt8] = [
        0x97, 0xBF, 0x3E, 0x68, 0x98, 0x4F, 0xE0, 0xB4,
        0x6F, 0x88, 0xF0, 0x79, 0xC5, 0x38, 0xE5, 0xF6,
        0xF0, 0xE2, 0x00, 0xCE, 0x47, 0x18, 0x68, 0x28,
        0x42, 0x61, 0x06, 0xDF, 0x27, 0x94, 0xB6, 0x26,
    ]
    private static let pad: [UInt8] = [
        0xF2, 0x87, 0x5A, 0x0B, 0xF9, 0x7D, 0xD4, 0xD1,
        0x56, 0xBE, 0x92, 0x40, 0xF1, 0x0A, 0xD2, 0xC0,
        0x92, 0x86, 0x37, 0xFA, 0x21, 0x29, 0x5D, 0x4B,
        0x72, 0x52, 0x37, 0xBD, 0x15, 0xA1, 0x83, 0x45,
    ]

    static func withEphemeralClientID<T>(override: String = "", _ body: (String) throws -> T) rethrows -> T {
        let trimmedOverride = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOverride.isEmpty {
            return try body(trimmedOverride)
        }

        let env = ProcessInfo.processInfo.environment
        for key in ["SPOTIFY_CLIENT_ID", "SCONEOS_SPOTIFY_CLIENT_ID"] {
            if let val = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty {
                return try body(val)
            }
        }

        var buffer = [UInt8](repeating: 0, count: cipher.count)
        for idx in cipher.indices {
            buffer[idx] = cipher[idx] ^ pad[idx]
        }
        defer {
            for idx in buffer.indices { buffer[idx] = 0 }
        }
        return try body(String(decoding: buffer, as: UTF8.self))
    }
}

public struct TokenVault: Sendable {
    private struct VaultRecord: Codable, Sendable {
        var refreshToken: String?
        var accessToken: String?
        var accessExpiry: Double?
        var displayName: String?
    }

    public struct Snapshot: Sendable {
        public let refreshToken: String?
        public let accessToken: (token: String, expiry: Date)?
        public let displayName: String?
    }

    public let service: String
    public let vaultFileURL: URL
    private let derivedKey: SymmetricKey

    private static let stableMachineIdentity: String = {
        let user = resolvedHostUserName()
        #if os(macOS)
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/")
        if entry != 0 {
            defer { IOObjectRelease(entry) }
            if let uuid = IORegistryEntryCreateCFProperty(
                entry,
                kIOPlatformUUIDKey as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? String, !uuid.isEmpty {
                return "\(uuid).\(user)"
            }
        }
        #endif
        var ts = timespec(tv_sec: 0, tv_nsec: 0)
        var uuidBytes = [UInt8](repeating: 0, count: 16)
        if _scone_gethostuuid(&uuidBytes, &ts) == 0 {
            let uuidString = NSUUID(uuidBytes: uuidBytes).uuidString
            if !uuidString.isEmpty {
                return "\(uuidString).\(user)"
            }
        }
        return "mac.\(user)"
    }()

    private static func resolvedHostUserName() -> String {
        #if targetEnvironment(simulator)
        if let hostHome = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"], !hostHome.isEmpty {
            let last = URL(fileURLWithPath: hostHome).lastPathComponent
            if !last.isEmpty {
                return last
            }
        }
        #endif
        return NSUserName()
    }

    private static func legacyHostCandidates() -> [String] {
        let user = resolvedHostUserName()
        var hosts: [String] = [
            ProcessInfo.processInfo.hostName,
            "localhost",
        ]
        #if os(macOS)
        var baseSlugs: [String] = []
        if let localHost = SCDynamicStoreCopyLocalHostName(nil) as String?, !localHost.isEmpty {
            hosts.append(localHost)
            let slug = localHost.lowercased()
            baseSlugs.append(slug)
            hosts.append(slug)
            hosts.append("\(slug).local")
        }
        if let localized = SCDynamicStoreCopyComputerName(nil, nil) as String?, !localized.isEmpty {
            hosts.append(localized)
            let slug = localized
                .lowercased()
                .replacingOccurrences(of: "’", with: "")
                .replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: " ", with: "-")
            if !baseSlugs.contains(slug) {
                baseSlugs.append(slug)
            }
            hosts.append(slug)
            hosts.append("\(slug).local")
        }
        if let store = SCDynamicStoreCreate(nil, "sconeos" as CFString, nil, nil),
           let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? NSDictionary,
           let domains = dns["SearchDomains"] as? [String] {
            for domain in domains where !domain.isEmpty {
                for slug in baseSlugs {
                    hosts.append("\(slug).\(domain)")
                    for index in 1...4 {
                        hosts.append("\(slug)-\(index).\(domain)")
                    }
                }
            }
        }
        #endif
        var ordered: [String] = []
        var seen = Set<String>()
        for h in hosts where !h.isEmpty {
            for variant in [h, h.lowercased()] {
                let combined = "\(variant).\(user)"
                if seen.insert(combined).inserted {
                    ordered.append(combined)
                }
            }
        }
        return ordered
    }

    public init(
        service: String = "Sconeos.Spotify",
        directory: URL = URL.applicationSupportDirectory.appending(path: "Sconeos")
    ) {
        self.service = service
        self.vaultFileURL = directory.appending(path: "spotify-vault.enc")
        #if targetEnvironment(simulator)
        if !FileManager.default.fileExists(atPath: self.vaultFileURL.path),
           let hostHome = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"],
           !hostHome.isEmpty {
            let hostVaults = [
                URL(fileURLWithPath: hostHome).appending(path: "Library/Application Support/Sconeos/spotify-vault.enc"),
                URL(fileURLWithPath: hostHome).appending(path: ".sconeos/spotify-vault.enc"),
            ]
            for hostVault in hostVaults where FileManager.default.fileExists(atPath: hostVault.path) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: hostVault, to: self.vaultFileURL)
                break
            }
        }
        #endif

        let primaryMaterial = Data("Sconeos.TokenVault.\(service).\(Self.stableMachineIdentity)".utf8)
        self.derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: primaryMaterial),
            salt: Data("Sconeos.AESGCM.Salt.v1".utf8),
            info: Data(service.utf8),
            outputByteCount: 32
        )
    }

    private func makeFallbackKeys() -> [SymmetricKey] {
        var fallbacks: [SymmetricKey] = []
        let candidateServices = Array(Set([service, "Sconeos.Spotify"]))
        for svc in candidateServices {
            for hostUser in Self.legacyHostCandidates() {
                let mat = Data("Sconeos.TokenVault.\(svc).\(hostUser)".utf8)
                fallbacks.append(
                    HKDF<SHA256>.deriveKey(
                        inputKeyMaterial: SymmetricKey(data: mat),
                        salt: Data("Sconeos.AESGCM.Salt.v1".utf8),
                        info: Data(svc.utf8),
                        outputByteCount: 32
                    )
                )
            }
        }
        return fallbacks
    }

    public func loadSnapshot() -> Snapshot {
        guard let record = readEncryptedFile() else {
            return Snapshot(refreshToken: nil, accessToken: nil, displayName: nil)
        }
        let access: (token: String, expiry: Date)?
        if let token = record.accessToken,
           let timestamp = record.accessExpiry,
           timestamp > 0 {
            access = (token, Date(timeIntervalSince1970: timestamp))
        } else {
            access = nil
        }
        return Snapshot(
            refreshToken: record.refreshToken,
            accessToken: access,
            displayName: record.displayName
        )
    }

    public func refreshToken() -> String? {
        readEncryptedFile()?.refreshToken
    }

    public func accessToken() -> (token: String, expiry: Date)? {
        loadSnapshot().accessToken
    }

    public func displayName() -> String? {
        readEncryptedFile()?.displayName
    }

    public func store(refreshToken: String) {
        var record = readEncryptedFile() ?? VaultRecord()
        record.refreshToken = refreshToken
        writeEncryptedFile(record)
    }

    public func store(accessToken: String, expiry: Date) {
        var record = readEncryptedFile() ?? VaultRecord()
        record.accessToken = accessToken
        record.accessExpiry = expiry.timeIntervalSince1970
        writeEncryptedFile(record)
    }

    public func store(
        accessToken: String,
        expiry: Date,
        refreshToken: String?,
        displayName: String? = nil
    ) {
        var record = readEncryptedFile() ?? VaultRecord()
        record.accessToken = accessToken
        record.accessExpiry = expiry.timeIntervalSince1970
        if let refreshToken {
            record.refreshToken = refreshToken
        }
        if let displayName, !displayName.isEmpty {
            record.displayName = displayName
        }
        writeEncryptedFile(record)
    }

    public func storeDisplayName(_ displayName: String) {
        guard !displayName.isEmpty else { return }
        var record = readEncryptedFile() ?? VaultRecord()
        record.displayName = displayName
        writeEncryptedFile(record)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: vaultFileURL)
    }

    public nonisolated func storeAsync(
        accessToken: String,
        expiry: Date,
        refreshToken: String?,
        displayName: String? = nil
    ) {
        let copy = self
        Task.detached(priority: .utility) {
            await TokenVaultWriter.shared.perform {
                copy.store(
                    accessToken: accessToken,
                    expiry: expiry,
                    refreshToken: refreshToken,
                    displayName: displayName
                )
            }
        }
    }

    public nonisolated func storeDisplayNameAsync(_ displayName: String) {
        let copy = self
        Task.detached(priority: .utility) {
            await TokenVaultWriter.shared.perform {
                copy.storeDisplayName(displayName)
            }
        }
    }

    public nonisolated func clearAsync() {
        let copy = self
        Task.detached(priority: .utility) {
            await TokenVaultWriter.shared.perform {
                copy.clear()
            }
        }
    }

    private func readEncryptedFile() -> VaultRecord? {
        guard let combined = try? Data(contentsOf: vaultFileURL),
              let sealedBox = try? AES.GCM.SealedBox(combined: combined) else {
            return nil
        }
        if let plaintext = try? AES.GCM.open(sealedBox, using: derivedKey),
           let record = try? JSONDecoder().decode(VaultRecord.self, from: plaintext) {
            return record
        }
        for fallbackKey in makeFallbackKeys() {
            if let plaintext = try? AES.GCM.open(sealedBox, using: fallbackKey),
               let record = try? JSONDecoder().decode(VaultRecord.self, from: plaintext) {
                writeEncryptedFile(record)
                return record
            }
        }
        return nil
    }

    private func writeEncryptedFile(_ record: VaultRecord) {
        let dir = vaultFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let plaintext = try? JSONEncoder().encode(record),
              let sealed = try? AES.GCM.seal(plaintext, using: derivedKey),
              let combined = sealed.combined else {
            return
        }
        try? combined.write(to: vaultFileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: vaultFileURL.path
        )
    }
}

private actor TokenVaultWriter {
    static let shared = TokenVaultWriter()

    func perform(_ operation: @Sendable () -> Void) {
        operation()
    }
}

package struct SpotifyTokenSet: Sendable, Equatable {
    package var accessToken: String
    package var refreshToken: String?
    package var expiresIn: Int
}

private struct SpotifyNamedResourcePayload: Decodable, Sendable {
    let name: String?
}

private struct SpotifyOEmbedPayload: Decodable, Sendable {
    let title: String?
}

private struct SpotifyUserProfilePayload: Decodable, Sendable {
    let id: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

private struct SpotifyTokenPayload: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct SpotifyDevicesPayload: Decodable, Sendable {
    struct Device: Decodable, Sendable {
        let id: String?
        let name: String?
        let type: String?
        let isActive: Bool?
        let isRestricted: Bool?

        enum CodingKeys: String, CodingKey {
            case id, name, type
            case isActive = "is_active"
            case isRestricted = "is_restricted"
        }
    }
    let devices: [Device]?
}

private struct SpotifyTransferPlaybackPayload: Encodable, Sendable {
    let deviceIDs: [String]
    let play: Bool

    enum CodingKeys: String, CodingKey {
        case deviceIDs = "device_ids"
        case play
    }
}

private struct SpotifyResumePlaybackPayload: Encodable, Sendable {
    struct Offset: Encodable, Sendable {
        let uri: String
    }
    var contextURI: String?
    var uris: [String]?
    var offset: Offset?
    var positionMs: Int?

    enum CodingKeys: String, CodingKey {
        case contextURI = "context_uri"
        case uris
        case offset
        case positionMs = "position_ms"
    }
}

private struct SpotifyTrackObjectPayload: Decodable, Sendable {
    struct Artist: Decodable, Sendable {
        let name: String?
    }
    struct Image: Decodable, Sendable {
        let url: String?
    }
    struct Album: Decodable, Sendable {
        let name: String?
        let images: [Image]?
    }
    let name: String?
    let uri: String?
    let type: String?
    let isLocal: Bool?
    let durationMs: Int?
    let artists: [Artist]?
    let album: Album?

    enum CodingKeys: String, CodingKey {
        case name, uri, type, artists, album
        case isLocal = "is_local"
        case durationMs = "duration_ms"
    }
}

private struct SpotifyQueuePayload: Decodable, Sendable {
    let queue: [SpotifyTrackObjectPayload]?
}

private struct SpotifyCurrentlyPlayingPayload: Decodable, Sendable {
    struct Context: Decodable, Sendable {
        let uri: String?
    }
    let item: SpotifyTrackObjectPayload?
    let context: Context?
    let device: SpotifyDevicesPayload.Device?
    let isPlaying: Bool?
    let progressMs: Int?

    enum CodingKeys: String, CodingKey {
        case item, context, device
        case isPlaying = "is_playing"
        case progressMs = "progress_ms"
    }
}

actor SpotifyAPIClient {
    static let shared = SpotifyAPIClient()

    private var contextTitleCache: [String: String?] = [:]
    private var inFlightContextTitleTasks: [String: Task<String?, Never>] = [:]
    private var cachedQueueTrackURI: SpotifyURI?
    private var cachedQueueItems: [QueueItem] = []
    private var cachedQueueFetchedAt: Date = .distantPast
    private var contextByURI: [SpotifyURI: SpotifyTrackContext] = [:]
    private var lastContext: SpotifyTrackContext?
    private var lastContextFetchedAt: Date = .distantPast
    private var rateLimitedUntil: Date = .distantPast
    private var consecutiveRateLimits: Int = 0
    private var inFlightCurrentlyPlaying: Task<SpotifyTrackContext?, any Error>?
    private var inFlightQueueTask: Task<[QueueItem], Never>?

    func currentlyPlaying(accessToken: String, minCacheAge: TimeInterval = 4.0) async throws(SpotifyBridgeError) -> SpotifyTrackContext? {
        let now = Date()
        if now < rateLimitedUntil {
            return lastContext
        }
        if now.timeIntervalSince(lastContextFetchedAt) < minCacheAge {
            return lastContext
        }
        if let existing = inFlightCurrentlyPlaying {
            do {
                return try await existing.value
            } catch let error as SpotifyBridgeError {
                throw error
            } catch {
                throw .network(error.localizedDescription)
            }
        }

        let task = Task<SpotifyTrackContext?, any Error> {
            try await self.performCurrentlyPlaying(accessToken: accessToken)
        }
        inFlightCurrentlyPlaying = task
        defer { inFlightCurrentlyPlaying = nil }

        do {
            let result = try await task.value
            lastContext = result
            if let result {
                contextByURI[result.uri] = result
            }
            lastContextFetchedAt = Date()
            return result
        } catch let error as SpotifyBridgeError {
            throw error
        } catch {
            throw .network(error.localizedDescription)
        }
    }

    func invalidateShortCache() {
        lastContextFetchedAt = .distantPast
        cachedQueueFetchedAt = .distantPast
    }

    private func performCurrentlyPlaying(accessToken: String) async throws(SpotifyBridgeError) -> SpotifyTrackContext? {
        let (data, status, retryAfter) = try await WebAPI.loadWithHeaders(
            url: WebAPI.playerURL,
            method: "GET",
            token: accessToken,
            body: nil
        )
        if status == 429 {
            setRateLimited(retryAfter: retryAfter)
            return lastContext
        }
        if status == 204 || status == 202 {
            consecutiveRateLimits = 0
            return nil
        }
        if status == 401 { throw .authorizationFailed("401") }
        guard (200..<300).contains(status) else { throw .network("currently-playing HTTP \(status)") }
        consecutiveRateLimits = 0
        let base = try WebAPI.parseCurrentlyPlaying(data)
        guard let base else { return nil }

        let now = Date()
        let needFreshQueue = (cachedQueueTrackURI != base.uri)
            || now.timeIntervalSince(cachedQueueFetchedAt) >= 30

        async let fetchedQueue: [QueueItem] = needFreshQueue
            ? fetchQueue(accessToken: accessToken)
            : cachedQueueItems
        async let fetchedContextTitle = resolveContextTitle(
            contextURI: base.contextURI,
            fallbackAlbum: base.metadata.album,
            accessToken: accessToken
        )

        let upNext = await fetchedQueue
        if needFreshQueue {
            cachedQueueTrackURI = base.uri
            cachedQueueItems = upNext
            cachedQueueFetchedAt = Date()
        }
        let contextTitle = await fetchedContextTitle
        return SpotifyTrackContext(
            uri: base.uri,
            metadata: base.metadata,
            position: base.position,
            contextTitle: contextTitle,
            contextURI: base.contextURI,
            deviceID: base.deviceID,
            deviceName: base.deviceName,
            deviceType: base.deviceType,
            isPlaying: base.isPlaying,
            upNext: upNext
        )
    }

    func fetchQueue(accessToken: String) async -> [QueueItem] {
        if Date() < rateLimitedUntil {
            return cachedQueueItems
        }
        if let existing = inFlightQueueTask {
            return await existing.value
        }
        let task = Task<[QueueItem], Never> {
            guard let (data, status, retryAfter) = try? await WebAPI.loadWithHeaders(
                url: WebAPI.queueURL,
                method: "GET",
                token: accessToken,
                body: nil
            ) else {
                return self.cachedQueueItems
            }
            if status == 429 {
                self.setRateLimited(retryAfter: retryAfter)
                return self.cachedQueueItems
            }
            guard (200..<300).contains(status) else {
                return self.cachedQueueItems
            }
            self.consecutiveRateLimits = 0
            return WebAPI.parseQueueData(data)
        }
        inFlightQueueTask = task
        defer { inFlightQueueTask = nil }
        return await task.value
    }

    private func setRateLimited(retryAfter: TimeInterval?) {
        consecutiveRateLimits = min(consecutiveRateLimits + 1, 6)
        let exponentialBackoff = TimeInterval(5 * (1 << (consecutiveRateLimits - 1)))
        let delay = max(retryAfter ?? 10, exponentialBackoff)
        rateLimitedUntil = Date().addingTimeInterval(min(delay, 300))
    }

    func resolveContextTitle(
        contextURI: String?,
        fallbackAlbum: String?,
        accessToken: String
    ) async -> String? {
        guard let contextURI, !contextURI.isEmpty else { return fallbackAlbum }
        if let cachedEntry = contextTitleCache[contextURI] {
            return cachedEntry ?? fallbackAlbum
        }
        if Date() < rateLimitedUntil { return fallbackAlbum }
        if let inFlight = inFlightContextTitleTasks[contextURI] {
            return (await inFlight.value) ?? fallbackAlbum
        }

        let parts = contextURI.split(separator: ":")
        guard parts.count >= 3 else {
            contextTitleCache[contextURI] = nil
            return fallbackAlbum
        }
        let kind = String(parts[parts.count - 2])
        let id = String(parts[parts.count - 1])

        if kind == "collection" {
            let liked = "Liked Songs"
            contextTitleCache[contextURI] = liked
            return liked
        }

        let task = Task<String?, Never> {
            let endpointPath: String? = switch kind {
            case "playlist": "https://api.spotify.com/v1/playlists/\(id)?fields=name"
            case "album": "https://api.spotify.com/v1/albums/\(id)"
            case "artist": "https://api.spotify.com/v1/artists/\(id)"
            default: nil
            }

            if let endpointPath,
               let url = URL(string: endpointPath),
               let (data, status, retryAfter) = try? await WebAPI.loadWithHeaders(url: url, method: "GET", token: accessToken, body: nil) {
                if status == 429 {
                    self.setRateLimited(retryAfter: retryAfter)
                    return nil
                }
                if (200..<300).contains(status),
                   let formatted = WebAPI.parseContextName(from: data, kind: kind) {
                    self.contextTitleCache[contextURI] = formatted
                    return formatted
                }
            }

            if (kind == "playlist" || kind == "album"),
               let oembedURL = URL(string: "https://open.spotify.com/oembed?url=https://open.spotify.com/\(kind)/\(id)"),
               let (data, status, retryAfter) = try? await WebAPI.loadWithHeaders(url: oembedURL, method: "GET", token: nil, body: nil) {
                if status == 429 {
                    self.setRateLimited(retryAfter: retryAfter)
                    return nil
                }
                if (200..<300).contains(status),
                   let formatted = WebAPI.parseOEmbedTitle(from: data, kind: kind) {
                    self.contextTitleCache[contextURI] = formatted
                    return formatted
                }
            }

            self.contextTitleCache[contextURI] = nil
            return nil
        }

        inFlightContextTitleTasks[contextURI] = task
        defer { inFlightContextTitleTasks[contextURI] = nil }
        return (await task.value) ?? fallbackAlbum
    }
}

package struct SpotifyConnectDevice: Sendable, Hashable {
    package var id: String?
    package var name: String
    package var type: String
    package var isActive: Bool
    package var isRestricted: Bool
}

public enum SpotifyDeviceMatcher {
    public static func normalizeRoomName(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        text.replace(/\s*\+\s*\d+.*$/, with: "")
        for suffix in [" speakers", " speaker", " sonos"] {
            if text.hasSuffix(suffix) {
                text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func matches(deviceName: String?, roomName: String) -> Bool {
        guard let deviceName, !deviceName.isEmpty else { return false }
        let normDevice = normalizeRoomName(deviceName)
        let normRoom = normalizeRoomName(roomName)
        guard !normDevice.isEmpty, !normRoom.isEmpty else { return false }
        if normDevice == normRoom { return true }
        let shortDevice = RoomNaming.shortName(normDevice, merged: false).lowercased()
        let shortRoom = RoomNaming.shortName(normRoom, merged: false).lowercased()
        return !shortDevice.isEmpty && shortDevice == shortRoom
    }

    public static func matchesAny(deviceName: String?, roomNames: [String]) -> Bool {
        roomNames.contains { matches(deviceName: deviceName, roomName: $0) }
    }
}

package enum WebAPI {
    static let playerURL = URL(string: "https://api.spotify.com/v1/me/player")!
    static let devicesURL = URL(string: "https://api.spotify.com/v1/me/player/devices")!
    static let queueURL = URL(string: "https://api.spotify.com/v1/me/player/queue")!
    private static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!

    static func currentlyPlaying(accessToken: String, minCacheAge: TimeInterval = 4.0) async throws(SpotifyBridgeError) -> SpotifyTrackContext? {
        try await SpotifyAPIClient.shared.currentlyPlaying(accessToken: accessToken, minCacheAge: minCacheAge)
    }

    static func availableDevices(accessToken: String) async -> [SpotifyConnectDevice] {
        guard let (data, status, _) = try? await loadWithHeaders(
            url: devicesURL,
            method: "GET",
            token: accessToken,
            body: nil
        ), (200..<300).contains(status) else {
            return []
        }
        return parseDevicesData(data)
    }

    package static func parseDevicesData(_ data: Data) -> [SpotifyConnectDevice] {
        guard let payload = try? JSONDecoder().decode(SpotifyDevicesPayload.self, from: data),
              let list = payload.devices else {
            return []
        }
        return list.compactMap { device -> SpotifyConnectDevice? in
            guard let name = device.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            let rawID = device.id?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpotifyConnectDevice(
                id: (rawID?.isEmpty == false) ? rawID : nil,
                name: name,
                type: device.type ?? "",
                isActive: device.isActive ?? false,
                isRestricted: device.isRestricted ?? false
            )
        }
    }

    package static func encodeTransferPayload(deviceID: String, play: Bool) -> Data? {
        guard !deviceID.isEmpty else { return nil }
        return try? JSONEncoder().encode(SpotifyTransferPlaybackPayload(deviceIDs: [deviceID], play: play))
    }

    static func transferPlayback(deviceID: String, play: Bool = true, accessToken: String) async -> Bool {
        guard let body = encodeTransferPayload(deviceID: deviceID, play: play) else {
            return false
        }
        var request = URLRequest(url: playerURL, timeoutInterval: 10)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return false
        }
        return (200..<300).contains(http.statusCode)
    }

    package static func parseQueueData(_ data: Data) -> [QueueItem] {
        guard let payload = try? JSONDecoder().decode(SpotifyQueuePayload.self, from: data),
              let queueArray = payload.queue else {
            return []
        }
        var seen = Set<String>()
        var items: [QueueItem] = []
        for (idx, item) in queueArray.prefix(20).enumerated() {
            guard let title = item.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { continue }
            let uriString = item.uri ?? ""
            let spotifyURI = SpotifyURI(uriString)
            let artists = item.artists?.compactMap(\.name) ?? []
            let artistText = artists.joined(separator: ", ")
            let albumName = item.album?.name
            let artwork = item.album?.images?.compactMap(\.url).first.flatMap(URL.init(string:))
            let duration = item.durationMs.map { Duration.milliseconds($0) }
            let dedupeKey = spotifyURI?.description ?? "\(title)|\(artistText)"
            if seen.insert(dedupeKey).inserted {
                items.append(
                    QueueItem(
                        id: "\(idx + 1):\(dedupeKey)",
                        title: title,
                        artist: artistText.isEmpty ? nil : artistText,
                        album: albumName,
                        artworkURL: artwork,
                        duration: duration,
                        queueNumber: nil,
                        spotifyURI: spotifyURI
                    )
                )
            }
        }
        return items
    }

    static func pause(accessToken: String) async {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/pause")!)
        request.httpMethod = "PUT"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
    }

    package static func encodeResumePayload(
        contextURI: String?,
        trackURI: SpotifyURI,
        position: Duration?
    ) -> Data? {
        var payload = SpotifyResumePlaybackPayload()
        if let contextURI,
           !contextURI.isEmpty,
           (contextURI.contains(":playlist:") || contextURI.contains(":album:")) {
            payload.contextURI = contextURI
            payload.offset = SpotifyResumePlaybackPayload.Offset(uri: trackURI.description)
        } else {
            payload.uris = [trackURI.description]
        }
        if let position {
            let ms = max(0, Int(position.components.seconds * 1000) + Int(position.components.attoseconds / 1_000_000_000_000_000))
            payload.positionMs = ms
        }
        return try? JSONEncoder().encode(payload)
    }

    static func resume(
        accessToken: String,
        deviceID: String? = nil,
        contextURI: String? = nil,
        trackURI: SpotifyURI? = nil,
        position: Duration? = nil
    ) async -> Bool {
        var components = URLComponents(string: "https://api.spotify.com/v1/me/player/play")!
        if let deviceID, !deviceID.isEmpty {
            components.queryItems = [URLQueryItem(name: "device_id", value: deviceID)]
        }
        guard let url = components.url else { return false }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        if let trackURI,
           let body = encodeResumePayload(contextURI: contextURI, trackURI: trackURI, position: position) {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return false
        }
        return (200..<300).contains(http.statusCode)
    }

    static func exchange(
        code: String,
        verifier: String,
        explicitClientID: String,
        redirectURI: URL
    ) async throws(SpotifyBridgeError) -> SpotifyTokenSet {
        var bodyData = SealedClientStore.withEphemeralClientID(override: explicitClientID) { activeID in
            formBody([
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirectURI.absoluteString,
                "client_id": activeID,
                "code_verifier": verifier,
            ])
        }
        defer {
            if !bodyData.isEmpty {
                bodyData.resetBytes(in: 0..<bodyData.count)
            }
        }
        return try await token(bodyData: bodyData)
    }

    static func refresh(
        explicitClientID: String,
        refreshToken: String
    ) async throws(SpotifyBridgeError) -> SpotifyTokenSet {
        var bodyData = SealedClientStore.withEphemeralClientID(override: explicitClientID) { activeID in
            formBody([
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": activeID,
            ])
        }
        defer {
            if !bodyData.isEmpty {
                bodyData.resetBytes(in: 0..<bodyData.count)
            }
        }
        return try await token(bodyData: bodyData)
    }

    package static func parseProfileName(from data: Data) -> String? {
        guard let payload = try? JSONDecoder().decode(SpotifyUserProfilePayload.self, from: data) else {
            return nil
        }
        let name = payload.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        return payload.id ?? "Spotify"
    }

    package static func parseContextName(from data: Data, kind: String) -> String? {
        guard let payload = try? JSONDecoder().decode(SpotifyNamedResourcePayload.self, from: data),
              let name = payload.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        return kind == "playlist" ? "Playlist \"\(name)\"" : name
    }

    package static func parseOEmbedTitle(from data: Data, kind: String) -> String? {
        guard let payload = try? JSONDecoder().decode(SpotifyOEmbedPayload.self, from: data),
              let name = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        return kind == "playlist" ? "Playlist \"\(name)\"" : name
    }

    static func profileName(accessToken: String) async throws(SpotifyBridgeError) -> String {
        let (data, status) = try await load(
            url: URL(string: "https://api.spotify.com/v1/me")!, method: "GET", token: accessToken, body: nil)
        guard (200..<300).contains(status),
              let resolved = parseProfileName(from: data) else {
            throw .network("profile HTTP \(status)")
        }
        return resolved
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        let joined = fields.map { key, value in "\(form(key))=\(form(value))" }.sorted().joined(separator: "&")
        return Data(joined.utf8)
    }

    package static func parseTokenResponse(_ data: Data) -> SpotifyTokenSet? {
        guard let payload = try? JSONDecoder().decode(SpotifyTokenPayload.self, from: data),
              !payload.accessToken.isEmpty else {
            return nil
        }
        return SpotifyTokenSet(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresIn: payload.expiresIn ?? 3600
        )
    }

    private static func token(bodyData: Data) async throws(SpotifyBridgeError) -> SpotifyTokenSet {
        let (data, status) = try await load(url: tokenURL, method: "POST", token: nil, body: bodyData)
        guard (200..<300).contains(status),
              let tokenSet = parseTokenResponse(data) else {
            throw .authorizationFailed("token HTTP \(status)")
        }
        return tokenSet
    }

    private static func load(url: URL, method: String, token: String?, body: Data?) async throws(SpotifyBridgeError) -> (Data, Int) {
        let (data, status, _) = try await loadWithHeaders(url: url, method: method, token: token, body: body)
        return (data, status)
    }

    static func loadWithHeaders(
        url: URL,
        method: String,
        token: String?,
        body: Data?
    ) async throws(SpotifyBridgeError) -> (Data, Int, TimeInterval?) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return (data, http?.statusCode ?? 0, retryAfter)
        } catch {
            throw .network(error.localizedDescription)
        }
    }

    package static func parseCurrentlyPlaying(_ data: Data) throws(SpotifyBridgeError) -> SpotifyTrackContext? {
        guard let payload = try? JSONDecoder().decode(SpotifyCurrentlyPlayingPayload.self, from: data) else {
            throw .network("currently-playing")
        }
        guard let item = payload.item else { return nil }
        let type = item.type ?? ""
        let isLocal = item.isLocal ?? false
        let uriString = item.uri ?? ""
        if isLocal || type != "track" || uriString.hasPrefix("spotify:local:") {
            throw .unplayableOnSonos(uriString.isEmpty ? type : uriString)
        }
        guard let uri = SpotifyURI(uriString) else { throw .unplayableOnSonos(uriString) }
        let artists = item.artists?.compactMap(\.name) ?? []
        let artwork = item.album?.images?.compactMap(\.url).first.flatMap(URL.init(string:))
        let metadata = SpotifyTrackMetadata(
            title: item.name ?? "",
            artist: artists.joined(separator: ", "),
            album: item.album?.name,
            artworkURL: artwork,
            duration: item.durationMs.map { .milliseconds($0) }
        )
        let rawDeviceID = payload.device?.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceID = (rawDeviceID?.isEmpty == false) ? rawDeviceID : nil
        return SpotifyTrackContext(
            uri: uri,
            metadata: metadata,
            position: payload.progressMs.map { .milliseconds($0) },
            contextTitle: nil,
            contextURI: payload.context?.uri,
            deviceID: deviceID,
            deviceName: payload.device?.name,
            deviceType: payload.device?.type,
            isPlaying: payload.isPlaying ?? false,
            upNext: []
        )
    }

    private static func form(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private func base64URL(_ data: Data) -> String { data.base64URLEncoded() }
