import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

public enum BookOrbitClient {
    /// Builds a generated API client for one server. `serverURL` is the server's base address; the
    /// generated paths already include the `/api/v1` prefix.
    public static func make(
        serverURL: URL,
        session: URLSession,
        middlewares: [any ClientMiddleware] = []
    ) -> Client {
        Client(
            serverURL: serverURL,
            // The server serializes dates with JavaScript's toISOString, which always has milliseconds.
            configuration: Configuration(dateTranscoder: .iso8601WithFractionalSeconds),
            transport: URLSessionTransport(configuration: .init(session: session)),
            middlewares: middlewares
        )
    }
}
