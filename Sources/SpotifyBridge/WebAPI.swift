import CryptoKit
import Foundation
import SconeDomain
import Security

enum PKCE {
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        }
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}

struct TokenVault: Sendable {
    let service: String

    func refreshToken() -> String? {
        keychainValue() ?? UserDefaults.standard.string(forKey: defaultsKey)
    }

    func store(refreshToken: String) {
        if writeKeychain(refreshToken) {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(refreshToken, forKey: defaultsKey)
        }
    }

    func clear() {
        SecItemDelete(keychainQuery as CFDictionary)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private var defaultsKey: String { "\(service).refreshToken" }

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "refresh-token",
        ]
    }

    private func keychainValue() -> String? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeKeychain(_ token: String) -> Bool {
        let data = Data(token.utf8)
        if SecItemCopyMatching(keychainQuery as CFDictionary, nil) == errSecSuccess {
            let updated = SecItemUpdate(keychainQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            return updated == errSecSuccess
        }
        var query = keychainQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}

struct SpotifyTokenSet: Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Int
}

enum WebAPI {
    static func currentlyPlaying(accessToken: String) async throws(SpotifyBridgeError) -> SpotifyTrackContext? {
        let (data, status) = try await load(url: playerURL, method: "GET", token: accessToken, body: nil)
        if status == 204 || status == 202 { return nil }
        if status == 401 { throw .authorizationFailed("401") }
        guard (200..<300).contains(status) else { throw .network("currently-playing HTTP \(status)") }
        return try parseCurrentlyPlaying(data)
    }

    static func pause(accessToken: String) async {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/pause")!)
        request.httpMethod = "PUT"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
    }

    static func exchange(code: String, verifier: String, clientID: String, redirectURI: URL) async throws(SpotifyBridgeError) -> SpotifyTokenSet {
        try await token([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI.absoluteString,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
    }

    static func refresh(clientID: String, refreshToken: String) async throws(SpotifyBridgeError) -> SpotifyTokenSet {
        try await token([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
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

    private static let playerURL = URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!
    private static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!

    private static func token(_ fields: [String: String]) async throws(SpotifyBridgeError) -> SpotifyTokenSet {
        let body = fields.map { key, value in "\(form(key))=\(form(value))" }.sorted().joined(separator: "&")
        let (data, status) = try await load(url: tokenURL, method: "POST", token: nil, body: Data(body.utf8))
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
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw .network(error.localizedDescription)
        }
    }

    private static func parseCurrentlyPlaying(_ data: Data) throws(SpotifyBridgeError) -> SpotifyTrackContext? {
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
        return SpotifyTrackContext(uri: uri, metadata: metadata, position: int(json["progress_ms"]).map { .milliseconds($0) })
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
