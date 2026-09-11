import Foundation
import Network

/// Tiny local HTTP listener. Claude Code hooks and the status line POST JSON here.
final class HookServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "clawdpet.hooks")
    let port: UInt16
    var onHook: (([String: Any]) -> Void)?
    var onStatus: (([String: Any]) -> Void)?
    private(set) var lastError: String?

    init(port: UInt16) throws {
        self.port = port
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: params)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] c in self?.handle(c) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state {
                self?.lastError = "\(e)"
                NSLog("ClawdPet: listener failed: \(e)")
            }
        }
        listener.start(queue: queue)
    }

    private func handle(_ c: NWConnection) {
        var buffer = Data()
        var headerEnd: Int?
        var contentLength = 0
        var requestLine = ""
        var sentContinue = false
        c.start(queue: queue)

        func receive() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
                if let d = data { buffer.append(d) }
                if headerEnd == nil, let r = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    headerEnd = r.upperBound
                    let head = String(decoding: buffer.subdata(in: 0..<r.lowerBound), as: UTF8.self)
                    let lines = head.components(separatedBy: "\r\n")
                    requestLine = lines.first ?? ""
                    for line in lines.dropFirst() {
                        let lower = line.lowercased()
                        if lower.hasPrefix("content-length:") {
                            contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
                        } else if lower.hasPrefix("expect:"), lower.contains("100-continue"), !sentContinue {
                            sentContinue = true
                            c.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                        }
                    }
                }
                if let he = headerEnd, buffer.count - he >= contentLength {
                    let body = buffer.subdata(in: he..<(he + contentLength))
                    self.finish(c, requestLine: requestLine, body: body)
                    return
                }
                if isComplete || error != nil { c.cancel(); return }
                receive()
            }
        }
        receive()
    }

    private func finish(_ c: NWConnection, requestLine: String, body: Data) {
        let parts = requestLine.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        let path = parts.count > 1 ? String(parts[1]) : "/"
        var reply = "ok"
        if method == "POST" {
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            if let json = json {
                DispatchQueue.main.async { [weak self] in
                    if path.hasPrefix("/status") { self?.onStatus?(json) } else { self?.onHook?(json) }
                }
            } else {
                reply = "bad json"
            }
        } else {
            reply = "clawd-pet listening on \(port)\n"
        }
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(reply.utf8.count)\r\nConnection: close\r\n\r\n\(reply)"
        c.send(content: Data(response.utf8), completion: .contentProcessed { _ in c.cancel() })
    }
}
