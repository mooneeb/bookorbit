import Foundation
import Network

final class ReflowServer: @unchecked Sendable {
  private var listener: NWListener?
  private let root = Bundle.main.resourceURL!

  func start(ready: @escaping @Sendable (UInt16) -> Void) throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    self.listener = listener
    listener.stateUpdateHandler = { [weak listener] state in
      if case .ready = state, let port = listener?.port { ready(port.rawValue) }
    }
    listener.newConnectionHandler = { [weak self] connection in
      guard let root = self?.root else {
        connection.cancel()
        return
      }
      connection.start(queue: .main)
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
        guard let data,
          let request = String(data: data, encoding: .utf8),
          let target = request.components(separatedBy: "\r\n").first?.split(separator: " ")
            .dropFirst().first,
          let path = String(target).components(separatedBy: "?").first?.removingPercentEncoding
        else {
          connection.cancel()
          return
        }
        let url = root.appending(path: path).standardizedFileURL
        let allowed = ["Fixtures/Reflow/", "foliate/"].contains {
          url.path.hasPrefix(root.appending(path: $0).path + "/")
        }
        let payload = allowed ? try? Data(contentsOf: url) : nil
        let types = [
          "html": "text/html", "js": "text/javascript", "css": "text/css",
          "epub": "application/epub+zip", "json": "application/json", "svg": "image/svg+xml",
        ]
        let body = payload ?? Data("Not found".utf8)
        let status = payload == nil ? "404 Not Found" : "200 OK"
        let header =
          "HTTP/1.1 \(status)\r\nContent-Type: \(types[url.pathExtension] ?? "application/octet-stream")\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(
          content: Data(header.utf8) + body,
          completion: .contentProcessed { _ in connection.cancel() })
      }
    }
    listener.start(queue: .main)
  }

  func stop() {
    listener?.stateUpdateHandler = nil
    listener?.newConnectionHandler = nil
    listener?.cancel()
    listener = nil
  }
}
