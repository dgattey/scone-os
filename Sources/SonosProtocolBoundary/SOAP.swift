import Darwin
import Foundation
import SconeDomain

public enum NetworkDebugLog {
    private static let lock = NSLock()

    public static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("Sconeos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("network-debug.log")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        let pid = ProcessInfo.processInfo.processIdentifier
        let ppid = Darwin.getppid()
        let bundleID = Bundle.main.bundleIdentifier ?? "nil"
        let line = "[\(timestamp)] [pid=\(pid) ppid=\(ppid) bundle=\(bundleID)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: file.path) {
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: file, options: .atomic)
        }
    }
}

enum UPnPService: CaseIterable {
    case zoneGroupTopology, avTransport, renderingControl, groupRenderingControl, contentDirectory, queue, systemProperties

    var urn: String {
        switch self {
        case .zoneGroupTopology: "urn:schemas-upnp-org:service:ZoneGroupTopology:1"
        case .avTransport: "urn:schemas-upnp-org:service:AVTransport:1"
        case .renderingControl: "urn:schemas-upnp-org:service:RenderingControl:1"
        case .groupRenderingControl: "urn:schemas-upnp-org:service:GroupRenderingControl:1"
        case .contentDirectory: "urn:schemas-upnp-org:service:ContentDirectory:1"
        case .queue: "urn:schemas-sonos-com:service:Queue:1"
        case .systemProperties: "urn:schemas-upnp-org:service:SystemProperties:1"
        }
    }

    var controlPath: String {
        switch self {
        case .zoneGroupTopology: "/ZoneGroupTopology/Control"
        case .avTransport: "/MediaRenderer/AVTransport/Control"
        case .renderingControl: "/MediaRenderer/RenderingControl/Control"
        case .groupRenderingControl: "/MediaRenderer/GroupRenderingControl/Control"
        case .contentDirectory: "/MediaServer/ContentDirectory/Control"
        case .queue: "/MediaRenderer/Queue/Control"
        case .systemProperties: "/SystemProperties/Control"
        }
    }
}

struct SOAPRequest: Sendable {
    let service: UPnPService
    let action: String
    let arguments: [(String, String)]
}

struct ProtocolParseError: Error, CustomStringConvertible {
    let description: String
}

func xmlEscaped(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

func sonosURL(endpoint: URL, path: String) -> URL? {
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
    let raw = path.hasPrefix("/") ? path : "/" + path
    if let mark = raw.firstIndex(of: "?") {
        components.path = String(raw[..<mark])
        components.percentEncodedQuery = String(raw[raw.index(after: mark)...])
    } else {
        components.path = raw
        components.percentEncodedQuery = nil
    }
    return components.url
}

struct SOAPClient: Sendable {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func call(_ request: SOAPRequest, on speaker: SpeakerUUID, at endpoint: URL) async throws(SonosCommandError) -> XMLNode {
        try await perform(request, at: endpoint, failure: .speakerUnreachable(speaker))
    }

    func call(_ request: SOAPRequest, at endpoint: URL) async throws(SonosCommandError) -> XMLNode {
        try await perform(request, at: endpoint, failure: .speakerRejected(detail: "\(request.action) unreachable"))
    }

    func get(_ path: String, at endpoint: URL) async throws(SonosCommandError) -> Data {
        guard let url = sonosURL(endpoint: endpoint, path: path) else {
            throw .speakerRejected(detail: "GET \(path)")
        }
        var urlRequest = URLRequest(url: url, timeoutInterval: 6)
        urlRequest.httpMethod = "GET"
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: urlRequest)
        } catch {
            throw .speakerRejected(detail: "GET \(path) unreachable")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw .speakerRejected(detail: "GET \(path) HTTP \(status)")
        }
        return data
    }

    private func perform(_ request: SOAPRequest, at endpoint: URL, failure: SonosCommandError) async throws(SonosCommandError) -> XMLNode {
        guard let url = sonosURL(endpoint: endpoint, path: request.service.controlPath) else { throw failure }
        var urlRequest = URLRequest(url: url, timeoutInterval: 8)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("\"\(request.service.urn)#\(request.action)\"", forHTTPHeaderField: "SOAPACTION")
        urlRequest.httpBody = Data(envelope(request).utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: urlRequest)
        } catch {
            let firstErr = error as NSError
            if firstErr.domain == NSURLErrorDomain, firstErr.code == NSURLErrorCancelled {
                throw failure
            }
            try? await Task.sleep(for: .milliseconds(150))
            do {
                (data, response) = try await Self.session.data(for: urlRequest)
            } catch {
                let nsErr = error as NSError
                if nsErr.domain != NSURLErrorDomain || nsErr.code != NSURLErrorCancelled {
                    let underlying = (nsErr.userInfo[NSUnderlyingErrorKey] as? NSError).map { "\($0.domain):\($0.code)" } ?? "none"
                    NetworkDebugLog.write("SOAP \(request.action) -> \(url.absoluteString) FAILED: \(nsErr.domain) code=\(nsErr.code) underlying=\(underlying) desc=\(nsErr.localizedDescription)")
                }
                throw failure
            }
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let node = try? XMLNode.parse(data)
        if status == 500 {
            let code = node?.descendants("errorCode").first?.text ?? "500"
            let description = node?.descendants("errorDescription").first?.text ?? ""
            let detail = description.isEmpty ? "\(request.action) \(code)" : "\(request.action) \(code) \(description)"
            throw .speakerRejected(detail: detail)
        }
        guard (200..<300).contains(status), let node else { throw failure }
        guard let body = node.descendants(request.action + "Response").first else {
            throw .speakerRejected(detail: "\(request.action) missing response")
        }
        return body
    }

    private func envelope(_ request: SOAPRequest) -> String {
        let arguments = request.arguments.map { name, value in
            "<\(name)>\(xmlEscaped(value))</\(name)>"
        }.joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body><u:\(request.action) xmlns:u="\(request.service.urn)">\(arguments)</u:\(request.action)></s:Body>\
        </s:Envelope>
        """
    }
}

struct XMLNode: Sendable {
    let name: String
    let attributes: [String: String]
    let children: [XMLNode]
    let text: String

    static func parse(_ data: Data) throws -> XMLNode {
        let builder = XMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw parser.parserError ?? ProtocolParseError(description: "XML parse failed")
        }
        return root
    }

    func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }

    func descendants(_ name: String) -> [XMLNode] {
        children.flatMap { child in
            (child.name == name ? [child] : []) + child.descendants(name)
        }
    }

    func value(_ name: String) -> String {
        if let child = child(name) { return child.text }
        return descendants(name).first?.text ?? ""
    }

    func attribute(_ name: String) -> String? {
        if let value = attributes[name] { return value }
        return attributes.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    fileprivate static func localName(_ raw: String) -> String {
        guard let colon = raw.lastIndex(of: ":") else { return raw }
        let local = raw[raw.index(after: colon)...]
        return local.isEmpty ? raw : String(local)
    }
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    private final class Frame {
        let name: String
        let attributes: [String: String]
        var children: [XMLNode] = []
        var text = ""

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }
    }

    private var stack: [Frame] = []
    private(set) var root: XMLNode?

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        var attributes: [String: String] = [:]
        attributes.reserveCapacity(attributeDict.count)
        for (key, value) in attributeDict {
            attributes[XMLNode.localName(key)] = value
        }
        stack.append(Frame(name: XMLNode.localName(elementName), attributes: attributes))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text.append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else { return }
        stack.last?.text.append(string)
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
    ) {
        guard let frame = stack.popLast() else { return }
        let node = XMLNode(
            name: frame.name,
            attributes: frame.attributes,
            children: frame.children,
            text: frame.text.trimmingCharacters(in: .whitespacesAndNewlines))
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
    }
}
