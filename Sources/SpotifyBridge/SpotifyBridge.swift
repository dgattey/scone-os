import AuthenticationServices
import Foundation
import Observation
import SconeDomain
import SwiftUI

public enum SpotifyBridgeError: Error, Hashable, Sendable {
    case notConnected
    case nothingPlaying
    case unplayableOnSonos(String)
    case automationDenied
    case authorizationFailed(String)
    case network(String)
}

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
    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var accessExpiry: Date?
    @ObservationIgnored private var lastSource: PlaybackSource?

    private enum PlaybackSource { case appleScript, webAPI }

    private static let displayNameKey = "SconeOS.Spotify.displayName"
    private static let scopes = "user-read-currently-playing user-read-playback-state user-modify-playback-state"

    public init(clientID: String, redirectURI: URL) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.vault = TokenVault(service: "SconeOS.Spotify")
        if vault.refreshToken() != nil {
            let name = UserDefaults.standard.string(forKey: Self.displayNameKey) ?? "Spotify"
            authorization = .connected(displayName: name)
        }
    }

    public func connect(using session: WebAuthenticationSession) async throws(SpotifyBridgeError) {
        let verifier = PKCE.makeVerifier()
        let challenge = PKCE.challenge(for: verifier)
        let state = UUID().uuidString
        guard let authorizeURL = authorizeURL(challenge: challenge, state: state) else {
            throw .authorizationFailed("bad authorize URL")
        }
        let callback: URL
        do {
            callback = try await session.authenticate(
                using: authorizeURL,
                callbackURLScheme: redirectURI.scheme ?? "sconeos",
                preferredBrowserSession: .ephemeral)
        } catch {
            throw .authorizationFailed(error.localizedDescription)
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if items.first(where: { $0.name == "state" })?.value != state {
            throw .authorizationFailed("state mismatch")
        }
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw .authorizationFailed(error)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw .authorizationFailed("missing code")
        }
        let tokens = try await WebAPI.exchange(code: code, verifier: verifier, clientID: clientID, redirectURI: redirectURI)
        remember(tokens)
        let name = (try? await WebAPI.profileName(accessToken: tokens.accessToken)) ?? "Spotify"
        UserDefaults.standard.set(name, forKey: Self.displayNameKey)
        authorization = .connected(displayName: name)
    }

    public func disconnect() {
        vault.clear()
        accessToken = nil
        accessExpiry = nil
        lastSource = nil
        UserDefaults.standard.removeObject(forKey: Self.displayNameKey)
        authorization = .notConnected
    }

    public func currentContext() async throws(SpotifyBridgeError) -> SpotifyTrackContext {
        #if os(macOS)
        var automationDenied = false
        do {
            if let local = try await AppleScriptSource.read() {
                lastSource = .appleScript
                return local
            }
        } catch {
            switch error {
            case .unplayableOnSonos: throw error
            case .automationDenied: automationDenied = true
            case .notConnected, .nothingPlaying, .authorizationFailed, .network: break
            }
        }
        #endif
        guard let token = try await validAccessToken() else {
            #if os(macOS)
            if automationDenied { throw .automationDenied }
            #endif
            throw .notConnected
        }
        guard let context = try await WebAPI.currentlyPlaying(accessToken: token) else { throw .nothingPlaying }
        lastSource = .webAPI
        return context
    }

    public func pauseSourcePlayback() async {
        switch lastSource {
        case .appleScript:
            #if os(macOS)
            await AppleScriptSource.pause()
            #endif
        case .webAPI:
            if let token = try? await validAccessToken() { await WebAPI.pause(accessToken: token) }
        case nil:
            break
        }
    }

    private func validAccessToken() async throws(SpotifyBridgeError) -> String? {
        if let accessToken, let accessExpiry, accessExpiry.timeIntervalSinceNow > 60 { return accessToken }
        guard let refresh = vault.refreshToken() else { return nil }
        let tokens = try await WebAPI.refresh(clientID: clientID, refreshToken: refresh)
        remember(tokens, previousRefresh: refresh)
        return tokens.accessToken
    }

    private func remember(_ tokens: SpotifyTokenSet, previousRefresh: String? = nil) {
        accessToken = tokens.accessToken
        accessExpiry = Date().addingTimeInterval(TimeInterval(tokens.expiresIn))
        if let refresh = tokens.refreshToken, refresh != previousRefresh {
            vault.store(refreshToken: refresh)
        } else if previousRefresh == nil, let refresh = tokens.refreshToken {
            vault.store(refreshToken: refresh)
        }
    }

    private func authorizeURL(challenge: String, state: String) -> URL? {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]
        return components?.url
    }
}
