import AuthenticationServices
import Foundation
import Observation
import SconeDomain
import SwiftUI

public enum SpotifyBridgeError: Error, Hashable, Sendable {
    case notConnected
    case nothingPlaying
    case unplayableOnSonos(String)
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

    @ObservationIgnored private let explicitClientID: String
    @ObservationIgnored private let redirectURI: URL
    @ObservationIgnored private let vault: TokenVault
    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var accessExpiry: Date?
    @ObservationIgnored private var refreshToken: String?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var inFlightTokenRefresh: Task<String?, any Error>?

    private nonisolated static let displayNameKey = "Sconeos.Spotify.displayName"
    private nonisolated static let scopes = "user-read-currently-playing user-read-playback-state user-modify-playback-state"

    public init(
        clientID: String = "",
        redirectURI: URL = URL(string: "sconeos://spotify-callback")!,
        vault: TokenVault = TokenVault(service: "Sconeos.Spotify")
    ) {
        self.explicitClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.redirectURI = redirectURI
        self.vault = vault

        let snapshot = vault.loadSnapshot()
        if let cached = snapshot.accessToken {
            self.accessToken = cached.token
            self.accessExpiry = cached.expiry
        }
        self.refreshToken = snapshot.refreshToken
        if snapshot.refreshToken != nil || snapshot.accessToken != nil {
            let storedName = snapshot.displayName
                ?? UserDefaults.standard.string(forKey: Self.displayNameKey)
            let name = (storedName?.isEmpty == false) ? storedName! : "Spotify"
            UserDefaults.standard.set(name, forKey: Self.displayNameKey)
            if snapshot.displayName == nil {
                vault.storeDisplayName(name)
            }
            authorization = .connected(displayName: name)
            startBackgroundRefreshLoop()
            if storedName == nil {
                Task { [weak self] in
                    guard let self,
                          let token = try? await self.validAccessToken(),
                          let fetchedName = try? await WebAPI.profileName(accessToken: token),
                          !fetchedName.isEmpty else { return }
                    UserDefaults.standard.set(fetchedName, forKey: Self.displayNameKey)
                    self.vault.storeDisplayName(fetchedName)
                    self.authorization = .connected(displayName: fetchedName)
                }
            }
        }
    }

    public func connect(using session: WebAuthenticationSession) async throws(SpotifyBridgeError) {
        let verifier = PKCE.makeVerifier()
        let challenge = PKCE.challenge(for: verifier)
        let state = UUID().uuidString

        let authorizeURL: URL? = SealedClientStore.withEphemeralClientID(override: explicitClientID) { activeID in
            self.authorizeURL(clientID: activeID, challenge: challenge, state: state)
        }
        guard let authorizeURL else {
            throw .authorizationFailed("Spotify client credentials unavailable")
        }

        let callback: URL
        do {
            callback = try await session.authenticate(
                using: authorizeURL,
                callbackURLScheme: redirectURI.scheme ?? "sconeos",
                preferredBrowserSession: .shared
            )
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
        let tokens = try await WebAPI.exchange(
            code: code,
            verifier: verifier,
            explicitClientID: explicitClientID,
            redirectURI: redirectURI
        )
        let name = (try? await WebAPI.profileName(accessToken: tokens.accessToken)) ?? "Spotify"
        UserDefaults.standard.set(name, forKey: Self.displayNameKey)
        remember(tokens, displayName: name)
        authorization = .connected(displayName: name)
        startBackgroundRefreshLoop()
    }

    public func disconnect() {
        refreshTask?.cancel()
        refreshTask = nil
        inFlightTokenRefresh?.cancel()
        inFlightTokenRefresh = nil
        vault.clear()
        accessToken = nil
        accessExpiry = nil
        refreshToken = nil
        UserDefaults.standard.removeObject(forKey: Self.displayNameKey)
        if authorization != .notConnected {
            authorization = .notConnected
        }
    }

    public func currentContext() async throws(SpotifyBridgeError) -> SpotifyTrackContext {
        try await currentContext(forceRefresh: false)
    }

    public func currentContext(forceRefresh: Bool) async throws(SpotifyBridgeError) -> SpotifyTrackContext {
        guard let token = try await validAccessToken() else {
            throw .notConnected
        }
        let minAge: TimeInterval = forceRefresh ? 0 : 4.0
        do {
            guard let context = try await WebAPI.currentlyPlaying(accessToken: token, minCacheAge: minAge) else {
                throw SpotifyBridgeError.nothingPlaying
            }
            return context
        } catch SpotifyBridgeError.authorizationFailed {
            guard let refreshed = try await forceRefreshAccessToken() else {
                throw .notConnected
            }
            guard let context = try await WebAPI.currentlyPlaying(accessToken: refreshed, minCacheAge: minAge) else {
                throw .nothingPlaying
            }
            return context
        } catch let error as SpotifyBridgeError {
            throw error
        } catch {
            throw .authorizationFailed(error.localizedDescription)
        }
    }

    public func pauseSourcePlayback() async {
        if let token = try? await validAccessToken() {
            await WebAPI.pause(accessToken: token)
            await SpotifyAPIClient.shared.invalidateShortCache()
        }
    }

    public func resumeSourcePlayback() async -> Bool {
        guard let token = try? await validAccessToken() else { return false }
        let ok = await WebAPI.resume(accessToken: token)
        if ok {
            await SpotifyAPIClient.shared.invalidateShortCache()
        }
        return ok
    }

    public func playOnSonosGroup(
        coordinatorRoomName: String,
        memberRoomNames: [String],
        context: SpotifyTrackContext?
    ) async -> Bool {
        guard let token = try? await validAccessToken() else { return false }

        // 1. If Spotify's active device already matches this group's coordinator, resume directly.
        if SpotifyDeviceMatcher.matches(deviceName: context?.deviceName, roomName: coordinatorRoomName) {
            if await WebAPI.resume(accessToken: token, deviceID: context?.deviceID) {
                await SpotifyAPIClient.shared.invalidateShortCache()
                return true
            }
        }

        // 2. Query /v1/me/player/devices for a Spotify Connect target matching the group coordinator.
        let devices = await WebAPI.availableDevices(accessToken: token)
        if let coordDevice = devices.first(where: {
            SpotifyDeviceMatcher.matches(deviceName: $0.name, roomName: coordinatorRoomName)
        }) {
            if coordDevice.isActive {
                if await WebAPI.resume(accessToken: token, deviceID: coordDevice.id) {
                    await SpotifyAPIClient.shared.invalidateShortCache()
                    return true
                }
            } else if !coordDevice.isRestricted, let deviceID = coordDevice.id {
                if await WebAPI.transferPlayback(deviceID: deviceID, play: true, accessToken: token) {
                    if context?.isPlaying == false {
                        _ = await WebAPI.resume(accessToken: token, deviceID: deviceID)
                    }
                    await SpotifyAPIClient.shared.invalidateShortCache()
                    return true
                }
            }
        }

        return false
    }

    private func startBackgroundRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = try? await self.validAccessToken()
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    private func validAccessToken() async throws(SpotifyBridgeError) -> String? {
        if let accessToken, let accessExpiry, accessExpiry.timeIntervalSinceNow > 300 {
            return accessToken
        }
        return try await forceRefreshAccessToken()
    }

    private func forceRefreshAccessToken() async throws(SpotifyBridgeError) -> String? {
        if let existing = inFlightTokenRefresh {
            do {
                return try await existing.value
            } catch let error as SpotifyBridgeError {
                throw error
            } catch {
                throw .authorizationFailed(error.localizedDescription)
            }
        }
        guard let refresh = refreshToken ?? vault.refreshToken() else { return nil }
        self.refreshToken = refresh
        let explicitID = explicitClientID
        let task = Task<String?, any Error> {
            let tokens = try await WebAPI.refresh(explicitClientID: explicitID, refreshToken: refresh)
            self.remember(tokens, previousRefresh: refresh)
            return tokens.accessToken
        }
        inFlightTokenRefresh = task
        defer { inFlightTokenRefresh = nil }
        do {
            return try await task.value
        } catch let error as SpotifyBridgeError {
            throw error
        } catch {
            throw .authorizationFailed(error.localizedDescription)
        }
    }

    private func remember(_ tokens: SpotifyTokenSet, previousRefresh: String? = nil, displayName: String? = nil) {
        let expiry = Date().addingTimeInterval(TimeInterval(tokens.expiresIn))
        accessToken = tokens.accessToken
        accessExpiry = expiry
        let updatedRefresh: String?
        if let refresh = tokens.refreshToken, refresh != previousRefresh {
            refreshToken = refresh
            updatedRefresh = refresh
        } else if previousRefresh == nil, let refresh = tokens.refreshToken {
            refreshToken = refresh
            updatedRefresh = refresh
        } else {
            updatedRefresh = refreshToken
        }
        vault.store(
            accessToken: tokens.accessToken,
            expiry: expiry,
            refreshToken: updatedRefresh,
            displayName: displayName
        )
    }

    private func authorizeURL(clientID: String, challenge: String, state: String) -> URL? {
        guard !clientID.isEmpty else { return nil }
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
