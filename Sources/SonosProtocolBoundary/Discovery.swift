import Foundation
import SconeDomain

/// Finds one answering speaker. Discovery only has to produce a seed, since topology from any
/// speaker names every member and its IP.
enum Discovery {
    struct SSDPSighting: Sendable {
        let speaker: SpeakerUUID
        let location: URL
        let householdID: String
        /// `X-RINCON-PROXY`: set on home-theater satellites. Still a valid seed, never a visible speaker.
        let proxiedBy: SpeakerUUID?
    }

    static let ssdpSearch = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 2\r
        ST: urn:schemas-upnp-org:device:ZonePlayer:1\r
        \r

        """

    /// Sonos players advertise this Bonjour type (inference, to verify on the household). Browsing it
    /// needs only `NSBonjourServices` and local-network permission. SSDP multicast on iOS needs the
    /// `com.apple.developer.networking.multicast` entitlement, which Apple grants by request.
    static let bonjourServiceType = "_sonos._tcp"

    static func parse(ssdpResponse datagram: Data) -> SSDPSighting? {
        fatalError("not implemented")
    }

    /// SSDP on macOS (and iOS once the entitlement exists) merged with a Bonjour browse. Yields
    /// endpoints until cancelled.
    static func seeds() -> AsyncStream<URL> {
        fatalError("not implemented")
    }
}
