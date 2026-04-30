#if os(macOS)
import Foundation
import Network

/// Minimal loopback HTTP server that exposes the proxy-hover API.
///
/// Callers register a `(gatingFocusPid, targetPid)` pairing with a TTL (max
/// 150s). While the gating PID is the frontmost app, VibeGrid treats the
/// target window as if the user were hovering it in the Window List — hover
/// highlight, overlay, and Move Everything hotkeys all target it. The caller
/// must refresh before the TTL elapses for the state to persist.
final class ProxyHoverAPIServer {

    static let maxDurationSeconds: Double = 150
    static let minDurationSeconds: Double = 1

    struct SetPayload {
        var gatingFocusPid: pid_t
        var gatingFocusWindowNumber: Int?
        var gatingFocusITermWindowID: String?
        var targetPid: pid_t?
        var targetWindowNumber: Int?
        var targetITermWindowID: String?
        var targetITermTTY: String?
        var durationSeconds: Double
    }

    enum Command {
        case set(SetPayload)
        case clear(gatingFocusPid: pid_t)
        case clearAll
        case get
    }

    struct Response {
        var status: Int
        var body: [String: Any]
    }

    private let port: UInt16
    private let handler: (Command) -> Response
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "VibeGrid.ProxyHoverAPIServer")
    private(set) var isRunning = false

    init(port: UInt16, handler: @escaping (Command) -> Response) {
        self.port = port
        self.handler = handler
    }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            NSLog("VibeGrid proxy-hover API: invalid port %d", Int(port))
            return
        }
        do {
            let listener = try NWListener(using: params, on: nwPort)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.isRunning = true
                    NSLog("VibeGrid proxy-hover API listening on 127.0.0.1:%d", Int(self?.port ?? 0))
                case .failed(let error):
                    self?.isRunning = false
                    NSLog("VibeGrid proxy-hover API listener failed: %@", error.localizedDescription)
                case .cancelled:
                    self?.isRunning = false
                default:
                    break
                }
            }
            listener.start(queue: queue)
        } catch {
            NSLog("VibeGrid proxy-hover API failed to bind 127.0.0.1:%d — %@",
                  Int(port), error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, accumulated: Data())
    }

    private func receive(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                conn.cancel()
                return
            }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if let error {
                NSLog("VibeGrid proxy-hover API receive error: %@", error.localizedDescription)
                conn.cancel()
                return
            }
            switch self.parseRequest(buffer) {
            case .needMore:
                if isComplete {
                    self.respond(conn, response: Response(status: 400, body: ["error": "incomplete request"]))
                    return
                }
                self.receive(conn, accumulated: buffer)
            case .invalid(let msg):
                self.respond(conn, response: Response(status: 400, body: ["error": msg]))
            case .ok(let method, let path, let body):
                let response = self.route(method: method, path: path, body: body)
                self.respond(conn, response: response)
            }
        }
    }

    private enum ParseResult {
        case needMore
        case invalid(String)
        case ok(method: String, path: String, body: Data)
    }

    private func parseRequest(_ buffer: Data) -> ParseResult {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return .needMore
        }
        let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .invalid("non-UTF8 headers")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .invalid("missing request line")
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else {
            return .invalid("malformed request line")
        }
        let method = String(parts[0])
        let path = String(parts[1])

        var contentLength = 0
        for line in lines.dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<colonIndex].lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" { contentLength = Int(value) ?? 0 }
        }

        let bodyStart = headerEnd.upperBound
        if buffer.count - bodyStart < contentLength {
            return .needMore
        }
        let bodyEnd = bodyStart + contentLength
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        return .ok(method: method, path: path, body: body)
    }

    private func route(method: String, path: String, body: Data) -> Response {
        let normalizedPath = path.split(separator: "?").first.map(String.init) ?? path
        switch (method.uppercased(), normalizedPath) {
        case ("GET", "/proxy-hover"):
            return handler(.get)
        case ("POST", "/proxy-hover"):
            return parseSet(body: body)
        case ("DELETE", "/proxy-hover"):
            return parseDelete(body: body)
        default:
            return Response(status: 404, body: ["error": "not found", "path": normalizedPath])
        }
    }

    private func parseSet(body: Data) -> Response {
        guard !body.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return Response(status: 400, body: ["error": "invalid JSON body"])
        }
        guard let gatingRaw = (json["gatingFocusPid"] as? NSNumber)?.int32Value,
              let duration = (json["durationSeconds"] as? NSNumber)?.doubleValue else {
            return Response(status: 400, body: ["error": "missing gatingFocusPid or durationSeconds"])
        }
        guard gatingRaw > 0 else {
            return Response(status: 400, body: ["error": "gatingFocusPid must be positive"])
        }
        guard duration > 0 else {
            return Response(status: 400, body: ["error": "durationSeconds must be positive"])
        }
        let targetPidRaw = (json["targetPid"] as? NSNumber)?.int32Value
        let targetWindowNumber = (json["targetWindowNumber"] as? NSNumber)?.intValue
        let targetITermWindowID = nonEmptyString(json["targetITermWindowID"])
        let targetITermTTY = nonEmptyString(json["targetITermTTY"])
        guard targetPidRaw != nil || targetITermWindowID != nil || targetITermTTY != nil else {
            return Response(status: 400, body: [
                "error": "must set one of targetPid, targetITermWindowID, or targetITermTTY"
            ])
        }
        if let targetPidRaw, targetPidRaw <= 0 {
            return Response(status: 400, body: ["error": "targetPid must be positive"])
        }
        let payload = SetPayload(
            gatingFocusPid: pid_t(gatingRaw),
            gatingFocusWindowNumber: (json["gatingFocusWindowNumber"] as? NSNumber)?.intValue,
            gatingFocusITermWindowID: nonEmptyString(json["gatingFocusITermWindowID"]),
            targetPid: targetPidRaw.map { pid_t($0) },
            targetWindowNumber: targetWindowNumber,
            targetITermWindowID: targetITermWindowID,
            targetITermTTY: targetITermTTY,
            durationSeconds: duration
        )
        return handler(.set(payload))
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parseDelete(body: Data) -> Response {
        if body.isEmpty {
            return handler(.clearAll)
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return Response(status: 400, body: ["error": "invalid JSON body"])
        }
        guard let gatingRaw = (json["gatingFocusPid"] as? NSNumber)?.int32Value, gatingRaw > 0 else {
            return handler(.clearAll)
        }
        return handler(.clear(gatingFocusPid: pid_t(gatingRaw)))
    }

    private func respond(_ conn: NWConnection, response: Response) {
        let statusText: String
        switch response.status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "OK"
        }
        let body = (try? JSONSerialization.data(withJSONObject: response.body, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        var header = "HTTP/1.1 \(response.status) \(statusText)\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        conn.send(content: payload, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
#endif
