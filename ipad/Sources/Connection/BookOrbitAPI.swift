import Foundation

struct CoverReExtractionResult: Decodable, Sendable {
  let processed: Int
  let updated: Int
}

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
  private var activeBookFileWrites: Set<String> = []
  private var resourceStore: OfflineResourceStore?
  private var pdfPublicationRefreshes:
    [Int: (id: UUID, session: UUID, previous: String, current: String?, task: Task<Bool, Error>)] =
      [:]
  private(set) var isOffline = false

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

  func sendPublicEmpty(_ path: String, body: Data, expectedStatus: Int) async throws {
    try Task.checkCancellation()
    let (data, response) = try await raw(path, method: "POST", body: body)
    try Task.checkCancellation()
    try validate(response)
    guard response.statusCode == expectedStatus, data.isEmpty else {
      throw ConnectionError.invalidResponse
    }
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
    resourceStore = nil
    isOffline = false
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
    resourceStore = nil
    isOffline = false
  }

  func offlineStore() throws -> OfflineResourceStore {
    let namespace = try storageNamespace()
    if let resourceStore { return resourceStore }
    let store = try OfflineResourceStore(namespace: namespace)
    resourceStore = store
    return store
  }

  func resumeOfflineUser() async throws -> AuthUser? {
    guard let saved, !(try await offlineStore().summaries()).isEmpty else { return nil }
    isOffline = true
    return saved.user
  }

  func send<T: Decodable & Sendable>(
    _ path: String, method: String = "GET", body: Data? = nil,
    query: [URLQueryItem] = [], authenticated: Bool = true
  ) async throws -> T {
    do {
      return try await sendOnline(
        path, method: method, body: body, query: query, authenticated: authenticated)
    } catch {
      if method == "GET", authenticated, error is URLError,
        let data = try await offlineStore().read(path: path, query: query, limit: 8 * 1024 * 1024)
      {
        return try JSONDecoder().decode(T.self, from: data)
      }
      throw error
    }
  }

  func boundedJSON<T: Decodable & Sendable>(
    _ path: String, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = [],
    byteLimit: Int = 1024 * 1024, session: UUID? = nil, expectedStatus: Int? = nil
  ) async throws -> T {
    do {
      return try await boundedJSONOnline(
        path, method: method, body: body, query: query,
        byteLimit: byteLimit, session: session, expectedStatus: expectedStatus)
    } catch {
      if method == "GET", error is URLError,
        let data = try await offlineStore().read(path: path, query: query, limit: byteLimit)
      {
        return try JSONDecoder().decode(T.self, from: data)
      }
      throw error
    }
  }

  private func reconcileOfflineMetadata(path: String, data: Data) async throws {
    let parts = path.split(separator: "/")
    guard parts.count == 2, parts[0] == "books", let bookID = Int(parts[1]),
      var snapshot = try await offlineStore().snapshot(bookID: bookID),
      let fresh = try? JSONDecoder().decode(BookDetail.self, from: data)
    else { return }
    let resourceStore = try offlineStore()
    let current = Dictionary(uniqueKeysWithValues: fresh.files.map { ($0.id, $0) })
    for previous in snapshot.book.files {
      let replacement = current[previous.id]
      guard
        replacement == nil || replacement?.absolutePath != previous.absolutePath
          || replacement?.sizeBytes != previous.sizeBytes
      else { continue }
      if let replacement, replacement.absolutePath == previous.absolutePath,
        previous.format?.lowercased() == "pdf",
        let revision = try await resourceStore.sourceResource(fileID: previous.id)?.digest,
        try await refreshKnownPdfPublication(
          fileID: previous.id, previousRevision: revision,
          session: authenticatedSessionGeneration())
      {
        snapshot = try await resourceStore.snapshot(bookID: bookID) ?? snapshot
        continue
      }
      let repository = try await NativeAnnotationRepository.shared(api: self)
      try await repository.retainSourceRecovery(
        bookID: bookID, fileID: previous.id,
        reason: replacement == nil ? "source_deleted" : "source_replaced")
      try await resourceStore.retainCurrentSource(
        fileID: previous.id,
        reason: replacement == nil ? "source_deleted" : "source_replaced")
      try await resourceStore.invalidateDerivedResources(bookID: bookID, fileID: previous.id)
      snapshot.state = "recovery"
      snapshot.message =
        "Source content changed. Retained local copies and pending annotations require explicit review."
    }
    if snapshot.book.coverVersion != fresh.coverVersion && snapshot.state == "ready" {
      snapshot.state = "paused"
      snapshot.message =
        "The cover changed. Resume the offline download to verify the updated cover."
    }
    if snapshot.book != fresh || snapshot.state == "recovery" {
      snapshot.book = fresh
      try await resourceStore.save(snapshot)
    }
  }

  private func retainOfflineBookUnavailable(path: String) async throws {
    let parts = path.split(separator: "/")
    guard parts.count == 2, parts[0] == "books", let bookID = Int(parts[1]),
      var snapshot = try await offlineStore().snapshot(bookID: bookID)
    else { return }
    let repository = try await NativeAnnotationRepository.shared(api: self)
    for file in snapshot.book.files {
      try await repository.retainSourceRecovery(
        bookID: bookID, fileID: file.id, reason: "source_deleted")
      try await offlineStore().retainCurrentSource(fileID: file.id, reason: "source_deleted")
    }
    snapshot.state = "recovery"
    snapshot.message =
      "This book is unavailable on the server. Retained source versions and pending annotations can be recovered explicitly."
    try await offlineStore().save(snapshot)
  }

  func sourceRevision(fileID: Int, session: UUID) async throws -> String {
    guard fileID > 0 else { throw ConnectionError.invalidResponse }
    try ensureSession(session)
    let resource = try await offlineStore().sourceResource(fileID: fileID)
    let path = resource?.path ?? "books/files/\(fileID)/serve"
    do {
      var request = URLRequest(url: profile.endpoint(path))
      request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
      request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
      request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
      var delivery = try await networkBytes(for: request)
      if (delivery.1 as? HTTPURLResponse)?.statusCode == 401 {
        delivery.0.task.cancel()
        request.setValue(
          "Bearer \(try await refresh().accessToken)", forHTTPHeaderField: "Authorization")
        delivery = try await networkBytes(for: request)
      }
      let (bytes, response) = delivery
      defer { bytes.task.cancel() }
      try ensureSession(session)
      guard let response = response as? HTTPURLResponse else {
        throw ConnectionError.invalidResponse
      }
      if [403, 404].contains(response.statusCode) {
        try await retainOfflineSource(fileID: fileID, reason: "source_deleted")
      }
      try validate(response)
      guard response.statusCode == 206, response.expectedContentLength == 1,
        response.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 0-0/") == true,
        let revision = response.value(forHTTPHeaderField: "X-Content-SHA256"),
        revision.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
        response.value(forHTTPHeaderField: "ETag") == "\"\(revision)\""
      else { throw ConnectionError.invalidResponse }
      var received = 0
      for try await _ in bytes {
        received += 1
        guard received <= 1 else { throw ConnectionError.invalidResponse }
      }
      guard received == 1 else { throw ConnectionError.fileChanged }
      try ensureSession(session)
      if let local = resource?.digest, revision != local {
        if try await !refreshKnownPdfPublication(
          fileID: fileID, previousRevision: local, currentRevision: revision, session: session)
        {
          try await retainOfflineSource(fileID: fileID, reason: "source_replaced")
        }
      }
      return revision
    } catch {
      guard error is URLError, let revision = resource?.digest else { throw error }
      try ensureSession(session)
      return revision
    }
  }

  func reconciledSourceRevision(fileID: Int, previous: String, session: UUID) async throws
    -> String
  {
    let current = try await sourceRevision(fileID: fileID, session: session)
    if previous.replacingOccurrences(of: "sha256:", with: "") == current { return current }
    guard
      try await publicationProof(
        fileID: fileID, previousRevision: previous, currentRevision: current, session: session)
        != nil
    else { throw ConnectionError.fileChanged }
    return current
  }

  private func publicationProof(
    fileID: Int, previousRevision: String, currentRevision: String? = nil, session: UUID
  ) async throws -> NativePdfPageSource? {
    try ensureSession(session)
    let store = try offlineStore()
    guard let bookID = try await store.bookID(fileID: fileID),
      let snapshot = try await store.snapshot(bookID: bookID),
      snapshot.book.files.first(where: { $0.id == fileID })?.format?.lowercased() == "pdf"
    else { return nil }
    let previous = "sha256:" + previousRevision.replacingOccurrences(of: "sha256:", with: "")
    let proof: NativePdfPageSource = try await boundedJSONOnline(
      "annotations/native/files/\(fileID)/source",
      query: [
        .init(name: "bookId", value: String(bookID)), .init(name: "page", value: "0"),
        .init(name: "sourceRevision", value: previous),
      ], session: session)
    try ensureSession(session)
    guard proof.matchedSourceRevision == previous,
      proof.sourceRevision != previous,
      currentRevision.map({ proof.sourceRevision == "sha256:\($0)" }) ?? true
    else { return nil }
    return proof
  }

  private func refreshKnownPdfPublication(
    fileID: Int, previousRevision: String, currentRevision: String? = nil, session: UUID
  ) async throws -> Bool {
    if let pending = pdfPublicationRefreshes[fileID] {
      if pending.session == session, pending.previous == previousRevision,
        pending.current == currentRevision
      {
        let result = try await pending.task.value
        try ensureSession(session)
        return result
      }
      do { _ = try await pending.task.value } catch {
        if pending.session == session { throw error }
      }
      if pdfPublicationRefreshes[fileID]?.id == pending.id { pdfPublicationRefreshes[fileID] = nil }
      return try await refreshKnownPdfPublication(
        fileID: fileID, previousRevision: previousRevision,
        currentRevision: currentRevision, session: session)
    }
    let id = UUID()
    let task = Task {
      try await self.refreshKnownPdfPublicationNow(
        fileID: fileID, previousRevision: previousRevision,
        currentRevision: currentRevision, session: session)
    }
    pdfPublicationRefreshes[fileID] = (id, session, previousRevision, currentRevision, task)
    defer {
      if pdfPublicationRefreshes[fileID]?.id == id { pdfPublicationRefreshes[fileID] = nil }
    }
    return try await task.value
  }

  private func refreshKnownPdfPublicationNow(
    fileID: Int, previousRevision: String, currentRevision: String? = nil, session: UUID
  ) async throws -> Bool {
    guard
      let proof = try await publicationProof(
        fileID: fileID, previousRevision: previousRevision,
        currentRevision: currentRevision, session: session)
    else { return false }
    let store = try offlineStore()
    guard var resource = try await store.sourceResource(fileID: fileID),
      let bookID = try await store.bookID(fileID: fileID)
    else { return false }
    let digest = proof.sourceRevision.replacingOccurrences(of: "sha256:", with: "")
    resource.expectedBytes = nil
    resource.validator = nil
    resource.sourceDigest = digest
    resource.bookID = bookID
    resource.fileID = fileID
    let destination = await store.destination(
      path: resource.path, query: resource.query.map(\.item))
    let refreshed = try await downloadOfflineResource(
      resource, destination: destination, expectedPublicationRevision: digest, progress: { _ in })
    try ensureSession(session)
    try await store.advancePublishedSource(bookID: bookID, fileID: fileID, resource: refreshed)
    return true
  }

  private func retainOfflineSource(fileID: Int, reason: String) async throws {
    let store = try offlineStore()
    guard let bookID = try await store.bookID(fileID: fileID),
      var snapshot = try await store.snapshot(bookID: bookID)
    else { return }
    let repository = try await NativeAnnotationRepository.shared(api: self)
    try await repository.retainSourceRecovery(bookID: bookID, fileID: fileID, reason: reason)
    try await store.retainCurrentSource(fileID: fileID, reason: reason)
    try await store.invalidateDerivedResources(bookID: bookID, fileID: fileID)
    snapshot.state = "recovery"
    snapshot.message =
      "Source content changed. Retained versions and pending annotations require explicit review."
    try await store.save(snapshot)
  }

  func reconcileOfflineBooks(limit: Int = 20) async {
    do {
      guard (1...20).contains(limit) else { throw ConnectionError.invalidResponse }
      let namespace = try storageNamespace()
      let store = try offlineStore()
      let books = try await store.summaries().sorted { $0.id < $1.id }
      guard !books.isEmpty else { return }
      let key = "bookorbit.offline-source-scan.\(OfflineResourceStore.hash(Data(namespace.utf8)))"
      let cursor = UserDefaults.standard.array(forKey: key) as? [Int] ?? [0, 0]
      var remaining = limit
      let session = try authenticatedSessionGeneration()
      for book in books where book.id >= (cursor.first ?? 0) {
        do { let _: BookDetail = try await boundedJSON("books/\(book.id)", session: session) } catch
        {
          if error is URLError { return }
          if case ConnectionError.http(404) = error {
          } else if case ConnectionError.denied = error {
          } else {
            throw error
          }
        }
        if isOffline { return }
        guard let snapshot = try await store.snapshot(bookID: book.id) else { continue }
        for fileID in snapshot.selectedFileIDs.sorted()
        where book.id != cursor.first || fileID > (cursor.last ?? 0) {
          do { _ = try await sourceRevision(fileID: fileID, session: session) } catch {
            if error is URLError { return }
            if case ConnectionError.http(404) = error {
            } else if case ConnectionError.denied = error {
            } else {
              throw error
            }
          }
          if isOffline { return }
          UserDefaults.standard.set([book.id, fileID], forKey: key)
          remaining -= 1
          if remaining == 0 { return }
        }
        UserDefaults.standard.set([book.id + 1, 0], forKey: key)
      }
      UserDefaults.standard.removeObject(forKey: key)
    } catch {}
  }

  func canRemoveSourceVersion(id: String) async throws -> Bool {
    let generation = try authenticatedSessionGeneration()
    let namespace = try storageNamespace()
    let version = try await offlineStore().sourceVersion(id: id)
    let repository = try await NativeAnnotationRepository.shared(api: self)
    let allowed = try await repository.canRemoveSourceVersion(
      bookID: version.bookID, fileID: version.fileID, revision: version.revision)
    let protectsReadingState: Bool
    do {
      protectsReadingState = try OfflineReadingStateJournal.hasProtectedWork(
        namespace: namespace, fileID: version.fileID, revision: version.revision)
    } catch {
      try ensureSession(generation)
      throw OfflineStorageError.unverifiedProtection
    }
    try ensureSession(generation)
    return allowed && !protectsReadingState
  }

  func removeSourceVersion(id: String) async throws {
    let generation = try authenticatedSessionGeneration()
    guard try await canRemoveSourceVersion(id: id) else {
      throw OfflineStorageError.protectedVersion
    }
    try ensureSession(generation)
    try await offlineStore().removeSourceVersion(id: id)
  }

  private func networkBytes(for request: URLRequest) async throws -> (
    URLSession.AsyncBytes, URLResponse
  ) {
    do {
      let result = try await transport.bytes(for: request)
      isOffline = false
      return result
    } catch {
      if error is URLError { isOffline = true }
      throw error
    }
  }

  private func sendOnline<T: Decodable & Sendable>(
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
    if method == "GET", [403, 404].contains(response.statusCode) {
      try await retainOfflineBookUnavailable(path: path)
    }
    try validate(response)
    if method == "GET" { try await reconcileOfflineMetadata(path: path, data: data) }
    if method == "GET", authenticated, let resourceStore,
      await resourceStore.contains(path: path, query: query)
    {
      _ = try await resourceStore.writeData(data, path: path, query: query)
    }
    do { return try JSONDecoder().decode(T.self, from: data) } catch {
      throw ConnectionError.invalidResponse
    }
  }

  private func boundedJSONOnline<T: Decodable & Sendable>(
    _ path: String, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = [],
    byteLimit: Int = 1024 * 1024, session: UUID? = nil, expectedStatus: Int? = nil
  ) async throws -> T {
    let generation = session ?? sessionGeneration
    try ensureSession(generation)
    var request = URLRequest(url: profile.endpoint(path, query: query))
    request.httpMethod = method
    request.httpBody = body
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
    try ensureSession(generation)
    var delivery = try await networkBytes(for: request)
    if (delivery.1 as? HTTPURLResponse)?.statusCode == 401 {
      delivery.0.task.cancel()
      let credentials = try await refresh()
      try ensureSession(generation)
      request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
      delivery = try await networkBytes(for: request)
    }
    let (bytes, response) = delivery
    defer { bytes.task.cancel() }
    guard let response = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
    if response.statusCode == 401 { throw ConnectionError.expiredSession }
    if method == "GET", [403, 404].contains(response.statusCode) {
      try await retainOfflineBookUnavailable(path: path)
    }
    try validate(response)
    if let expectedStatus, response.statusCode != expectedStatus {
      throw ConnectionError.invalidResponse
    }
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
    if method == "GET" { try await reconcileOfflineMetadata(path: path, data: data) }
    if method == "GET", let resourceStore, await resourceStore.contains(path: path, query: query) {
      _ = try await resourceStore.writeData(data, path: path, query: query)
    }
    do { return try JSONDecoder().decode(T.self, from: data) } catch {
      throw ConnectionError.invalidResponse
    }
  }

  func sendEmpty(
    _ path: String, method: String = "POST", body: Data? = nil, query: [URLQueryItem] = [],
    session: UUID? = nil, expectedStatus: Int? = nil
  ) async throws {
    let generation = session ?? sessionGeneration
    try ensureSession(generation)
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
    if let expectedStatus, response.statusCode != expectedStatus {
      throw ConnectionError.invalidResponse
    }
  }

  func updateSeriesCollapsePreferences(
    _ payload: UpdateSeriesCollapsePreferencesPayload, session: UUID
  ) async throws {
    try await sendEmpty(
      "users/me/series-collapse-preferences", method: "PATCH",
      body: JSONEncoder().encode(payload), session: session, expectedStatus: 204)
  }

  func seriesCollapseUser(session: UUID) async throws -> AuthUser {
    try ensureSession(session)
    guard let expectedUserID = saved?.user.id else { throw ConnectionError.expiredSession }
    let user: AuthUser = try await boundedJSON("auth/me", session: session)
    try ensureSession(session)
    guard user.id == expectedUserID, var current = saved else {
      throw ConnectionError.expiredSession
    }
    current.user = user
    try store.write(current)
    saved = current
    return user
  }

  func deleteBook(_ bookID: Int, session: UUID) async throws {
    guard bookID > 0 else { throw ConnectionError.invalidResponse }
    try Task.checkCancellation()
    try ensureSession(session)
    var request = URLRequest(url: profile.endpoint("books"))
    request.httpMethod = "DELETE"
    request.httpBody = try JSONEncoder().encode(BookIdsSelection(bookIds: [bookID]))
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
    try ensureSession(session)
    try Task.checkCancellation()
    var delivery = try await networkBytes(for: request)
    if (delivery.1 as? HTTPURLResponse)?.statusCode == 401 {
      delivery.0.task.cancel()
      let credentials = try await refresh()
      try ensureSession(session)
      try Task.checkCancellation()
      request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
      delivery = try await networkBytes(for: request)
    }
    let (bytes, response) = delivery
    defer { bytes.task.cancel() }
    try ensureSession(session)
    guard let response = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
    if response.statusCode == 401 { throw ConnectionError.expiredSession }
    try validate(response)
    guard response.statusCode == 204, response.expectedContentLength <= 0 else {
      throw ConnectionError.invalidResponse
    }
    for try await _ in bytes { throw ConnectionError.invalidResponse }
    try Task.checkCancellation()
    try ensureSession(session)
  }

  func moveBook(
    _ body: BookMoveExplicitExecuteRequest, session: UUID,
    receive: @MainActor @Sendable (BookMoveBookProgress) -> Void
  ) async throws -> BookMoveCompletionEvent {
    guard body.selection.bookIds.count == 1, let bookID = body.selection.bookIds.first,
      bookID > 0, body.targetLibraryId > 0, body.targetFolderId > 0,
      ["keep_both", "merge", "skip", "suggested"].contains(body.collisionPolicy),
      body.overrides == nil
    else { throw ConnectionError.invalidResponse }
    try Task.checkCancellation()
    try ensureSession(session)
    var request = URLRequest(url: profile.endpoint("books/move"))
    request.httpMethod = "POST"
    request.httpBody = try JSONEncoder().encode(body)
    request.timeoutInterval = 600
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
    try ensureSession(session)
    try Task.checkCancellation()
    var delivery = try await networkBytes(for: request)
    if (delivery.1 as? HTTPURLResponse)?.statusCode == 401 {
      delivery.0.task.cancel()
      let credentials = try await refresh()
      try ensureSession(session)
      try Task.checkCancellation()
      request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
      delivery = try await networkBytes(for: request)
    }
    let (bytes, response) = delivery
    defer { bytes.task.cancel() }
    try ensureSession(session)
    guard let response = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
    if response.statusCode == 401 { throw ConnectionError.expiredSession }
    if [400, 403, 404, 409].contains(response.statusCode) {
      throw BookMoveRejection.status(response.statusCode)
    }
    try validate(response)
    guard response.statusCode == 200, response.mimeType == "text/event-stream" else {
      throw ConnectionError.invalidResponse
    }
    var line = Data()
    var frame = Data()
    var received = 0
    var progress: BookMoveBookProgress?
    for try await byte in bytes {
      try Task.checkCancellation()
      try ensureSession(session)
      received += 1
      guard received <= 256 * 1024, line.count < 64 * 1024, frame.count < 64 * 1024 else {
        throw ConnectionError.responseTooLarge
      }
      if byte != 10 {
        line.append(byte)
        continue
      }
      if line.last == 13 { line.removeLast() }
      guard let text = String(data: line, encoding: .utf8) else {
        throw ConnectionError.invalidResponse
      }
      line.removeAll(keepingCapacity: true)
      if text.isEmpty {
        guard !frame.isEmpty else { continue }
        let event: BookMoveStreamEvent
        do { event = try JSONDecoder().decode(BookMoveStreamEvent.self, from: frame) } catch {
          throw ConnectionError.invalidResponse
        }
        frame.removeAll(keepingCapacity: true)
        switch event {
        case .book(let item):
          guard item.bookId == bookID, progress == nil,
            ["success", "merged", "failed", "skipped"].contains(item.status)
          else { throw ConnectionError.invalidResponse }
          progress = item
          await receive(item)
        case .completed(let result):
          let counts = [result.succeeded, result.merged, result.failed, result.skipped]
          guard result.done, counts.allSatisfy({ (0...1).contains($0) }),
            result.processed == counts.reduce(0, +), result.processed <= 1,
            result.processed == (progress == nil ? 0 : 1),
            (progress?.status == "success") == (result.succeeded == 1),
            (progress?.status == "merged") == (result.merged == 1),
            (progress?.status == "failed") == (result.failed == 1),
            (progress?.status == "skipped") == (result.skipped == 1)
          else { throw ConnectionError.invalidResponse }
          try Task.checkCancellation()
          try ensureSession(session)
          return result
        }
      } else if text.hasPrefix("data:") {
        if !frame.isEmpty { frame.append(10) }
        var value = text.dropFirst(5)
        if value.first == " " { value = value.dropFirst() }
        frame.append(contentsOf: value.utf8)
      } else if !text.hasPrefix(":") {
        throw ConnectionError.invalidResponse
      }
    }
    throw ConnectionError.invalidResponse
  }

  func speechAudio(_ path: String, body: Data, session: UUID) async throws -> Data {
    guard path == "tts/preview" || path == "tts/synthesize", body.count <= 32 * 1024 else {
      throw ConnectionError.invalidResponse
    }
    try ensureSession(session)
    var request = URLRequest(url: profile.endpoint(path))
    request.httpMethod = "POST"
    request.httpBody = body
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
    try ensureSession(session)
    var delivery = try await networkBytes(for: request)
    if (delivery.1 as? HTTPURLResponse)?.statusCode == 401 {
      delivery.0.task.cancel()
      let credentials = try await refresh()
      try ensureSession(session)
      request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
      delivery = try await networkBytes(for: request)
    }
    let (bytes, response) = delivery
    defer { bytes.task.cancel() }
    guard let response = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
    if response.statusCode == 401 { throw ConnectionError.expiredSession }
    try validate(response)
    let limit = 8 * 1024 * 1024
    guard response.mimeType == "audio/mpeg" else { throw ConnectionError.invalidResponse }
    guard response.expectedContentLength <= limit else { throw ConnectionError.responseTooLarge }
    var data = Data()
    for try await byte in bytes {
      guard data.count < limit else { throw ConnectionError.responseTooLarge }
      data.append(byte)
      if data.count % (16 * 1024) == 0 {
        try Task.checkCancellation()
        try ensureSession(session)
      }
    }
    try Task.checkCancellation()
    try ensureSession(session)
    guard !data.isEmpty else { throw ConnectionError.invalidResponse }
    return data
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

  func canReExtractCovers() -> Bool {
    saved?.user.hasPermission(.libraryEditMetadata) == true
  }

  func reExtractCover(bookID: Int, medium: CoverMedium, session: UUID) async throws
    -> CoverReExtractionResult
  {
    try ensureSession(session)
    guard canReExtractCovers() else { throw ConnectionError.http(403) }
    let result: CoverReExtractionResult = try await boundedJSON(
      "books/\(bookID)/re-extract-cover", method: "POST",
      query: [URLQueryItem(name: "medium", value: medium.rawValue)],
      byteLimit: 16 * 1024, session: session)
    guard (0...1).contains(result.processed), (0...result.processed).contains(result.updated) else {
      throw ConnectionError.invalidResponse
    }
    return result
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

  func thumbnailImage(bookID: Int, version: String, namespace: String) async throws -> Data {
    return try await authenticatedImage(
      path: "books/\(bookID)/thumbnail",
      query: [URLQueryItem(name: "t", value: version)],
      cachePolicy: .reloadIgnoringLocalCacheData, namespace: namespace)
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

  private func authenticatedImageOnline(
    path: String, query: [URLQueryItem],
    cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy, namespace: String? = nil
  ) async throws -> Data {
    if let namespace, try imageNamespace() != namespace { throw ConnectionError.expiredSession }
    let generation = sessionGeneration
    var request = URLRequest(url: profile.endpoint(path, query: query))
    request.cachePolicy = cachePolicy
    request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
    try ensureSession(generation)
    var delivery = try await networkBytes(for: request)
    if (delivery.1 as? HTTPURLResponse)?.statusCode == 401 {
      delivery.0.task.cancel()
      let credentials = try await refresh()
      try ensureSession(generation)
      request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
      delivery = try await networkBytes(for: request)
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

  private func comicPageOnline(fileID: Int, pageIndex: Int) async throws -> Data {
    guard pageIndex >= 0 else { throw ConnectionError.invalidResponse }
    let limit = 20 * 1024 * 1024
    let generation = sessionGeneration
    var request = URLRequest(url: profile.endpoint("cbz/files/\(fileID)/pages/\(pageIndex)"))
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
    try ensureSession(generation)
    var delivery = try await networkBytes(for: request)
    if (delivery.1 as? HTTPURLResponse)?.statusCode == 401 {
      delivery.0.task.cancel()
      let credentials = try await refresh()
      try ensureSession(generation)
      request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
      delivery = try await networkBytes(for: request)
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
    var delivery = try await networkBytes(for: request)
    if (delivery.1 as? HTTPURLResponse)?.statusCode == 401 {
      delivery.0.task.cancel()
      let credentials = try await refresh()
      try ensureSession(generation)
      request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
      delivery = try await networkBytes(for: request)
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

  private func deliveredFileOnline(
    fileID: Int, expectedSize: Double?, mimeType: String, maximumSize: Int64? = nil,
    session: UUID? = nil
  ) async throws -> URL {
    var expectedBytes: Int64?
    if let expectedSize {
      guard expectedSize.isFinite, expectedSize > 0, expectedSize.rounded() == expectedSize,
        expectedSize < Double(Int64.max)
      else { throw ConnectionError.invalidResponse }
      expectedBytes = Int64(expectedSize)
    }
    guard maximumSize.map({ $0 > 0 }) ?? true else { throw ConnectionError.invalidResponse }
    if let expectedBytes, let maximumSize, expectedBytes > maximumSize {
      throw ConnectionError.resourceTooLarge
    }

    let generation = session ?? sessionGeneration
    var request = URLRequest(url: profile.endpoint("books/files/\(fileID)/serve"))
    request.setValue(mimeType, forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
    try ensureSession(generation)
    var delivery = try await networkBytes(for: request)
    if (delivery.1 as? HTTPURLResponse)?.statusCode == 401 {
      delivery.0.task.cancel()
      try ensureSession(generation)
      let credentials = try await refresh()
      try ensureSession(generation)
      request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
      delivery = try await networkBytes(for: request)
    }
    let (bytes, response) = delivery
    defer { bytes.task.cancel() }
    try ensureSession(generation)
    guard let response = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
    if response.statusCode == 401 { throw ConnectionError.expiredSession }
    try validate(response)
    guard response.statusCode == 200, response.mimeType == mimeType else {
      throw ConnectionError.invalidResponse
    }
    if let expectedBytes, response.expectedContentLength >= 0,
      response.expectedContentLength != expectedBytes
    {
      throw ConnectionError.fileChanged
    }
    let byteLimit = expectedBytes ?? response.expectedContentLength
    guard byteLimit > 0 else { throw ConnectionError.invalidResponse }
    if let maximumSize, byteLimit > maximumSize { throw ConnectionError.resourceTooLarge }
    let folder = FileManager.default.temporaryDirectory
    let capacity = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
    if let freeBytes = capacity[.systemFreeSize] as? NSNumber,
      byteLimit > freeBytes.int64Value - 128 * 1024 * 1024
    {
      throw ConnectionError.insufficientStorage
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

  func downloadBookFile(
    fileID: Int, kind: BookFileDownloadKind, session: UUID,
    progress: @MainActor @Sendable (BookFileTransferProgress) -> Void
  ) async throws -> StagedBookFile {
    do {
      return try await downloadBookFileOnline(
        fileID: fileID, kind: kind, session: session, progress: progress)
    } catch {
      guard error is URLError, kind == .original,
        saved?.user.hasPermission(.libraryDownload) == true
      else { throw error }
      try ensureSession(session)
      let artifact = try await offlineStore().exportDownloadedResource(fileID: fileID)
      await progress(.init(received: artifact.size, total: artifact.size))
      return artifact
    }
  }

  private func downloadBookFileOnline(
    fileID: Int, kind: BookFileDownloadKind, session: UUID,
    progress: @MainActor @Sendable (BookFileTransferProgress) -> Void
  ) async throws -> StagedBookFile {
    guard fileID > 0 else { throw ConnectionError.invalidResponse }
    try Task.checkCancellation()
    try ensureSession(session)
    var request = URLRequest(url: profile.endpoint(kind.path(fileID: fileID)))
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 120
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
    try ensureSession(session)
    var delivery = try await networkBytes(for: request)
    if (delivery.1 as? HTTPURLResponse)?.statusCode == 401 {
      delivery.0.task.cancel()
      let credentials = try await refresh()
      try ensureSession(session)
      request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
      delivery = try await networkBytes(for: request)
    }
    let (bytes, response) = delivery
    defer { bytes.task.cancel() }
    try ensureSession(session)
    guard let response = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
    if response.statusCode == 401 { throw ConnectionError.expiredSession }
    try validate(response)
    let staging = try BookFileDownloadStaging(response: response, kind: kind)
    let total = staging.artifact.size
    await progress(.init(received: 0, total: total))
    var buffer = Data()
    buffer.reserveCapacity(64 * 1024)
    var received: Int64 = 0
    var lastUpdate = Date.timeIntervalSinceReferenceDate
    for try await byte in bytes {
      guard received < total else { throw ConnectionError.fileChanged }
      buffer.append(byte)
      received += 1
      if buffer.count == 64 * 1024 {
        try Task.checkCancellation()
        try ensureSession(session)
        try staging.write(buffer)
        buffer.removeAll(keepingCapacity: true)
        if Date.timeIntervalSinceReferenceDate - lastUpdate >= 0.2 {
          await progress(.init(received: received, total: total))
          lastUpdate = Date.timeIntervalSinceReferenceDate
        }
      }
    }
    try Task.checkCancellation()
    try ensureSession(session)
    guard received == total else { throw ConnectionError.fileChanged }
    if !buffer.isEmpty { try staging.write(buffer) }
    await progress(.init(received: received, total: total))
    try Task.checkCancellation()
    try ensureSession(session)
    return try staging.finish()
  }

  func bookFileWriteIsUnconfirmed(_ bookID: Int, session: UUID) throws -> Bool {
    try ensureSession(session)
    guard let userID = saved?.user.id else { throw ConnectionError.expiredSession }
    return try BookFileWriteUncertainty.contains(bookID, profile: profile, userID: userID)
  }

  func writeAndRenameBook(_ bookID: Int, session: UUID, deliberateRepeat: Bool) async throws
    -> BookWriteAndRenameResult
  {
    try Task.checkCancellation()
    try ensureSession(session)
    guard let userID = saved?.user.id else { throw ConnectionError.expiredSession }
    let operationKey = "\(userID).\(bookID)"
    guard !activeBookFileWrites.contains(operationKey) else {
      throw BookFileWriteRequestError.inProgress
    }
    let unconfirmed = try BookFileWriteUncertainty.contains(
      bookID, profile: profile, userID: userID)
    guard deliberateRepeat || !unconfirmed else {
      throw BookFileWriteRequestError.unconfirmed
    }
    try BookFileWriteUncertainty.record(bookID, profile: profile, userID: userID)
    activeBookFileWrites.insert(operationKey)
    defer { activeBookFileWrites.remove(operationKey) }
    let result: BookWriteAndRenameResult = try await boundedJSON(
      "books/\(bookID)/write-and-rename", method: "POST", byteLimit: 256 * 1024,
      session: session, expectedStatus: 201)
    let statuses = [result.write.status, result.rename.status]
    guard statuses.allSatisfy({ ["success", "skipped", "failed"].contains($0) }),
      result.write.durationMs >= 0, result.rename.durationMs >= 0
    else { throw ConnectionError.invalidResponse }
    try? BookFileWriteUncertainty.clear(bookID, profile: profile, userID: userID)
    return result
  }

  func authenticatedSessionGeneration() throws -> UUID {
    try ensureSession(sessionGeneration)
    return sessionGeneration
  }

  func readerFontFile(
    scope: String, font: UserFont, cached: ReaderFontFile?, directory: URL, session: UUID
  ) async throws -> ReaderFontFile {
    do {
      return try await readerFontFileOnline(
        scope: scope, font: font, cached: cached, directory: directory, session: session)
    } catch {
      guard error is URLError, ["user", "server"].contains(scope),
        let mimeType = ReaderFontVocabulary.mimeTypes[font.format]
      else { throw error }
      try ensureSession(session)
      let path = "\(scope == "server" ? "server-fonts" : "fonts")/\(font.id)/file"
      guard let file = try await offlineStore().verifiedURL(path: path),
        let receipt = try await offlineStore().receipt(path: path),
        receipt.receivedBytes == Int64(font.fileSize), let validator = receipt.validator
      else { throw EPUBFontError.invalidFile }
      let copy = directory.appendingPathComponent(
        "offline-font-\(UUID().uuidString).\(font.format)")
      try FileManager.default.copyItem(at: file, to: copy)
      return ReaderFontFile(url: copy, size: font.fileSize, etag: validator, mimeType: mimeType)
    }
  }

  private func readerFontFileOnline(
    scope: String, font: UserFont, cached: ReaderFontFile?, directory: URL, session: UUID
  )
    async throws -> ReaderFontFile
  {
    guard ["user", "server"].contains(scope), font.id > 0,
      let mimeType = ReaderFontVocabulary.mimeTypes[font.format],
      (1...ReaderFontVocabulary.fileMaximum).contains(font.fileSize)
    else { throw EPUBFontError.invalidFile }
    try ensureSession(session)
    let path = "\(scope == "server" ? "server-fonts" : "fonts")/\(font.id)/file"
    var request = URLRequest(url: profile.endpoint(path))
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 120
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    request.setValue(mimeType, forHTTPHeaderField: "Accept")
    if let cached { request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }
    request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
    try ensureSession(session)
    var delivery = try await networkBytes(for: request)
    if (delivery.1 as? HTTPURLResponse)?.statusCode == 401 {
      delivery.0.task.cancel()
      let credentials = try await refresh()
      try ensureSession(session)
      request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
      delivery = try await networkBytes(for: request)
    }
    let (bytes, response) = delivery
    defer { bytes.task.cancel() }
    try ensureSession(session)
    guard let response = response as? HTTPURLResponse else { throw EPUBFontError.invalidFile }
    if response.statusCode == 401 { throw ConnectionError.expiredSession }
    if response.statusCode == 304 {
      guard let cached, cached.size == font.fileSize, cached.mimeType == mimeType,
        (try cached.url.resourceValues(forKeys: [.fileSizeKey])).fileSize == cached.size
      else { throw EPUBFontError.invalidFile }
      try Task.checkCancellation()
      return cached
    }
    try validate(response)
    guard response.statusCode == 200, response.mimeType == mimeType,
      let etag = response.value(forHTTPHeaderField: "ETag"), etag.utf8.count <= 200,
      etag.hasPrefix("\""), etag.hasSuffix("\""), !etag.contains("\r"), !etag.contains("\n"),
      response.expectedContentLength < 0 || response.expectedContentLength == font.fileSize
    else { throw EPUBFontError.invalidFile }
    let folder = directory
    let capacity = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
    if let free = capacity[.systemFreeSize] as? NSNumber,
      Int64(font.fileSize) > free.int64Value - 128 * 1024 * 1024
    {
      throw ConnectionError.insufficientStorage
    }
    let destination = folder.appendingPathComponent(
      "bookorbit-font-\(UUID().uuidString).\(font.format)")
    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
      throw ConnectionError.insufficientStorage
    }
    var completed = false
    defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
    let handle = try FileHandle(forWritingTo: destination)
    defer { try? handle.close() }
    var buffer = Data()
    buffer.reserveCapacity(64 * 1024)
    var received = 0
    for try await byte in bytes {
      guard received < font.fileSize else { throw EPUBFontError.invalidFile }
      buffer.append(byte)
      received += 1
      if buffer.count == 64 * 1024 {
        try Task.checkCancellation()
        try ensureSession(session)
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
      }
    }
    try Task.checkCancellation()
    try ensureSession(session)
    guard received == font.fileSize else { throw EPUBFontError.invalidFile }
    if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
    completed = true
    return ReaderFontFile(url: destination, size: received, etag: etag, mimeType: mimeType)
  }

  private func audioChunkOnline(
    bookID: Int, assetID: String, format: String, offset: Int64, length: Int,
    expectedSize: Int64?, generation: UUID
  ) async throws -> AudioByteChunk {
    guard bookID > 0, assetID.hasPrefix("aud_"),
      UUID(uuidString: String(assetID.dropFirst(4))) != nil,
      let mimeType = AudioStreamFormat.mimeTypes[format.lowercased()],
      offset >= 0, (1...AudioStreamFormat.chunkLimit).contains(length)
    else { throw ConnectionError.invalidResponse }
    let (end, overflow) = offset.addingReportingOverflow(Int64(length) - 1)
    guard !overflow, expectedSize == nil || end < expectedSize! else {
      throw ConnectionError.fileChanged
    }
    try ensureSession(generation)
    var request = URLRequest(
      url: profile.endpoint("audiobooks/\(bookID)/assets/\(assetID)/content"))
    request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    request.setValue(mimeType, forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
    try ensureSession(generation)
    var delivery = try await networkBytes(for: request)
    if (delivery.1 as? HTTPURLResponse)?.statusCode == 401 {
      delivery.0.task.cancel()
      try ensureSession(generation)
      let credentials = try await refresh()
      try ensureSession(generation)
      request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
      delivery = try await networkBytes(for: request)
    }
    let (bytes, response) = delivery
    defer { bytes.task.cancel() }
    try ensureSession(generation)
    guard let response = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
    if response.statusCode == 401 { throw ConnectionError.expiredSession }
    try validate(response)
    let range = response.value(forHTTPHeaderField: "Content-Range") ?? ""
    guard response.statusCode == 206, response.mimeType == mimeType,
      response.expectedContentLength == Int64(length),
      range.hasPrefix("bytes \(offset)-\(end)/"),
      let total = Int64(range.dropFirst("bytes \(offset)-\(end)/".count)),
      total > end, total <= 9_007_199_254_740_991,
      expectedSize == nil || total == expectedSize,
      response.value(forHTTPHeaderField: "Content-Encoding").map({ $0 == "identity" }) ?? true
    else { throw ConnectionError.fileChanged }
    var data = Data()
    data.reserveCapacity(length)
    for try await byte in bytes {
      try Task.checkCancellation()
      try ensureSession(generation)
      guard data.count < length else { throw ConnectionError.fileChanged }
      data.append(byte)
    }
    try Task.checkCancellation()
    try ensureSession(generation)
    guard data.count == length else { throw ConnectionError.fileChanged }
    return .init(data: data, totalBytes: total, mimeType: mimeType)
  }

  private func recordedAudioChunkOnline(
    bookID: Int, fileID: Int, clip: EpubMediaOverlayClip, offset: Int64, length: Int,
    expectedSize: Int64?, generation: UUID
  ) async throws -> AudioByteChunk {
    guard bookID > 0, fileID > 0, clip.sectionIndex >= 0,
      EPUBPublicationResources.validPath(clip.audioHref), clip.audioMimeType.hasPrefix("audio/"),
      offset >= 0, (1...AudioStreamFormat.chunkLimit).contains(length)
    else { throw ConnectionError.invalidResponse }
    let (end, overflow) = offset.addingReportingOverflow(Int64(length) - 1)
    guard !overflow, expectedSize.map({ end < $0 }) ?? true else {
      throw ConnectionError.fileChanged
    }
    try ensureSession(generation)
    var request = URLRequest(
      url: profile.endpoint(
        "epub/\(bookID)/media-overlay/file/\(clip.audioHref)",
        query: [
          URLQueryItem(name: "fileId", value: String(fileID)),
          URLQueryItem(name: "sectionIndex", value: String(clip.sectionIndex)),
        ]))
    request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    request.setValue(clip.audioMimeType, forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
    try ensureSession(generation)
    var delivery = try await networkBytes(for: request)
    if (delivery.1 as? HTTPURLResponse)?.statusCode == 401 {
      delivery.0.task.cancel()
      let credentials = try await refresh()
      try ensureSession(generation)
      request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
      delivery = try await networkBytes(for: request)
    }
    let (bytes, response) = delivery
    defer { bytes.task.cancel() }
    try ensureSession(generation)
    guard let response = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
    if response.statusCode == 401 { throw ConnectionError.expiredSession }
    try validate(response)
    let prefix = "bytes \(offset)-\(end)/"
    let range = response.value(forHTTPHeaderField: "Content-Range") ?? ""
    guard response.statusCode == 206, response.mimeType == clip.audioMimeType,
      response.expectedContentLength == Int64(length), range.hasPrefix(prefix),
      let size = Int64(range.dropFirst(prefix.count)), size > end,
      expectedSize.map({ $0 == size }) ?? true,
      response.value(forHTTPHeaderField: "Content-Encoding").map({ $0 == "identity" }) ?? true,
      let validator = response.value(forHTTPHeaderField: "ETag"), !validator.isEmpty,
      validator.utf8.count <= 512
    else { throw ConnectionError.fileChanged }
    var data = Data()
    data.reserveCapacity(length)
    for try await byte in bytes {
      try Task.checkCancellation()
      try ensureSession(generation)
      guard data.count < length else { throw ConnectionError.fileChanged }
      data.append(byte)
    }
    try Task.checkCancellation()
    try ensureSession(generation)
    guard data.count == length else { throw ConnectionError.fileChanged }
    return .init(
      data: data, totalBytes: size, mimeType: clip.audioMimeType, sourceValidator: validator)
  }

  func deliveredFile(
    fileID: Int, expectedSize: Double?, mimeType: String, maximumSize: Int64? = nil,
    session: UUID? = nil
  ) async throws -> URL {
    do {
      return try await deliveredFileOnline(
        fileID: fileID, expectedSize: expectedSize,
        mimeType: mimeType, maximumSize: maximumSize, session: session)
    } catch {
      guard error is URLError,
        let cached = try await offlineStore().verifiedURL(path: "books/files/\(fileID)/serve")
      else { throw error }
      let copy = FileManager.default.temporaryDirectory.appendingPathComponent(
        "offline-\(UUID().uuidString).content")
      try FileManager.default.copyItem(at: cached, to: copy)
      return copy
    }
  }

  func epubResource(
    bookID: Int, fileID: Int, path: String, expectedSize: Int?, byteLimit: Int = 8 * 1024 * 1024,
    session: UUID? = nil
  ) async throws -> Data {
    do {
      return try await epubResourceOnline(
        bookID: bookID, fileID: fileID, path: path,
        expectedSize: expectedSize, byteLimit: byteLimit, session: session)
    } catch {
      guard error is URLError,
        let data = try await offlineStore().read(
          path: "epub/\(bookID)/file/\(path)",
          query: [URLQueryItem(name: "fileId", value: String(fileID))], limit: byteLimit),
        expectedSize.map({ data.count == $0 }) ?? true
      else { throw error }
      return data
    }
  }

  func comicPage(fileID: Int, pageIndex: Int) async throws -> Data {
    do { return try await comicPageOnline(fileID: fileID, pageIndex: pageIndex) } catch {
      guard error is URLError,
        let data = try await offlineStore().read(
          path: "cbz/files/\(fileID)/pages/\(pageIndex)", limit: 20 * 1024 * 1024)
      else { throw error }
      return data
    }
  }

  private func authenticatedImage(
    path: String, query: [URLQueryItem],
    cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
    namespace: String? = nil
  ) async throws -> Data {
    do {
      return try await authenticatedImageOnline(
        path: path, query: query, cachePolicy: cachePolicy, namespace: namespace)
    } catch {
      guard error is URLError,
        let data = try await offlineStore().read(
          path: path, query: query, limit: CoverImageImport.byteLimit)
      else { throw error }
      return data
    }
  }

  func audioChunk(
    bookID: Int, assetID: String, format: String, offset: Int64, length: Int,
    expectedSize: Int64?, generation: UUID
  ) async throws -> AudioByteChunk {
    do {
      return try await audioChunkOnline(
        bookID: bookID, assetID: assetID, format: format,
        offset: offset, length: length, expectedSize: expectedSize, generation: generation)
    } catch {
      guard error is URLError else { throw error }
      return try await localAudioChunk(
        path: "audiobooks/\(bookID)/assets/\(assetID)/content",
        query: [], offset: offset, length: length, expectedSize: expectedSize,
        mimeType: AudioStreamFormat.mimeTypes[format] ?? "application/octet-stream",
        generation: generation)
    }
  }

  func recordedAudioChunk(
    bookID: Int, fileID: Int, clip: EpubMediaOverlayClip, offset: Int64, length: Int,
    expectedSize: Int64?, generation: UUID
  ) async throws -> AudioByteChunk {
    do {
      return try await recordedAudioChunkOnline(
        bookID: bookID, fileID: fileID, clip: clip,
        offset: offset, length: length, expectedSize: expectedSize, generation: generation)
    } catch {
      guard error is URLError else { throw error }
      return try await localAudioChunk(
        path: "epub/\(bookID)/file/\(clip.audioHref)",
        query: [URLQueryItem(name: "fileId", value: String(fileID))], offset: offset,
        length: length,
        expectedSize: expectedSize, mimeType: clip.audioMimeType, generation: generation)
    }
  }

  private func localAudioChunk(
    path: String, query: [URLQueryItem], offset: Int64, length: Int, expectedSize: Int64?,
    mimeType: String, generation: UUID
  ) async throws -> AudioByteChunk {
    try ensureSession(generation)
    guard offset >= 0, (1...AudioStreamFormat.chunkLimit).contains(length),
      let file = try await offlineStore().verifiedURL(path: path, query: query),
      let count = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      expectedSize.map({ $0 == Int64(count) }) ?? true, offset <= Int64(count) - Int64(length)
    else { throw ConnectionError.fileChanged }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(offset))
    let data = try handle.read(upToCount: length) ?? Data()
    guard data.count == length else { throw ConnectionError.fileChanged }
    return AudioByteChunk(
      data: data, totalBytes: Int64(count), mimeType: mimeType,
      sourceValidator: "offline-\(file.lastPathComponent)")
  }

  func downloadOfflineResource(
    _ input: OfflineResource, destination: URL,
    expectedPublicationRevision: String? = nil,
    progress: @MainActor @Sendable (BookFileTransferProgress) -> Void
  ) async throws -> OfflineResource {
    let generation = try authenticatedSessionGeneration()
    var resource = input
    let partial = destination.appendingPathExtension("partial")
    let transfer = destination.appendingPathExtension("transfer")
    if expectedPublicationRevision != nil {
      try? FileManager.default.removeItem(at: partial)
      try? FileManager.default.removeItem(at: transfer)
    }
    if let data = try? Data(contentsOf: transfer), data.count < 64 * 1024,
      let retained = try? JSONDecoder().decode(OfflineResource.self, from: data),
      retained.id == input.id,
      retained.expectedBytes == input.expectedBytes || input.expectedBytes == nil
    {
      resource.validator = retained.validator
      resource.expectedBytes = retained.expectedBytes
      resource.sourceDigest = retained.sourceDigest
    }
    var offset = Int64((try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    if resource.validator == nil || resource.expectedBytes.map({ offset >= $0 }) ?? false {
      try? FileManager.default.removeItem(at: partial)
      offset = 0
    }
    var request = URLRequest(
      url: profile.endpoint(resource.path, query: resource.query.map(\.item)))
    request.timeoutInterval = 120
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
    if offset > 0 {
      request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
      request.setValue(resource.validator, forHTTPHeaderField: "If-Range")
    }
    try ensureSession(generation)
    var delivery = try await networkBytes(for: request)
    if (delivery.1 as? HTTPURLResponse)?.statusCode == 401 {
      delivery.0.task.cancel()
      request.setValue(
        "Bearer \(try await refresh().accessToken)", forHTTPHeaderField: "Authorization")
      delivery = try await networkBytes(for: request)
    }
    let (bytes, response) = delivery
    defer { bytes.task.cancel() }
    guard let response = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
    try validate(response)
    if response.statusCode == 200 { offset = 0 }
    let total = response.expectedContentLength + offset
    guard [200, 206].contains(response.statusCode), response.expectedContentLength >= 0,
      total >= 0, total <= OfflineResourceStore.byteLimit,
      resource.expectedBytes.map({ $0 == total }) ?? true,
      offset == 0
        || (response.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(offset)-")
          == true
          && response.value(forHTTPHeaderField: "ETag") == resource.validator)
    else { throw ConnectionError.fileChanged }
    resource.expectedBytes = total
    resource.validator = response.value(forHTTPHeaderField: "ETag")
    resource.sourceDigest = response.value(forHTTPHeaderField: "X-Content-SHA256")
    if let digest = resource.sourceDigest {
      guard digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
        resource.validator == "\"\(digest)\""
      else { throw ConnectionError.invalidResponse }
    }
    try await offlineStore().reserveTransfer(destination: destination, total: total)
    try await offlineStore().saveTransfer(resource, destination: destination)
    if offset == 0 {
      guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
        throw ConnectionError.insufficientStorage
      }
    }
    let handle = try FileHandle(forWritingTo: partial)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(offset))
    var received = offset
    var buffer = Data()
    buffer.reserveCapacity(64 * 1024)
    await progress(.init(received: received, total: total))
    for try await byte in bytes {
      guard received < total else { throw ConnectionError.fileChanged }
      buffer.append(byte)
      received += 1
      if buffer.count == 64 * 1024 {
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
        await progress(.init(received: received, total: total))
        try Task.checkCancellation()
        try ensureSession(generation)
      }
    }
    if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
    try handle.synchronize()
    try Task.checkCancellation()
    try ensureSession(generation)
    guard received == total else { throw ConnectionError.fileChanged }
    guard expectedPublicationRevision.map({ $0 == resource.sourceDigest }) ?? true else {
      throw ConnectionError.fileChanged
    }
    try handle.close()
    resource = try await offlineStore().publish(
      resource, partial: partial, destination: destination,
      knownPublication: expectedPublicationRevision != nil)
    try await offlineStore().finishTransfer(destination: destination)
    await progress(.init(received: received, total: total))
    return resource
  }

  private func ensureSession(_ generation: UUID) throws {
    guard generation == sessionGeneration, saved != nil else {
      throw ConnectionError.expiredSession
    }
  }

  private func epubResourceOnline(
    bookID: Int, fileID: Int, path: String, expectedSize: Int?, byteLimit: Int = 8 * 1024 * 1024,
    session: UUID? = nil
  ) async throws -> Data {
    guard (1...(8 * 1024 * 1024)).contains(byteLimit) else {
      throw ConnectionError.resourceTooLarge
    }
    let limit = byteLimit
    if let expectedSize, !(0...limit).contains(expectedSize) {
      throw ConnectionError.resourceTooLarge
    }
    let generation = session ?? sessionGeneration
    try ensureSession(generation)
    var request = URLRequest(
      url: profile.endpoint(
        "epub/\(bookID)/file/\(path)", query: [URLQueryItem(name: "fileId", value: String(fileID))])
    )
    request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
    try ensureSession(generation)
    var delivery = try await networkBytes(for: request)
    if (delivery.1 as? HTTPURLResponse)?.statusCode == 401 {
      delivery.0.task.cancel()
      let credentials = try await refresh()
      try ensureSession(generation)
      request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
      delivery = try await networkBytes(for: request)
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
    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await transport.data(for: request)
      isOffline = false
    } catch {
      if error is URLError { isOffline = true }
      throw error
    }
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
