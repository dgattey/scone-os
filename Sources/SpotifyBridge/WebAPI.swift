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
    private let fallbackKeys: [SymmetricKey]

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
           let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
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
        self.fallbackKeys = fallbacks
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

    private func readEncryptedFile() -> VaultRecord? {
        guard let combined = try? Data(contentsOf: vaultFileURL),
              let sealedBox = try? AES.GCM.SealedBox(combined: combined) else {
            return nil
        }
        if let plaintext = try? AES.GCM.open(sealedBox, using: derivedKey),
           let record = try? JSONDecoder().decode(VaultRecord.self, from: plaintext) {
            return record
        }
        for fallbackKey in fallbackKeys {
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

struct SpotifyTokenSet: Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Int
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
            deviceName: base.deviceName,
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
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !name.isEmpty {
                    let formatted = kind == "playlist" ? "Playlist \"\(name)\"" : name
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
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let name = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !name.isEmpty {
                    let formatted = kind == "playlist" ? "Playlist \"\(name)\"" : name
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

enum WebAPI {
    static let playerURL = URL(string: "https://api.spotify.com/v1/me/player")!
    static let queueURL = URL(string: "https://api.spotify.com/v1/me/player/queue")!
    private static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!

    static func currentlyPlaying(accessToken: String) async throws(SpotifyBridgeError) -> SpotifyTrackContext? {
        try await SpotifyAPIClient.shared.currentlyPlaying(accessToken: accessToken)
    }

    static func parseQueueData(_ data: Data) -> [QueueItem] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let queueArray = json["queue"] as? [[String: Any]] else {
            return []
        }
        var seen = Set<String>()
        var items: [QueueItem] = []
        for (idx, item) in queueArray.prefix(20).enumerated() {
            guard let title = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { continue }
            let uriString = (item["uri"] as? String) ?? ""
            let spotifyURI = SpotifyURI(uriString)
            let artists = (item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            let artistText = artists.joined(separator: ", ")
            let albumDict = item["album"] as? [String: Any]
            let albumName = albumDict?["name"] as? String
            let images = albumDict?["images"] as? [[String: Any]]
            let artwork = images?.compactMap { $0["url"] as? String }.first.flatMap(URL.init(string:))
            let duration = int(item["duration_ms"]).map { Duration.milliseconds($0) }
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

    static func resume(accessToken: String) async -> Bool {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/play")!)
        request.httpMethod = "PUT"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
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

    static func profileName(accessToken: String) async throws(SpotifyBridgeError) -> String {
        let (data, status) = try await load(
            url: URL(string: "https://api.spotify.com/v1/me")!, method: "GET", token: accessToken, body: nil)
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .network("profile HTTP \(status)")
        }
        let name = (json["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        return (json["id"] as? String) ?? "Spotify"
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        let joined = fields.map { key, value in "\(form(key))=\(form(value))" }.sorted().joined(separator: "&")
        return Data(joined.utf8)
    }

    private static func token(bodyData: Data) async throws(SpotifyBridgeError) -> SpotifyTokenSet {
        let (data, status) = try await load(url: tokenURL, method: "POST", token: nil, body: bodyData)
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw .authorizationFailed("token HTTP \(status)")
        }
        return SpotifyTokenSet(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String,
            expiresIn: int(json["expires_in"]) ?? 3600)
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

    static func parseCurrentlyPlaying(_ data: Data) throws(SpotifyBridgeError) -> SpotifyTrackContext? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .network("currently-playing")
        }
        guard let item = json["item"] as? [String: Any] else { return nil }
        let type = item["type"] as? String ?? ""
        let isLocal = item["is_local"] as? Bool ?? false
        let uriString = (item["uri"] as? String) ?? ""
        if isLocal || type != "track" || uriString.hasPrefix("spotify:local:") {
            throw .unplayableOnSonos(uriString.isEmpty ? type : uriString)
        }
        guard let uri = SpotifyURI(uriString) else { throw .unplayableOnSonos(uriString) }
        let artists = (item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        let album = item["album"] as? [String: Any]
        let images = album?["images"] as? [[String: Any]]
        let artwork = images?.compactMap { $0["url"] as? String }.first.flatMap(URL.init(string:))
        let metadata = SpotifyTrackMetadata(
            title: item["name"] as? String ?? "",
            artist: artists.joined(separator: ", "),
            album: album?["name"] as? String,
            artworkURL: artwork,
            duration: int(item["duration_ms"]).map { .milliseconds($0) })
        let contextDict = json["context"] as? [String: Any]
        let contextURI = contextDict?["uri"] as? String
        let deviceDict = json["device"] as? [String: Any]
        let deviceName = deviceDict?["name"] as? String
        return SpotifyTrackContext(
            uri: uri,
            metadata: metadata,
            position: int(json["progress_ms"]).map { .milliseconds($0) },
            contextTitle: nil,
            contextURI: contextURI,
            deviceName: deviceName,
            upNext: []
        )
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
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
