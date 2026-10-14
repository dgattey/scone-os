import AuthenticationServices
import Foundation
import Observation
import SconeDomain
import SwiftUI

public enum SpotifyBridgeError: Error, Hashable, Sendable {
    /// No token, and no local Spotify.app to ask (iOS, or macOS with Spotify closed).
    case notConnected
    case nothingPlaying
    /// A local file, podcast episode, or ad. Carries the raw URI for the alert.
    case unplayableOnSonos(String)
    /// The person declined the Automation prompt for Spotify (AppleScript error -1743).
    case automationDenied
    case authorizationFailed(String)
    case network(String)
}

/// Turns "what am I listening to" into a `SpotifyTrackContext`, from whichever source can answer.
/// The caller never chooses a source.
@MainActor
@Observable
public final class SpotifyBridge {
    public enum Authorization: Hashable, Sendable {
        case notConnected
        case connected(displayName: String)
    }

    public private(set) var authorization: Authorization = .notConnected

    @ObservationIgnored private let clientID: String
    @ObservationIgnored private let redirectURI: URL
    @ObservationIgnored private let vault: TokenVault

    /// `redirectURI` uses the app's custom scheme, e.g. `sconeos://spotify-callback`. PKCE needs no
    /// client secret, so nothing secret ships in the binary.
    public init(clientID: String, redirectURI: URL) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.vault = TokenVault(service: "SconeOS.Spotify")
        // TODO: authorization = vault has a refresh token ? .connected(cached display name) : .notConnected
    }

    /// PKCE authorization code flow through SwiftUI's `@Environment(\.webAuthenticationSession)`,
    /// which works on both platforms without a presentation anchor. Scopes:
    /// `user-read-currently-playing user-read-playback-state user-modify-playback-state`.
    public func connect(using session: WebAuthenticationSession) async throws(SpotifyBridgeError) {
        // TODO: verifier = PKCE.makeVerifier(); challenge = PKCE.challenge(for: verifier)
        // callback = session.authenticate(using: authorizeURL, callbackURLScheme: "sconeos", preferredBrowserSession: .ephemeral)
        // check `state`; exchange code + verifier at accounts.spotify.com/api/token; vault.store(refresh);
        // fetch /v1/me for displayName
        fatalError("not implemented")
    }

    public func disconnect() {
        fatalError("not implemented")
    }

    /// macOS: Spotify.app through `osascript` when it is running and has a track, because it is the
    /// player on this machine and needs no account. Otherwise the Web API
    /// `/v1/me/player/currently-playing`, which also covers a phone or another computer.
    /// iOS: Web API only.
    public func currentContext() async throws(SpotifyBridgeError) -> SpotifyTrackContext {
        fatalError("not implemented")
    }

    /// Pauses wherever `currentContext()` read from, after a hand-off, so music doesn't play twice.
    public func pauseSourcePlayback() async {
        fatalError("not implemented")
    }
}
