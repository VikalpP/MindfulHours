import Foundation
import Network

/// Receives one OAuth redirect on 127.0.0.1, which nothing outside this Mac can reach.
public final class LoopbackCallbackServer: @unchecked Sendable {
    public private(set) var port: UInt16 = 0
    private let path: String
    private let queue = DispatchQueue(label: "MindfulHours.LoopbackCallbackServer")
    private var listener: NWListener?
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    private init(path: String) {
        self.path = path
    }

    /// Falls back to any free port when `preferredPort` is taken.
    public static func start(path: String, preferredPort: UInt16? = nil) async throws -> LoopbackCallbackServer {
        let server = LoopbackCallbackServer(path: path)
        if let preferredPort, let listener = try? await server.listen(on: NWEndpoint.Port(rawValue: preferredPort)!) {
            server.listener = listener
        } else {
            server.listener = try await server.listen(on: .any)
        }
        server.port = server.listener?.port?.rawValue ?? 0
        return server
    }

    public func redirectURI(host: String = "127.0.0.1") -> URL {
        URL(string: "http://\(host):\(port)\(path)")!
    }

    /// The redirect's query items. Cancelling the task stops waiting.
    public func callback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result {
                        continuation.resume(with: result)
                    } else {
                        self.waiter = continuation
                    }
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    public func stop() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private func listen(on port: NWEndpoint.Port) async throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    listener.stateUpdateHandler = nil
                    listener.cancel()
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return listener
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return connection.cancel() }
            let requestLine = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
            let target = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let components = URLComponents(string: "http://127.0.0.1\(target)")

            guard components?.path == path, result == nil else {
                return respond(connection, status: "404 Not Found", message: "Not found.")
            }
            let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            respond(connection, status: "200 OK", message: "You're signed in. You can close this tab and return to MindfulHours.")
            finish(.success(query))
        }
    }

    private func respond(_ connection: NWConnection, status: String, message: String) {
        let html = "<!doctype html><meta charset=utf-8><title>MindfulHours</title><body style=\"font:16px -apple-system;margin:3em\">\(message)"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ outcome: Result<[String: String], Error>) {
        guard result == nil else { return }
        result = outcome
        waiter?.resume(with: outcome)
        waiter = nil
        // Let the browser's response go out before the listener closes.
        queue.asyncAfter(deadline: .now() + 1) { self.listener?.cancel() }
    }
}
