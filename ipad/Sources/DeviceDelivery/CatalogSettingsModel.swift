import Foundation
import Observation

@MainActor @Observable
final class CatalogSettingsModel {
  let api: BookOrbitAPI
  let user: AuthUser
  private let selectedBookID: Int?
  private(set) var koreader: KoreaderSyncStatus?
  private(set) var opdsAccounts: [OpdsUser] = []
  private(set) var book: BookDetail?
  private(set) var progress: KoreaderBookSyncInfo?
  private(set) var isBusy = false
  private(set) var isMutating = false
  private(set) var rootURL: URL?
  private(set) var syncURL: URL?
  private(set) var opdsURL: URL?
  private(set) var selectedScopeURL: URL?
  private(set) var selectedKOReaderURL: URL?
  private(set) var scopeName = "All books"
  var error: String?
  var result: String?
  var koreaderUsername = ""
  var koreaderPassword = ""
  var opdsUsername = ""
  var opdsPassword = ""
  var opdsSortOrder = "recent"
  private var requestID = UUID()

  init(api: BookOrbitAPI, user: AuthUser, book: BookDetail? = nil) {
    self.api = api
    self.user = user
    self.book = book
    selectedBookID = book?.id
  }

  var canKOReader: Bool { user.hasPermission(.koreaderSync) }
  var canOPDS: Bool { user.hasPermission(.opdsAccess) }
  var files: [BookDetailFile] { book?.files.filter { $0.role == "content" } ?? [] }
  var canSaveKOReader: Bool {
    !isMutating && (3...100).contains(koreaderUsername.count)
      && ((koreader?.credentials != nil && koreaderPassword.isEmpty)
        || (6...128).contains(koreaderPassword.count))
  }
  var canCreateOPDS: Bool {
    !isMutating && (3...100).contains(opdsUsername.count) && opdsPassword.count >= 8
      && !opdsUsername.contains(":")
  }

  func load() async {
    guard !isMutating else { return }
    let request = UUID()
    requestID = request
    isBusy = true
    error = nil
    defer { if requestID == request { isBusy = false } }
    rootURL = await api.catalogURL("koreader/plugin/catalog/root")
    syncURL = await api.catalogURL("koreader")
    opdsURL = await api.catalogURL("opds")
    if selectedScopeURL == nil { await selectScope(id: nil, name: "All books", smart: false) }
    if canKOReader {
      do {
        let status: KoreaderSyncStatus = try await api.boundedJSON("koreader/sync-status")
        guard requestID == request else { return }
        koreader = status
        koreaderUsername = status.credentials?.username ?? ""
        if let selectedBookID {
          let latestProgress: KoreaderBookSyncInfo? = try await api.boundedJSON(
            "koreader/books/\(selectedBookID)/progress")
          guard requestID == request else { return }
          progress = latestProgress
        }
      } catch { if requestID == request { self.error = error.localizedDescription } }
    }
    if canOPDS {
      do {
        let accounts: [OpdsUser] = try await api.boundedJSON("opds-users")
        guard requestID == request else { return }
        opdsAccounts = accounts
      } catch { if requestID == request { self.error = error.localizedDescription } }
    }
    if let selectedBookID {
      do {
        let fresh: BookDetail = try await api.boundedJSON("books/\(selectedBookID)")
        guard requestID == request else { return }
        book = fresh
      } catch {
        if requestID == request {
          book = nil
          self.error = error.localizedDescription
        }
      }
    }
  }

  func saveKOReader() async {
    guard canKOReader, canSaveKOReader else { return }
    await mutate {
      if self.koreader?.credentials != nil {
        let payload = UpdateKoreaderCredentialsPayload(
          username: self.koreaderUsername,
          password: self.koreaderPassword.isEmpty ? nil : self.koreaderPassword,
          syncEnabled: nil)
        try await self.api.sendEmpty(
          "koreader/credentials", method: "PATCH", body: JSONEncoder().encode(payload))
      } else {
        let payload = CreateKoreaderCredentialsPayload(
          username: self.koreaderUsername, password: self.koreaderPassword)
        try await self.api.sendEmpty(
          "koreader/credentials", method: "POST", body: JSONEncoder().encode(payload))
      }
      self.koreaderPassword = ""
      self.result = "KOReader credentials saved."
    }
  }

  func setKOReaderEnabled(_ enabled: Bool) async {
    guard canKOReader, koreader?.credentials != nil else { return }
    await mutate {
      let payload = UpdateKoreaderCredentialsPayload(
        username: nil, password: nil, syncEnabled: enabled)
      try await self.api.sendEmpty(
        "koreader/credentials", method: "PATCH", body: JSONEncoder().encode(payload))
      self.result = enabled ? "KOReader sync enabled." : "KOReader sync disabled."
    }
  }

  func deleteKOReader() async {
    guard canKOReader else { return }
    await mutate {
      try await self.api.sendEmpty("koreader/credentials", method: "DELETE")
      self.koreader = nil
      self.koreaderPassword = ""
      self.result = "KOReader credentials removed."
    }
  }

  func testKOReader() async {
    guard canKOReader, !koreaderPassword.isEmpty else { return }
    await mutate {
      let payload = CreateKoreaderCredentialsPayload(
        username: self.koreaderUsername, password: self.koreaderPassword)
      let response: TestKoreaderConnectionResult = try await self.api.boundedJSON(
        "koreader/test-connection", method: "POST", body: JSONEncoder().encode(payload))
      guard response.success else { throw ConnectionError.http(401) }
      self.koreaderPassword = ""
      self.result = "KOReader connection verified."
    }
  }

  func createOPDS() async {
    guard canOPDS, canCreateOPDS else { return }
    await mutate {
      let payload = CreateOpdsUserRequest(
        username: self.opdsUsername, password: self.opdsPassword, sortOrder: self.opdsSortOrder)
      let _: OpdsUser = try await self.api.boundedJSON(
        "opds-users", method: "POST", body: JSONEncoder().encode(payload))
      self.opdsPassword = ""
      self.result = "OPDS account created."
    }
  }

  func updateOPDS(_ account: OpdsUser, sortOrder: String) async {
    guard canOPDS else { return }
    await mutate {
      let payload = UpdateOpdsUserRequest(sortOrder: sortOrder)
      let _: OpdsUser = try await self.api.boundedJSON(
        "opds-users/\(account.id)", method: "PATCH", body: JSONEncoder().encode(payload))
      self.result = "OPDS sort order saved."
    }
  }

  func deleteOPDS(_ account: OpdsUser) async {
    guard canOPDS else { return }
    await mutate {
      try await self.api.sendEmpty("opds-users/\(account.id)", method: "DELETE")
      self.result = "OPDS account removed."
    }
  }

  func testOPDS() async {
    guard canOPDS, !opdsUsername.isEmpty, !opdsPassword.isEmpty else { return }
    await mutate {
      try await self.api.checkOPDS(username: self.opdsUsername, password: self.opdsPassword)
      self.opdsPassword = ""
      self.result = "OPDS connection verified."
    }
  }

  func selectScope(id: Int?, name: String, smart: Bool) async {
    let query =
      id.map { [URLQueryItem(name: smart ? "smartScopeId" : "collectionId", value: String($0))] }
      ?? []
    selectedScopeURL = await api.catalogURL("opds/catalog", query: query)
    selectedKOReaderURL = await api.catalogURL("koreader/plugin/catalog/manifest", query: query)
    scopeName = name
  }

  func fileURL(_ file: BookDetailFile, opds: Bool) async -> URL? {
    guard let book, files.contains(where: { $0.id == file.id }) else { return nil }
    if opds {
      return await api.catalogURL(
        "opds/\(book.id)/download", query: [URLQueryItem(name: "fileId", value: String(file.id))])
    }
    return await api.catalogURL("koreader/plugin/catalog/files/\(file.id)/download")
  }

  private func mutate(_ action: @MainActor () async throws -> Void) async {
    guard !isMutating else { return }
    requestID = UUID()
    isBusy = false
    isMutating = true
    error = nil
    result = nil
    do { try await action() } catch { self.error = error.localizedDescription }
    isMutating = false
    if error == nil { await load() }
  }
}
