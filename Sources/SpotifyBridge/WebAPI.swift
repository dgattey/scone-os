import Foundation
import SconeDomain

enum PKCE {
    /// 64 random bytes, base64url without padding (43 to 128 characters per RFC 7636).
    static func makeVerifier() -> String {
        fatalError("not implemented")
    }

    /// base64url(SHA256(verifier)).
    static func challenge(for verifier: String) -> String {
        fatalError("not implemented")
    }
}

/// Refresh token in the Keychain. The access token stays in memory with its expiry.
struct TokenVault: Sendable {
    let service: String

    func refreshToken() -> String? {
        fatalError("not implemented")
    }

    func store(refreshToken: String) {
        fatalError("not implemented")
    }

    func clear() {
        fatalError("not implemented")
    }
}

enum WebAPI {
    /// `GET /v1/me/player/currently-playing`. 204 means nothing is playing. An `item.type` of
    /// `episode` or `is_local: true` throws `.unplayableOnSonos`.
    static func currentlyPlaying(accessToken: String) async throws(SpotifyBridgeError) -> SpotifyTrackContext? {
        fatalError("not implemented")
    }

    static func pause(accessToken: String) async {
        fatalError("not implemented")
    }
}
