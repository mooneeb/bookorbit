import Foundation

/// HTTPS is assumed when no scheme is typed, as in `books.mooneeb.dev`.
public struct ServerAddress: Hashable, Sendable, Codable, CustomStringConvertible {
    public let baseURL: URL

    public init(_ input: String) throws(ServerAddressError) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .empty }
        if !text.contains("://") { text = "https://\(text)" }
        while text.hasSuffix("/") { text.removeLast() }

        guard let components = URLComponents(string: text),
            let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = components.host, !host.isEmpty,
            components.query == nil, components.fragment == nil,
            let url = components.url
        else { throw .invalid }
        baseURL = url
    }

    public var description: String { baseURL.absoluteString }
}

public enum ServerAddressError: Error, Equatable {
    case empty
    case invalid
}
