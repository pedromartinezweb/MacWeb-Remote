import Foundation
import Network
import Security

struct Request {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
}
struct Response {
    var status = 200
    var type = "application/json"
    var body = Data()
    var headers: [String: String] = [:]
    var stream = false
    var expiresAt = Date.distantFuture
    static func json(_ value: [String: Any], status: Int = 200) -> Response {
        Response(status: status, body: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data())
    }
}
final class HTTPServer {
    let frames: FrameStore
    var handler: ((Request, @escaping (Response) -> Void) -> Void)?
    var stateChanged: ((String) -> Void)?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "local.macweb.network")
    private var peers: [UUID: HTTPPeer] = [:]
    init(frames: FrameStore) { self.frames = frames }
    func start(address: String, port: UInt16, p12: Data, password: String) throws {
        guard let listenAddress = IPv4Address(address), port > 0 else { throw NSError(domain: "Network", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid address or port."]) }
        var imported: CFArray?
        let result = SecPKCS12Import(p12 as CFData, [kSecImportExportPassphrase as String: password, kSecImportToMemoryOnly as String: true] as CFDictionary, &imported)
        guard result == errSecSuccess, let items = imported as? [[String: Any]], let value = items.first?[kSecImportItemIdentity as String] else {
            throw NSError(domain: "TLS", code: Int(result), userInfo: [NSLocalizedDescriptionKey:"Could not load the HTTPS certificate."])
        }
        let identity = value as! SecIdentity
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(listenAddress), port: NWEndpoint.Port(rawValue: port)!)
        let next = try NWListener(using: parameters)
        next.newConnectionHandler = { [weak self] connection in
            guard let self, self.peers.count < 16 else { connection.cancel(); return }
            let peer = HTTPPeer(connection: connection, queue: self.queue, frames: self.frames)
            self.peers[peer.id] = peer
            let peerID = peer.id
            peer.onEnd = { [weak self] in self?.peers.removeValue(forKey: peerID) }
            peer.handle = { [weak self] request, reply in
                DispatchQueue.main.async {
                    guard let handler = self?.handler else { reply(.json(["error":"Unavailable"], status:503)); return }
                    handler(request, reply)
                }
            }
            peer.start()
        }
        next.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                DispatchQueue.main.async { self?.stateChanged?(error.localizedDescription) }
            }
        }
        next.start(queue: queue)
        listener = next
    }
    func closeStreams() {
        queue.async { Array(self.peers.values).filter { $0.isStreaming }.forEach { $0.end() } }
    }
    func stop() {
        listener?.cancel()
        queue.async { Array(self.peers.values).forEach { $0.end() }; self.peers.removeAll() }
    }
}
private final class HTTPPeer {
    let id = UUID()
    var handle: ((Request, @escaping (Response) -> Void) -> Void)?
    var onEnd: (() -> Void)?
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let frames: FrameStore
    private var buffer = Data()
    private var ended = false
    private var streaming = false
    var isStreaming: Bool { streaming }
    private var expiresAt = Date.distantFuture
    private var responding = false
    private var keepAlive = false
    private var requestGeneration: UInt64 = 0
    private var revision: UInt64 = 0
    init(connection: NWConnection, queue: DispatchQueue, frames: FrameStore) {
        self.connection = connection; self.queue = queue; self.frames = frames
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.beginRequest()
            case .failed, .cancelled: self.end()
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.requestGeneration == 0 else { return }
            self.end()
        }
    }
    private func beginRequest() {
        guard !ended else { return }
        requestGeneration &+= 1
        let generation = requestGeneration
        responding = false
        keepAlive = false
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.requestGeneration == generation, !self.streaming else { return }
            self.end()
        }
        if !parse() { read() }
    }
    func end() {
        guard !ended else { return }
        ended = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        let callback = onEnd; onEnd = nil; handle = nil
        callback?()
    }
    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self, !self.ended else { return }
            if let data { self.buffer.append(data) }
            if self.buffer.count > 65536 { self.respond(.json(["error":"Request too large"], status:413)); return }
            if self.parse() { return }
            if complete || error != nil { self.end() } else { self.read() }
        }
    }
    private func parse() -> Bool {
        guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else { return false }
        guard split.lowerBound <= 8192, let text = String(data: buffer[..<split.lowerBound], encoding: .utf8) else { respond(.json(["error":"Invalid header"], status:400)); return true }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3, ["HTTP/1.1", "HTTP/1.0"].contains(String(requestLine[2])) else { respond(.json(["error":"Invalid request"], status:400)); return true }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { respond(.json(["error":"Invalid header"], status:400)); return true }
            let name = line[..<colon].lowercased()
            guard headers[name] == nil else { respond(.json(["error":"Duplicate header"], status:400)); return true }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { respond(.json(["error":"Transfer encoding is not supported"], status:400)); return true }
        let length: Int
        if let declared = headers["content-length"] {
            guard let count = Int(declared), count >= 0, count <= 49152 else { respond(.json(["error":"Invalid length"], status:413)); return true }
            length = count
        } else { length = 0 }
        guard buffer.count - split.upperBound >= length else { return false }
        let request = Request(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: buffer.subdata(in: split.upperBound..<(split.upperBound + length)))
        buffer.removeSubrange(..<(split.upperBound + length))
        let connectionTokens = (headers["connection"] ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        keepAlive = requestLine[2] == "HTTP/1.1" && !connectionTokens.contains("close")
        handle?(request) { [weak self] response in
            guard let self else { return }
            self.queue.async { self.respond(response) }
        }
        return true
    }
    private func respond(_ response: Response) {
        guard !ended, !responding else { return }
        responding = true
        var header = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\nContent-Type: \(response.type)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\n"
        for (name, value) in response.headers { header += "\(name): \(value)\r\n" }
        if response.stream {
            streaming = true
            expiresAt = response.expiresAt
            header += "Connection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { self.end() } else { self.sendFrame() }
            })
        } else {
            if response.status != 204 { header += "Content-Length: \(response.body.count)\r\n" }
            header += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
            let body = response.status == 204 ? Data() : response.body
            connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil || !self.keepAlive { self.end() }
                else { self.beginRequest() }
            })
        }
    }
    private func sendFrame() {
        guard !ended else { return }
        guard expiresAt > Date() else { end(); return }
        let (frame, serial, _) = frames.read()
        guard !frame.isEmpty, serial != revision else {
            queue.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.sendFrame() }; return
        }
        revision = serial
        let part = Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(frame.count)\r\n\r\n".utf8) + frame + Data("\r\n".utf8)
        connection.send(content: part, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { self.end(); return }
            self.queue.asyncAfter(deadline: .now() + 0.065) { [weak self] in self?.sendFrame() }
        })
    }
    private static func reason(_ code: Int) -> String {
        [200:"OK", 204:"No Content", 400:"Bad Request", 401:"Unauthorized", 403:"Forbidden", 404:"Not Found", 409:"Conflict", 413:"Payload Too Large", 429:"Too Many Requests", 500:"Internal Server Error", 503:"Service Unavailable"][code] ?? "Error"
    }
}
