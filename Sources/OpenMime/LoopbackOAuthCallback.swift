import Foundation
import Network

final class LoopbackOAuthCallback: @unchecked Sendable {
    struct Response: Sendable {
        let code: String?
        let state: String?
        let error: String?
    }

    enum CallbackError: LocalizedError {
        case listenerFailed(String)
        case invalidRequest

        var errorDescription: String? {
            switch self {
            case .listenerFailed(let reason): "Could not start the local OAuth callback: \(reason)"
            case .invalidRequest: "The local OAuth callback received an invalid request."
            }
        }
    }

    private let queue = DispatchQueue(label: "org.openmime.oauth-loopback")
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var responseContinuation: CheckedContinuation<Response, Error>?
    private var pendingResponse: Result<Response, Error>?

    func start() async throws -> URL {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let port = listener.port,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth/callback")
                    else {
                        self?.resolveStart(.failure(CallbackError.listenerFailed("No local port was assigned.")))
                        return
                    }
                    self?.resolveStart(.success(url))
                case .failed(let error):
                    self?.finish(.failure(CallbackError.listenerFailed(error.localizedDescription)))
                    self?.resolveStart(.failure(CallbackError.listenerFailed(error.localizedDescription)))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.receive(connection)
            }
            listener.start(queue: queue)
        }
    }

    func waitForResponse() async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { return }
                if let pendingResponse {
                    self.pendingResponse = nil
                    continuation.resume(with: pendingResponse)
                } else {
                    responseContinuation = continuation
                }
            }
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(CallbackError.listenerFailed(error.localizedDescription)))
                connection.cancel()
                return
            }
            guard let data, let request = String(data: data, encoding: .utf8),
                  let firstLine = request.split(separator: "\r\n").first,
                  let path = firstLine.split(separator: " ").dropFirst().first,
                  let components = URLComponents(string: "http://127.0.0.1\(path)")
            else {
                self.finish(.failure(CallbackError.invalidRequest))
                connection.cancel()
                return
            }

            let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let response = Response(code: values["code"], state: values["state"], error: values["error"])
            let html = """
            <!doctype html><meta charset="utf-8"><title>OpenMime</title>
            <style>body{font:16px -apple-system;margin:48px;color:#222}h1{font-size:24px}</style>
            <h1>Sign-in complete</h1><p>You can close this tab and return to OpenMime.</p>
            """
            let http = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(http.utf8), completion: .contentProcessed { _ in connection.cancel() })
            self.finish(.success(response))
        }
    }

    private func finish(_ result: Result<Response, Error>) {
        listener?.cancel()
        listener = nil
        if let continuation = responseContinuation {
            responseContinuation = nil
            continuation.resume(with: result)
        } else {
            pendingResponse = result
        }
    }

    private func resolveStart(_ result: Result<URL, Error>) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume(with: result)
    }
}
