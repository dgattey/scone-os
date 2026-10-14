#if os(macOS)
import Foundation
import SconeDomain

/// Zero-config source on macOS. Runs `/usr/bin/osascript` off the main actor.
///
/// Needs `com.apple.security.automation.apple-events` and `NSAppleEventsUsageDescription`. A
/// sandboxed build also needs a temporary exception for `com.spotify.client`.
enum AppleScriptSource {
    /// Guards on `is running` first, because a bare `tell application "Spotify"` launches it.
    /// Position goes out as integer milliseconds, because AppleScript formats reals with the
    /// locale's decimal separator ("12,5" in some locales).
    static let script = """
        if application "Spotify" is not running then return "NOT_RUNNING"
        tell application "Spotify"
          if player state is stopped then return "STOPPED"
          set t to current track
          return (id of t) & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & ¬
            (duration of t) & tab & ((player position * 1000) as integer) & tab & (artwork url of t)
        end tell
        """

    static func read() async throws(SpotifyBridgeError) -> SpotifyTrackContext? {
        fatalError("not implemented")
    }

    /// Pure, so it is tested against literal script output. `NOT_RUNNING` and `STOPPED` return nil.
    /// A `spotify:local:` id throws `.unplayableOnSonos`.
    static func parse(_ output: String) throws(SpotifyBridgeError) -> SpotifyTrackContext? {
        fatalError("not implemented")
    }

    static func pause() async {
        fatalError("not implemented")
    }
}
#endif
