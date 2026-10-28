import Foundation
import CryptoKit

struct ServerIdentity: Codable, Equatable, Sendable {
    let product: String
    let protocolVersion: Int
    let instanceId: UUID
}
struct Account: Codable, Sendable {
    let id: Int
    let username: String
    let permissions: [String]
}
struct Credentials: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let user: Account?
}
struct BookFile: Codable, Identifiable, Sendable {
    let id: Int
    let format: String?
    let role: String
}
struct Book: Codable, Identifiable, Sendable {
    let id: Int
    let title: String?
    let files: [BookFile]
}
struct BookPage: Codable, Sendable {
    let items: [Book]
}
struct Publication: Codable, Sendable, Identifiable {
    struct Member: Codable, Sendable {
        let path: String
        let bytes: Int
        let sha256: String
    }
    let version: Int
    let id: UUID
    let bookId: Int
    let fileId: Int
    let sourceSha256: String
    let sourceBytes: Int
    let expiresAt: String
    let members: [Member]
}
enum ReaderFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor Transport {
    nonisolated let origin: URL
    private let session: URLSession
    private var token: String?
    private var credentials: Credentials?
    private var scope: SessionReference?
    private var refreshTask: Task<Credentials, Error>?
    private var closed = false
    private var downloads: [UUID: URLSession] = [:]

    init(server: String, configuration: URLSessionConfiguration = .ephemeral) throws {
        guard let url = URL(string: server), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw ReaderFailure.message("Enter an HTTPS server origin without a path or credentials.")
        }
        origin = url
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 130
        configuration.timeoutIntervalForResource = 130
        session = URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }

    func authorize(_ credentials: Credentials, scope: SessionReference? = nil) {
        self.credentials = credentials
        token = credentials.accessToken
        if let scope { self.scope = scope }
    }

    func invalidate() {
        closed = true
        refreshTask?.cancel()
        session.invalidateAndCancel()
        for download in downloads.values { download.invalidateAndCancel() }
        downloads.removeAll()
    }

    private func renew(rejected: String?) async throws {
        guard !closed, let stored = credentials, let scope else { throw ReaderFailure.message("Sign in again to reconnect.") }
        if token != rejected { return }
        let flight: Task<Credentials, Error>
        if let refreshTask { flight = refreshTask }
        else {
            flight = Task { try await self.refresh(stored) }
            refreshTask = flight
        }
        do {
            let renewed = try await flight.value
            guard !closed else { throw CancellationError() }
            if token == rejected {
                try CredentialStore().save(renewed, scope: scope)
                credentials = renewed
                token = renewed.accessToken
            }
            refreshTask = nil
        } catch { refreshTask = nil; throw error }
    }

    private func serverRequest(_ path: String, method: String, body: Data?) throws -> URLRequest {
        guard !closed else { throw CancellationError() }
        guard path.hasPrefix("/api/v1/"), !path.contains(".."), let url = URL(string: path, relativeTo: origin)?.absoluteURL,
              url.host == origin.host, url.port == origin.port, url.scheme == origin.scheme else {
            throw ReaderFailure.message("Invalid server request.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func responseBytes(_ path: String, method: String, body: Data?, limit: Int, retry: Bool = true) async throws -> URLSession.AsyncBytes {
        let rejected = token
        let request = try serverRequest(path, method: method, body: body)
        let (stream, response) = try await session.bytes(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401, retry, !path.hasPrefix("/api/v1/auth/") {
            try await renew(rejected: rejected)
            return try await responseBytes(path, method: method, body: body, limit: limit, retry: false)
        }
        guard let response = response as? HTTPURLResponse else { throw ReaderFailure.message("Invalid response.") }
        guard (200..<300).contains(response.statusCode) else {
            throw ReaderFailure.message(response.statusCode == 401 ? "Session expired. Sign out and reconnect." :
                response.statusCode == 403 ? "This account cannot access this book." : "Server request failed (\(response.statusCode)).")
        }
        guard response.expectedContentLength <= limit else { throw ReaderFailure.message("Response exceeds the reader limit.") }
        return stream
    }

    func request(_ path: String, method: String = "GET", body: Data? = nil, limit: Int = 4 * 1024 * 1024) async throws -> Data {
        let stream = try await responseBytes(path, method: method, body: body, limit: limit)
        var data = Data()
        for try await byte in stream {
            if data.count >= limit { throw ReaderFailure.message("Response exceeds the reader limit.") }
            data.append(byte)
        }
        return data
    }

    func identity() async throws -> ServerIdentity {
        let value = try JSONDecoder().decode(ServerIdentity.self, from: await request("/api/v1/server-identity", limit: 4096))
        guard value.product == "bookorbit", value.protocolVersion == 1 else { throw ReaderFailure.message("This server is incompatible.") }
        return value
    }

    func login(username: String, password: String) async throws -> Credentials {
        let body = try JSONSerialization.data(withJSONObject: ["username": username, "password": password,
            "clientKind": "native", "deviceLabel": "BookOrbit iPad"])
        return try JSONDecoder().decode(Credentials.self, from: await request("/api/v1/auth/login", method: "POST", body: body))
    }

    func refresh(_ credentials: Credentials) async throws -> Credentials {
        let body = try JSONSerialization.data(withJSONObject: ["refreshToken": credentials.refreshToken])
        return try JSONDecoder().decode(Credentials.self, from: await request("/api/v1/auth/refresh", method: "POST", body: body))
    }

    func account() async throws -> Account {
        try JSONDecoder().decode(Account.self, from: await request("/api/v1/auth/me"))
    }

    func books(query: String, page: Int) async throws -> [Book] {
        let body = try JSONSerialization.data(withJSONObject: ["q": String(query.prefix(200)),
            "sort": [["field": "title", "dir": "asc"]], "pagination": ["page": page, "size": 50]])
        return try JSONDecoder().decode(BookPage.self, from: await request("/api/v1/books/query", method: "POST", body: body)).items
    }

    func detail(_ id: Int) async throws -> Book {
        try JSONDecoder().decode(Book.self, from: await request("/api/v1/books/\(id)"))
    }

    func open(book: Int, file: Int) async throws -> Publication {
        let result = try JSONDecoder().decode(Publication.self, from: await request("/api/v1/epub-sessions/books/\(book)/files/\(file)", method: "POST", limit: 256 * 1024))
        guard result.version == 1, result.bookId == book, result.fileId == file,
              result.sourceBytes >= 22, result.sourceBytes <= 512 * 1024 * 1024, result.members.count <= 20_000,
              result.sourceSha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw ReaderFailure.message("Unsupported publication manifest.")
        }
        var names = Set<String>()
        var expanded = 0
        for member in result.members {
            guard member.bytes >= 0, member.bytes <= 32 * 1024 * 1024, member.path.utf8.count <= 1024,
                  !member.path.hasPrefix("/"), !member.path.contains("\\"),
                  !member.path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  names.insert(member.path).inserted, member.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                throw ReaderFailure.message("Invalid publication member.")
            }
            expanded += member.bytes
            guard expanded <= 2 * 1024 * 1024 * 1024 else { throw ReaderFailure.message("Publication is too large.") }
        }
        do { try await verifyOriginal(result) }
        catch { await close(result); throw error }
        return result
    }

    private func verifyOriginal(_ publication: Publication, retry: Bool = true) async throws {
        let configuration = session.configuration
        configuration.timeoutIntervalForResource = max(130, Double(publication.sourceBytes) / (64 * 1024) + 120)
        let downloadSession = URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
        let keepAlive = Task {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(60))
                    try await self.heartbeat(publication)
                }
            } catch is CancellationError {} catch { downloadSession.invalidateAndCancel() }
        }
        defer { keepAlive.cancel(); downloadSession.invalidateAndCancel() }
        let downloadID = UUID()
        downloads[downloadID] = downloadSession
        defer { downloads.removeValue(forKey: downloadID) }
        let rejected = token
        let request = try serverRequest("/api/v1/epub-sessions/\(publication.id.uuidString)/original", method: "GET", body: nil)
        let (file, response) = try await downloadSession.download(for: request, delegate: OriginalDownloadGuard(limit: publication.sourceBytes))
        defer { try? FileManager.default.removeItem(at: file) }
        if (response as? HTTPURLResponse)?.statusCode == 401, retry {
            try await renew(rejected: rejected)
            return try await verifyOriginal(publication, retry: false)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ReaderFailure.message("Original EPUB download failed.") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        var count = 0
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            count += data.count
            guard count <= publication.sourceBytes else { throw ReaderFailure.message("Original EPUB size mismatch.") }
            hash.update(data: data)
        }
        guard count == publication.sourceBytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == publication.sourceSha256 else {
            throw ReaderFailure.message("Original EPUB verification failed.")
        }
    }

    func heartbeat(_ publication: Publication) async throws {
        _ = try await request("/api/v1/epub-sessions/\(publication.id.uuidString)/heartbeat", method: "POST")
    }

    func close(_ publication: Publication) async {
        _ = try? await request("/api/v1/epub-sessions/\(publication.id.uuidString)", method: "DELETE")
    }
}

final class OriginalDownloadGuard: NSObject, URLSessionDownloadDelegate, Sendable {
    let limit: Int
    init(limit: Int) { self.limit = limit }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
