import Foundation

private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    let origin = task.originalRequest?.url
    let target = request.url
    let matches =
      origin?.scheme == target?.scheme && origin?.host == target?.host
      && origin?.port == target?.port
    completionHandler(matches ? request : nil)
  }
}

actor BookOrbitAPI {
  let profile: ServerProfile
  private let transport: URLSession
  private let store: CredentialStore
  private var saved: SavedSession?
  private var refreshTask: (id: UUID, task: Task<NativeCredentials, Error>)?
  private var sessionGeneration = UUID()

  init(profile: ServerProfile) throws {
    self.profile = profile
    store = CredentialStore(account: profile.url.absoluteString)
    saved = try store.read()
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.httpCookieStorage = nil
    config.timeoutIntervalForRequest = 20
    transport = URLSession(
      configuration: config, delegate: SameOriginRedirects(), delegateQueue: nil)
  }

  func loginOptions() async throws -> LoginOptionsResponse {
    try await send("auth/login-options", authenticated: false)
  }

  func login(username: String, password: String) async throws -> AuthUser {
    let body = LoginRequest(
      username: username, password: password, clientKind: "native",
      deviceLabel: "BookOrbit private iPad")
    let response: NativeAuthResponse = try await send(
      "auth/login", method: "POST", body: JSONEncoder().encode(body), authenticated: false)
    return try accept(response)
  }

  func oidcState(slug: String) async throws -> OidcStateResponse {
    try await send(
      "auth/oidc/\(slug)/state", method: "POST", body: Data("{}".utf8), authenticated: false)
  }

  func completeOIDC(_ callback: OidcCallbackRequest) async throws -> AuthUser {
    let response: NativeAuthResponse = try await send(
      "auth/oidc/callback", method: "POST", body: JSONEncoder().encode(callback),
      authenticated: false)
    return try accept(response)
  }

  private func accept(_ response: NativeAuthResponse) throws -> AuthUser {
    let session = SavedSession(
      credentials: NativeCredentials(
        accessToken: response.accessToken, accessTokenExpiresAt: response.accessTokenExpiresAt,
        refreshToken: response.refreshToken, refreshTokenExpiresAt: response.refreshTokenExpiresAt,
        sessionId: response.sessionId), user: response.user)
    try store.write(session)
    sessionGeneration = UUID()
    refreshTask?.task.cancel()
    refreshTask = nil
    saved = session
    return response.user
  }

  func resume() async throws -> AuthUser? {
    guard saved != nil else { return nil }
    let generation = sessionGeneration
    do {
      let user: AuthUser = try await send("auth/me")
      guard generation == sessionGeneration, var session = saved else {
        throw ConnectionError.expiredSession
      }
      session.user = user
      try store.write(session)
      saved = session
      return user
    } catch ConnectionError.expiredSession {
      if generation == sessionGeneration { try invalidateSession() }
      throw ConnectionError.expiredSession
    }
  }

  func logout() async throws {
    guard let saved else { return }
    let body = try JSONEncoder().encode(
      RefreshRequest(refreshToken: saved.credentials.refreshToken))
    let (_, response) = try await raw("auth/logout", method: "POST", body: body)
    try validate(response)
    try invalidateSession()
  }

  func changePassword(current: String, new: String) async throws {
    let body = try JSONEncoder().encode(
      ChangePasswordRequest(currentPassword: current, newPassword: new))
    let (_, response) = try await raw(
      "auth/change-password", method: "POST", body: body, token: accessToken())
    try validate(response)
    try invalidateSession()
  }

  private func invalidateSession() throws {
    try store.remove()
    sessionGeneration = UUID()
    refreshTask?.task.cancel()
    refreshTask = nil
    saved = nil
  }

  func send<T: Decodable & Sendable>(
    _ path: String, method: String = "GET", body: Data? = nil,
    query: [URLQueryItem] = [],
    authenticated: Bool = true
  ) async throws -> T {
    let token = authenticated ? try await accessToken() : nil
    var (data, response) = try await raw(
      path, method: method, body: body, query: query, token: token)
    if response.statusCode == 401 && authenticated {
      let credentials = try await refresh()
      (data, response) = try await raw(
        path, method: method, body: body, query: query, token: credentials.accessToken)
      if response.statusCode == 401 { throw ConnectionError.expiredSession }
    }
    try validate(response)
    do { return try JSONDecoder().decode(T.self, from: data) } catch {
      throw ConnectionError.invalidResponse
    }
  }

  func boundedJSON<T: Decodable & Sendable>(
    _ path: String, method: String = "GET", query: [URLQueryItem] = [],
    byteLimit: Int = 1024 * 1024
  ) async throws -> T {
    let generation = sessionGeneration
    var request = URLRequest(url: profile.endpoint(path, query: query))
    request.httpMethod = method
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
    try ensureSession(generation)
    var delivery = try await transport.bytes(for: request)
    if (delivery.1 as? HTTPURLResponse)?.statusCode == 401 {
      delivery.0.task.cancel()
      let credentials = try await refresh()
      try ensureSession(generation)
      request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
      delivery = try await transport.bytes(for: request)
    }
    let (bytes, response) = delivery
    defer { bytes.task.cancel() }
    guard let response = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
    if response.statusCode == 401 { throw ConnectionError.expiredSession }
    try validate(response)
    guard response.mimeType == "application/json" else { throw ConnectionError.invalidResponse }
    guard byteLimit > 0, response.expectedContentLength <= byteLimit else {
      throw ConnectionError.responseTooLarge
    }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      try ensureSession(generation)
      guard data.count < byteLimit else { throw ConnectionError.responseTooLarge }
      data.append(byte)
    }
    try Task.checkCancellation()
    try ensureSession(generation)
    do { return try JSONDecoder().decode(T.self, from: data) } catch {
      throw ConnectionError.invalidResponse
    }
  }

  func sendEmpty(
    _ path: String, method: String = "POST", body: Data? = nil, query: [URLQueryItem] = []
  ) async throws {
    let generation = sessionGeneration
    let token = try await accessToken()
    try ensureSession(generation)
    var (_, response) = try await raw(path, method: method, body: body, query: query, token: token)
    try ensureSession(generation)
    if response.statusCode == 401 {
      let credentials = try await refresh()
      try ensureSession(generation)
      (_, response) = try await raw(
        path, method: method, body: body, query: query, token: credentials.accessToken)
      try ensureSession(generation)
      if response.statusCode == 401 { throw ConnectionError.expiredSession }
    }
    try validate(response)
  }

  func uploadCover(bookID: Int, medium: CoverMedium, selection: StagedCoverImage) async throws {
    let generation = sessionGeneration
    let token = try await accessToken()
    try ensureSession(generation)
    let body = try coverUploadBody(selection.file, contentType: selection.contentType)
    defer { try? FileManager.default.removeItem(at: body.file) }
    var request = URLRequest(
      url: profile.endpoint(
        "books/\(bookID)/cover", query: [URLQueryItem(name: "medium", value: medium.rawValue)]))
    request.httpMethod = "POST"
    request.setValue(
      "multipart/form-data; boundary=\(body.boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue(String(body.length), forHTTPHeaderField: "Content-Length")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    var result = try await transport.upload(for: request, fromFile: body.file)
    try ensureSession(generation)
    if (result.1 as? HTTPURLResponse)?.statusCode == 401 {
      let credentials = try await refresh()
      try ensureSession(generation)
      request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
      result = try await transport.upload(for: request, fromFile: body.file)
      try ensureSession(generation)
    }
    try Task.checkCancellation()
    guard let response = result.1 as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
    if response.statusCode == 401 { throw ConnectionError.expiredSession }
    try validate(response)
    guard response.statusCode == 204 else { throw ConnectionError.invalidResponse }
  }

  private func coverUploadBody(_ image: URL, contentType: String) throws -> (
    file: URL, boundary: String, length: Int64
  ) {
    let size = try image.resourceValues(forKeys: [.fileSizeKey]).fileSize
    guard let size, size > 0, size <= CoverImageImport.byteLimit else {
      throw CoverImageError.tooLarge
    }
    let boundary = "BookOrbit-\(UUID().uuidString)"
    let header = Data(
      "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"cover\"\r\nContent-Type: \(contentType)\r\n\r\n"
        .utf8)
    let footer = Data("\r\n--\(boundary)--\r\n".utf8)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cover-upload-\(UUID().uuidString).multipart")
    guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
      throw ConnectionError.insufficientStorage
    }
    var completed = false
    defer { if !completed { try? FileManager.default.removeItem(at: file) } }
    let input = try FileHandle(forReadingFrom: image)
    defer { try? input.close() }
    let output = try FileHandle(forWritingTo: file)
    defer { try? output.close() }
    try output.write(contentsOf: header)
    var received = 0
    while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
      try Task.checkCancellation()
      received += chunk.count
      guard received <= size else { throw CoverImageError.tooLarge }
      try output.write(contentsOf: chunk)
    }
    guard received == size else { throw CoverImageError.invalidImage }
    try output.write(contentsOf: footer)
    completed = true
    return (file, boundary, Int64(header.count + received + footer.count))
  }

  func coverImage(bookID: Int, medium: CoverMedium, version: String) async throws -> Data {
    try await authenticatedImage(
      path: "books/\(bookID)/cover",
      query: [
        URLQueryItem(name: "medium", value: medium.rawValue),
        URLQueryItem(name: "strict", value: "true"),
        URLQueryItem(name: "t", value: version),
      ])
  }

  func remoteCoverPreview(url: String) async throws -> Data {
    try await authenticatedImage(
      path: "books/cover/proxy", query: [URLQueryItem(name: "url", value: url)])
  }

  func imageNamespace() throws -> String {
    guard let saved else { throw ConnectionError.expiredSession }
    return "\(profile.url.absoluteString).user.\(saved.user.id).session.\(sessionGeneration)"
  }

  func storageNamespace() throws -> String {
    guard let saved else { throw ConnectionError.expiredSession }
    return "\(profile.url.absoluteString).user.\(saved.user.id)"
  }

  private func authenticatedImage(path: String, query: [URLQueryItem]) async throws -> Data {
    let generation = sessionGeneration
    var request = URLRequest(url: profile.endpoint(path, query: query))
    request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
    try ensureSession(generation)
    var delivery = try await transport.bytes(for: request)
    if (delivery.1 as? HTTPURLResponse)?.statusCode == 401 {
      delivery.0.task.cancel()
      let credentials = try await refresh()
      try ensureSession(generation)
      request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
      delivery = try await transport.bytes(for: request)
    }
    let (bytes, response) = delivery
    defer { bytes.task.cancel() }
    try ensureSession(generation)
    guard let response = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
    if response.statusCode == 401 { throw ConnectionError.expiredSession }
    try validate(response)
    guard response.mimeType?.hasPrefix("image/") == true else { throw CoverImageError.invalidImage }
    guard response.expectedContentLength <= CoverImageImport.byteLimit else {
      throw CoverImageError.tooLarge
    }
    var data = Data()
    for try await byte in bytes {
      guard data.count < CoverImageImport.byteLimit else { throw CoverImageError.tooLarge }
      data.append(byte)
      if data.count % (64 * 1024) == 0 {
        try Task.checkCancellation()
        try ensureSession(generation)
      }
    }
    try Task.checkCancellation()
    try ensureSession(generation)
    return data
  }

  func comicPage(fileID: Int, pageIndex: Int) async throws -> Data {
    guard pageIndex >= 0 else { throw ConnectionError.invalidResponse }
    let limit = 20 * 1024 * 1024
    let generation = sessionGeneration
    var request = URLRequest(url: profile.endpoint("cbz/files/\(fileID)/pages/\(pageIndex)"))
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
    try ensureSession(generation)
    var delivery = try await transport.bytes(for: request)
    if (delivery.1 as? HTTPURLResponse)?.statusCode == 401 {
      delivery.0.task.cancel()
      let credentials = try await refresh()
      try ensureSession(generation)
      request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
      delivery = try await transport.bytes(for: request)
    }
    let (bytes, response) = delivery
    defer { bytes.task.cancel() }
    try ensureSession(generation)
    guard let response = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
    if response.statusCode == 401 { throw ConnectionError.expiredSession }
    try validate(response)
    guard response.mimeType?.hasPrefix("image/") == true else {
      throw ConnectionError.invalidResponse
    }
    guard response.expectedContentLength <= limit else { throw ConnectionError.comicPageTooLarge }
    var data = Data()
    for try await byte in bytes {
      guard data.count < limit else { throw ConnectionError.comicPageTooLarge }
      data.append(byte)
      if data.count % (64 * 1024) == 0 {
        try Task.checkCancellation()
        try ensureSession(generation)
      }
    }
    try Task.checkCancellation()
    try ensureSession(generation)
    if response.expectedContentLength >= 0 && Int64(data.count) != response.expectedContentLength {
      throw ConnectionError.fileChanged
    }
    return data
  }

  func streamMetadata(
    query: [URLQueryItem],
    receive: @MainActor @Sendable (MetadataSearchEvent) -> Void
  ) async throws {
    let generation = sessionGeneration
    var request = URLRequest(url: profile.endpoint("metadata-fetch/stream", query: query))
    request.timeoutInterval = 120
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
    try ensureSession(generation)
    var delivery = try await transport.bytes(for: request)
    if (delivery.1 as? HTTPURLResponse)?.statusCode == 401 {
      delivery.0.task.cancel()
      let credentials = try await refresh()
      try ensureSession(generation)
      request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
      delivery = try await transport.bytes(for: request)
    }
    let (bytes, response) = delivery
    defer { bytes.task.cancel() }
    guard let response = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
    if response.statusCode == 401 { throw ConnectionError.expiredSession }
    try validate(response)
    guard response.mimeType == "text/event-stream" else { throw ConnectionError.invalidResponse }
    var line = Data()
    var event = ""
    var data = Data()
    var total = 0
    var candidateCount = 0
    for try await byte in bytes {
      total += 1
      guard total <= 4 * 1024 * 1024, line.count <= 512 * 1024,
        data.count <= 512 * 1024
      else { throw MetadataSearchError.limit }
      if byte != 10 {
        line.append(byte)
        continue
      }
      try Task.checkCancellation()
      try ensureSession(generation)
      guard var text = String(data: line, encoding: .utf8) else {
        throw ConnectionError.invalidResponse
      }
      line.removeAll(keepingCapacity: true)
      if text.hasSuffix("\r") { text.removeLast() }
      if text.isEmpty {
        if !data.isEmpty {
          if data.last == 10 { data.removeLast() }
          if event == MetadataVocabulary.statusEvent {
            await receive(
              .status(try JSONDecoder().decode(MetadataProviderSearchStatus.self, from: data)))
          } else if event.isEmpty || event == "message" {
            candidateCount += 1
            guard candidateCount <= 100 else { throw MetadataSearchError.limit }
            await receive(.candidate(try JSONDecoder().decode(MetadataCandidate.self, from: data)))
          }
        }
        event = ""
        data.removeAll(keepingCapacity: true)
      } else if text.hasPrefix("event:") {
        event = String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces)
      } else if text.hasPrefix("data:") {
        var value = String(text.dropFirst(5))
        if value.hasPrefix(" ") { value.removeFirst() }
        data.append(contentsOf: value.utf8)
        data.append(10)
      }
    }
    try Task.checkCancellation()
    try ensureSession(generation)
    guard line.isEmpty, data.isEmpty else { throw MetadataSearchError.interrupted }
  }

  func deliveredFile(fileID: Int, expectedSize: Double, mimeType: String) async throws -> URL {
    guard expectedSize.isFinite, expectedSize > 0, expectedSize.rounded() == expectedSize,
      expectedSize < Double(Int64.max)
    else { throw ConnectionError.invalidResponse }
    let byteLimit = Int64(expectedSize)
    let folder = FileManager.default.temporaryDirectory
    let capacity = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
    if let freeBytes = capacity[.systemFreeSize] as? NSNumber,
      byteLimit > freeBytes.int64Value - 128 * 1024 * 1024
    {
      throw ConnectionError.insufficientStorage
    }

    let generation = sessionGeneration
    var request = URLRequest(url: profile.endpoint("books/files/\(fileID)/serve"))
    request.setValue(mimeType, forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
    try ensureSession(generation)
    var delivery = try await transport.bytes(for: request)
    if (delivery.1 as? HTTPURLResponse)?.statusCode == 401 {
      delivery.0.task.cancel()
      try ensureSession(generation)
      let credentials = try await refresh()
      try ensureSession(generation)
      request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
      delivery = try await transport.bytes(for: request)
    }
    let (bytes, response) = delivery
    defer { bytes.task.cancel() }
    try ensureSession(generation)
    guard let response = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
    if response.statusCode == 401 { throw ConnectionError.expiredSession }
    try validate(response)
    guard response.mimeType == mimeType else { throw ConnectionError.invalidResponse }
    if response.expectedContentLength >= 0 && response.expectedContentLength != byteLimit {
      throw ConnectionError.fileChanged
    }

    let destination = folder.appendingPathComponent("bookorbit-\(UUID().uuidString).content")
    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
      throw ConnectionError.insufficientStorage
    }
    var completed = false
    defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
    let handle = try FileHandle(forWritingTo: destination)
    defer { try? handle.close() }
    var buffer = Data()
    buffer.reserveCapacity(64 * 1024)
    var received: Int64 = 0
    for try await byte in bytes {
      guard received < byteLimit else { throw ConnectionError.fileChanged }
      buffer.append(byte)
      received += 1
      if buffer.count == 64 * 1024 {
        try Task.checkCancellation()
        try ensureSession(generation)
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
      }
    }
    try Task.checkCancellation()
    try ensureSession(generation)
    guard received == byteLimit else { throw ConnectionError.fileChanged }
    if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
    completed = true
    return destination
  }

  private func ensureSession(_ generation: UUID) throws {
    guard generation == sessionGeneration, saved != nil else {
      throw ConnectionError.expiredSession
    }
  }

  func epubResource(bookID: Int, fileID: Int, path: String, expectedSize: Int?) async throws -> Data
  {
    let limit = 8 * 1024 * 1024
    if let expectedSize, !(0...limit).contains(expectedSize) {
      throw ConnectionError.resourceTooLarge
    }
    let generation = sessionGeneration
    var request = URLRequest(
      url: profile.endpoint(
        "epub/\(bookID)/file/\(path)", query: [URLQueryItem(name: "fileId", value: String(fileID))])
    )
    request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
    try ensureSession(generation)
    var delivery = try await transport.bytes(for: request)
    if (delivery.1 as? HTTPURLResponse)?.statusCode == 401 {
      delivery.0.task.cancel()
      let credentials = try await refresh()
      try ensureSession(generation)
      request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
      delivery = try await transport.bytes(for: request)
    }
    let (bytes, response) = delivery
    defer { bytes.task.cancel() }
    try ensureSession(generation)
    guard let response = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
    if response.statusCode == 401 { throw ConnectionError.expiredSession }
    try validate(response)
    guard response.expectedContentLength <= limit else { throw ConnectionError.resourceTooLarge }
    var data = Data()
    for try await byte in bytes {
      guard data.count < limit else { throw ConnectionError.resourceTooLarge }
      data.append(byte)
      if data.count % (64 * 1024) == 0 {
        try Task.checkCancellation()
        try ensureSession(generation)
      }
    }
    try Task.checkCancellation()
    try ensureSession(generation)
    if let expectedSize, data.count != expectedSize { throw ConnectionError.fileChanged }
    return data
  }

  private func accessToken() async throws -> String {
    guard let saved else { throw ConnectionError.expiredSession }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let expiry = formatter.date(from: saved.credentials.accessTokenExpiresAt)
    if let expiry, expiry.timeIntervalSinceNow > 30 { return saved.credentials.accessToken }
    return try await refresh().accessToken
  }

  private func refresh() async throws -> NativeCredentials {
    let generation = sessionGeneration
    let pending: (id: UUID, task: Task<NativeCredentials, Error>)
    if let refreshTask {
      pending = refreshTask
    } else {
      guard let saved else { throw ConnectionError.expiredSession }
      let body = try JSONEncoder().encode(
        RefreshRequest(refreshToken: saved.credentials.refreshToken))
      let task = Task<NativeCredentials, Error> {
        let (data, response) = try await self.raw("auth/refresh", method: "POST", body: body)
        if response.statusCode == 401 { throw ConnectionError.expiredSession }
        try self.validate(response)
        let credentials = try JSONDecoder().decode(NativeCredentials.self, from: data)
        guard generation == self.sessionGeneration, var session = self.saved else {
          throw ConnectionError.expiredSession
        }
        session.credentials = credentials
        try self.store.write(session)
        self.saved = session
        return credentials
      }
      pending = (UUID(), task)
      refreshTask = pending
    }
    defer { if refreshTask?.id == pending.id { refreshTask = nil } }
    let credentials = try await pending.task.value
    guard generation == sessionGeneration else { throw ConnectionError.expiredSession }
    return credentials
  }

  private func raw(
    _ path: String, method: String, body: Data?, query: [URLQueryItem] = [], token: String? = nil
  ) async throws
    -> (Data, HTTPURLResponse)
  {
    var request = URLRequest(url: profile.endpoint(path, query: query))
    request.httpMethod = method
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    let (data, response) = try await transport.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
    return (data, response)
  }

  private func validate(_ response: HTTPURLResponse) throws {
    if response.statusCode == 403 { throw ConnectionError.denied }
    guard (200..<300).contains(response.statusCode) else {
      throw ConnectionError.http(response.statusCode)
    }
  }
}
