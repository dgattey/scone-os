import Darwin
import Foundation
import SconeDomain

enum Discovery {
    struct SSDPSighting: Sendable {
        let speaker: SpeakerUUID
        let location: URL
        let householdID: String
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

    static let bonjourServiceType = "_sonos._tcp"

    private static let fallbackHosts = [
        "192.168.68.58", "192.168.68.71", "192.168.68.73", "192.168.68.90", "192.168.68.92", "192.168.68.95",
    ]

    static func parse(ssdpResponse datagram: Data) -> SSDPSighting? {
        guard let text = String(data: datagram, encoding: .utf8) ?? String(data: datagram, encoding: .isoLatin1) else {
            return nil
        }
        var headers: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { headers[key] = value }
        }
        guard let location = headers["LOCATION"], let speaker = rinconID(in: headers["USN"] ?? ""),
              let base = baseURL(location: location) else { return nil }
        return SSDPSighting(
            speaker: speaker,
            location: base,
            householdID: headers["X-RINCON-HOUSEHOLD"] ?? "",
            proxiedBy: rinconID(in: headers["X-RINCON-PROXY"] ?? ""))
    }

    static func seeds() -> AsyncStream<URL> {
        AsyncStream { continuation in
            let channel = InterruptibleSocket()
            let thread = Thread {
                var seen = Set<String>()
                func yield(_ url: URL) {
                    if seen.insert(url.absoluteString).inserted { continuation.yield(url) }
                }
                for host in fallbackHosts {
                    if let url = URL(string: "http://\(host):1400") { yield(url) }
                }
                listen(channel: channel, yield: yield)
                channel.close()
                continuation.finish()
            }
            thread.name = "sonos-ssdp"
            thread.start()
            continuation.onTermination = { _ in channel.close() }
        }
    }

    private static func rinconID(in header: String) -> SpeakerUUID? {
        let upper = header.uppercased()
        guard let range = upper.range(of: #"RINCON_[0-9A-F]{12}[0-9]{5}"#, options: .regularExpression) else {
            return nil
        }
        return SpeakerUUID(rawValue: String(upper[range]))
    }

    private static func baseURL(location: String) -> URL? {
        guard let url = URL(string: location), let host = url.host, !host.isEmpty else { return nil }
        let rendered = host.contains(":") ? "[\(host)]" : host
        return URL(string: "http://\(rendered):1400")
    }

    private static func listen(channel: InterruptibleSocket, yield: (URL) -> Void) {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        guard channel.adopt(fd) else {
            Darwin.close(fd)
            return
        }
        defer { channel.close() }

        var reuse: Int32 = 1
        Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var broadcast: Int32 = 1
        Darwin.setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout.size(ofValue: broadcast)))
        var ttl: UInt8 = 2
        Darwin.setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout.size(ofValue: ttl)))

        var bindAddress = sockaddr_in()
        bindAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddress.sin_family = sa_family_t(AF_INET)
        bindAddress.sin_port = 0
        bindAddress.sin_addr.s_addr = in_addr_t(0)
        let bound = withUnsafePointer(to: &bindAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                Darwin.bind(fd, sock, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return }

        let payload = Array((ssdpSearch.trimmingCharacters(in: .newlines) + "\r\n\r\n").utf8)
        func send(host: String) {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(1900).bigEndian
            guard Darwin.inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return }
            _ = payload.withUnsafeBytes { buffer in
                withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                        Darwin.sendto(fd, buffer.baseAddress, buffer.count, 0, sock, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        send(host: "239.255.255.250")
        send(host: "255.255.255.255")
        send(host: "239.255.255.250")

        let deadline = Date().addingTimeInterval(1.5)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            let seconds = Int(remaining)
            var timeout = timeval(
                tv_sec: time_t(seconds),
                tv_usec: suseconds_t((remaining - Double(seconds)) * 1_000_000))
            Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            let count = Darwin.recvfrom(fd, &buffer, buffer.count, 0, nil, nil)
            if count < 0 { break }
            guard count > 0, let sighting = parse(ssdpResponse: Data(buffer.prefix(count))) else { continue }
            yield(sighting.location)
        }
    }
}

private final class InterruptibleSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var closed = false

    func adopt(_ socketFD: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed { return false }
        fd = socketFD
        return true
    }

    func close() {
        lock.lock()
        let current = fd
        fd = -1
        closed = true
        lock.unlock()
        if current >= 0 { Darwin.close(current) }
    }
}
