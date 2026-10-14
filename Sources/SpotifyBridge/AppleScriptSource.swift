#if os(macOS)
import Foundation
import SconeDomain

enum AppleScriptSource {
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
        try parse(await run(script))
    }

    static func parse(_ output: String) throws(SpotifyBridgeError) -> SpotifyTrackContext? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "NOT_RUNNING" || trimmed == "STOPPED" { return nil }
        let fields = trimmed.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 7 else { throw .network("unexpected Spotify script output") }
        let rawID = fields[0]
        if rawID.hasPrefix("spotify:local:") || rawID.hasPrefix("spotify:episode:") {
            throw .unplayableOnSonos(rawID)
        }
        guard let uri = SpotifyURI(rawID) else { throw .unplayableOnSonos(rawID) }
        let artworkText = fields[6]
        let metadata = SpotifyTrackMetadata(
            title: fields[1],
            artist: fields[2],
            album: fields[3].isEmpty ? nil : fields[3],
            artworkURL: artworkText == "missing value" ? nil : URL(string: artworkText),
            duration: milliseconds(fields[4]))
        return SpotifyTrackContext(uri: uri, metadata: metadata, position: milliseconds(fields[5]))
    }

    static func pause() async {
        _ = try? await run("""
            if application "Spotify" is not running then return
            tell application "Spotify" to pause
            """)
    }

    private static func milliseconds(_ field: String) -> Duration? {
        guard let value = Int(field) else { return nil }
        return .milliseconds(value)
    }

    private static func run(_ source: String) async throws(SpotifyBridgeError) -> String {
        let pipes = ScriptPipes()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = pipes.output
        process.standardError = pipes.errors
        let result: Result<String, SpotifyBridgeError> = await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                let text = String(data: pipes.output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: pipes.errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume(returning: .success(text))
                } else if err.contains("-1743") {
                    continuation.resume(returning: .failure(.automationDenied))
                } else {
                    let detail = err.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: .failure(.network(detail.isEmpty ? "osascript \(process.terminationStatus)" : detail)))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: .failure(.network(error.localizedDescription)))
            }
        }
        return try result.get()
    }
}

private final class ScriptPipes: @unchecked Sendable {
    let output = Pipe()
    let errors = Pipe()
}
#endif
