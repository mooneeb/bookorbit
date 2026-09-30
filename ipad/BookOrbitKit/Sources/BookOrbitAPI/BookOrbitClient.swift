import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

public enum BookOrbitClient {
    /// `serverURL` is the server's base address: the generated paths already include `/api/v1`.
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
