import SwiftUI

@main
struct BookOrbitQAApp: App {
    @State private var library: LibraryModel

    init() {
        let library = LibraryModel { origin in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [IsolatedQAProtocol.self]
            return try Transport(server: origin, configuration: configuration)
        }
        library.server = "https://bookorbit-qa.test"
        _library = State(initialValue: library)
    }

    var body: some Scene {
        WindowGroup { LibraryScreen(library: library).task { await library.restore() } }
    }
}

final class IsolatedQAProtocol: URLProtocol, @unchecked Sendable {
    private var forwardedTask: URLSessionDataTask?

    override class func canInit(with request: URLRequest) -> Bool {
        ["http", "https"].contains(request.url?.scheme ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard request.url?.scheme == "https", request.url?.host == "bookorbit-qa.test",
              var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        url.scheme = "http"
        url.host = "127.0.0.1"
        url.port = 55458
        var forwarded = request
        forwarded.url = url.url
        forwardedTask = URLSession.shared.dataTask(with: forwarded) { data, response, error in
            if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
            guard let http = response as? HTTPURLResponse, let data,
                  let response = HTTPURLResponse(url: self.request.url!, statusCode: http.statusCode, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(data.count)]) else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        forwardedTask?.resume()
    }

    override func stopLoading() { forwardedTask?.cancel() }
}
