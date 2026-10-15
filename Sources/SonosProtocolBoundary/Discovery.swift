import Darwin
import Foundation
import os
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
            let dedup = SeenURLSet()
            let yieldURL: @Sendable (URL) -> Void = { url in
                if dedup.insert(url.absoluteString) {
                    continuation.yield(url)
                }
            }

            Task.detached(priority: .utility) {
                listen(channel: channel, yield: yieldURL)
            }

            Task.detached(priority: .utility) {
                probeLocalSubnets(channel: channel, yield: yieldURL)
                channel.close()
                continuation.finish()
            }

            continuation.onTermination = { _ in channel.close() }
        }
    }

    static func activeSubnetPrefixes() -> [String] {
        var prefixes: [String] = []
        var seen = Set<String>()
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let first = ifaddrPointer else { return [] }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr, socklen_t(MemoryLayout<sockaddr_in>.size),
                &hostname, socklen_t(hostname.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let bytes = hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let ip = String(decoding: bytes, as: UTF8.self)
            let octets = ip.split(separator: ".")
            guard octets.count == 4,
                  !ip.hasPrefix("169.254."),
                  !ip.hasPrefix("127.") else { continue }
            let prefix = "\(octets[0]).\(octets[1]).\(octets[2])"
            if seen.insert(prefix).inserted {
                prefixes.append(prefix)
            }
        }
        return prefixes
    }

    private static func probeLocalSubnets(channel: InterruptibleSocket, yield: @Sendable (URL) -> Void) {
        let prefixes = activeSubnetPrefixes()
        let batchSize = 64
        for prefix in prefixes {
            var hostStart = 1
            while hostStart <= 254 {
                if channel.isClosed { return }
                let hostEnd = min(hostStart + batchSize - 1, 254)
                var fds: [(fd: Int32, host: String)] = []
                for hostNum in hostStart...hostEnd {
                    let host = "\(prefix).\(hostNum)"
                    var address = sockaddr_in()
                    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    address.sin_family = sa_family_t(AF_INET)
                    address.sin_port = UInt16(1400).bigEndian
                    guard Darwin.inet_pton(AF_INET, host, &address.sin_addr) == 1 else { continue }
                    let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                    guard fd >= 0 else { continue }
                    let currentFlags = Darwin.fcntl(fd, F_GETFL, 0)
                    _ = Darwin.fcntl(fd, F_SETFL, currentFlags | O_NONBLOCK)
                    var noSigPipe: Int32 = 1
                    Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
                    let rc = withUnsafePointer(to: &address) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                            Darwin.connect(fd, sock, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                    if rc == 0 {
                        Darwin.close(fd)
                        if let url = URL(string: "http://\(host):1400") { yield(url) }
                    } else if errno == EINPROGRESS {
                        fds.append((fd, host))
                    } else {
                        Darwin.close(fd)
                    }
                }
                if !fds.isEmpty {
                    var pollFDs = fds.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
                    let ready = Darwin.poll(&pollFDs, nfds_t(pollFDs.count), 180)
                    if ready > 0 {
                        for index in pollFDs.indices where (pollFDs[index].revents & Int16(POLLOUT)) != 0 {
                            var socketError: Int32 = 0
                            var errorLen = socklen_t(MemoryLayout<Int32>.size)
                            if Darwin.getsockopt(pollFDs[index].fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLen) == 0,
                               socketError == 0 {
                                let host = fds[index].host
                                if let url = URL(string: "http://\(host):1400") { yield(url) }
                            }
                        }
                    }
                    for item in fds { Darwin.close(item.fd) }
                }
                hostStart = hostEnd + 1
            }
        }
    }

    private static func rinconID(in header: String) -> SpeakerUUID? {
        let upper = header.uppercased()
        guard let match = upper.firstMatch(of: /RINCON_[0-9A-F]{12}[0-9]{5}/) else {
            return nil
        }
        return SpeakerUUID(rawValue: String(match.0))
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
        for prefix in activeSubnetPrefixes() {
            send(host: "\(prefix).255")
        }
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

private final class InterruptibleSocket: Sendable {
    private struct State: Sendable {
        var fd: Int32 = -1
        var closed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isClosed: Bool {
        state.withLock { $0.closed }
    }

    func adopt(_ socketFD: Int32) -> Bool {
        state.withLock { state in
            if state.closed { return false }
            state.fd = socketFD
            return true
        }
    }

    func close() {
        let current = state.withLock { state -> Int32 in
            let existing = state.fd
            state.fd = -1
            state.closed = true
            return existing
        }
        if current >= 0 { Darwin.close(current) }
    }
}

private final class SeenURLSet: Sendable {
    private let seen = OSAllocatedUnfairLock(initialState: Set<String>())

    func insert(_ value: String) -> Bool {
        seen.withLock { $0.insert(value).inserted }
    }
}
