import Foundation
import Observation

@MainActor @Observable
final class MigrationModel {
  let api: BookOrbitAPI
  let user: AuthUser
  var draft = MigrationSourceDraft()
  var types: [String] = []
  var targetUsers: [MigrationTargetUser] = []
  var userMappings: [MigrationUserMapping] = []
  var sourceUserNames: [String: String] = [:]
  var pathMappings: [MigrationPathMapping] = []
  var source: MigrationSourceApi?
  var profile: MigrationProfileApi?
  var plan: MigrationPlanArtifactApi?
  var run: MigrationRunApi?
  var progress: MigrationRunProgressApi?
  var report: MigrationRunReportApi?
  var duplicates: [MigrationDuplicateChoice] = []
  var matchPage: MigrationPlanPageApi?
  var previewKind = "matched"
  var busy = false
  var message: String?
  var denied = false
  private var session: UUID?
  private var attached = true
  private var runRevision = 0

  init(api: BookOrbitAPI, user: AuthUser) {
    self.api = api
    self.user = user
  }
  var running: Bool { run?.state == "running" }
  var sourceSaved: Bool {
    source?.type == draft.type && source?.name == draft.name
      && source?.connectionConfig == draft.connectionConfig
  }
  var mappingsSaved: Bool {
    guard let profile else { return false }
    return profile.userMappings.map {
      MigrationUserMapping(sourceUserId: $0.sourceUserId, targetUserId: $0.targetUserId)
    } == userMappings
      && profile.pathMappings.map {
        MigrationPathMapping(sourcePrefix: $0.sourcePrefix, targetPrefix: $0.targetPrefix)
      } == pathMappings
  }
  var canApply: Bool {
    plan != nil && duplicates.isEmpty && !busy && !running && run == nil && sourceSaved
      && mappingsSaved
  }

  func load() async {
    await perform {
      self.session = try await self.api.authenticatedSessionGeneration()
      let types: [String] = try await self.read("migration/supported-types")
      self.types = types
      self.targetUsers = try await self.read("migration/target-users")
      try await self.restore()
    }
  }

  private func restore() async throws {
    runRevision += 1
    guard let session else { throw ConnectionError.expiredSession }
    let state = try await api.migrationState(session: session)
    try await checkSession()
    if let active = state.active {
      source = active.source
      profile = active.profile
      plan = active.plan
      run = active.run
      draft.receive(active.source)
      userMappings =
        active.profile?.userMappings.map {
          MigrationUserMapping(sourceUserId: $0.sourceUserId, targetUserId: $0.targetUserId)
        } ?? []
      pathMappings =
        active.profile?.pathMappings.map {
          MigrationPathMapping(sourcePrefix: $0.sourcePrefix, targetPrefix: $0.targetPrefix)
        } ?? []
      if run == nil { try await loadMappings() }
      receiveDuplicates()
      try await loadMatchPage(offset: 0)
      if let run { try await refresh(runID: run.id) }
    }
  }

  func saveSource() async {
    await perform {
      guard let session = self.session else { throw ConnectionError.expiredSession }
      self.source = try await self.api.migrationCreateSource(
        CreateMigrationSourcePayload(
          type: self.draft.type, name: self.draft.name,
          connectionConfig: self.draft.connectionConfig), session: session)
      try await self.checkSession()
      if let source = self.source { self.draft.receive(source) }
      self.profile = nil
      self.plan = nil
      self.run = nil
      self.report = nil
      self.progress = nil
      self.userMappings = []
      self.pathMappings = []
      self.duplicates = []
      self.matchPage = nil
      try await self.loadMappings()
      self.message = "Source validated. Choose user and server path mappings."
    }
  }

  private func loadMappings() async throws {
    guard let source else { return }
    let suggestions: MigrationMappingSuggestions = try await read(
      "migration/sources/\(source.id)/user-mapping-suggestions")
    sourceUserNames = Dictionary(
      uniqueKeysWithValues: suggestions.suggestions.map { ($0.sourceUserId, $0.username) })
    if userMappings.isEmpty {
      userMappings = suggestions.suggestions.map {
        MigrationUserMapping(sourceUserId: $0.sourceUserId, targetUserId: $0.suggestedTargetUserId)
      }
    }
  }

  func preview() async {
    await perform {
      guard let source = self.source, let session = self.session else {
        throw ConnectionError.invalidResponse
      }
      self.profile = try await self.api.migrationCreateProfile(
        CreateMigrationProfilePayload(
          sourceId: source.id, name: "iPad migration", userMappings: self.userMappings,
          pathMappings: self.pathMappings), session: session)
      if !self.pathMappings.isEmpty {
        let _: JSONValue = try await self.read(
          "migration/sources/\(source.id)/path-mappings/validate", method: "POST",
          body: JSONEncoder().encode([
            "pathMappings": JSONValue.array(
              self.pathMappings.map {
                .object([
                  "sourcePrefix": .string($0.sourcePrefix),
                  "targetPrefix": .string($0.targetPrefix),
                ])
              })
          ]))
      }
      guard let profile = self.profile else { throw ConnectionError.invalidResponse }
      self.plan = try await self.api.migrationDryRun(profileID: profile.id, session: session)
      try await self.checkSession()
      self.receiveDuplicates()
      try await self.loadMatchPage(offset: 0)
      self.message = "Dry-run complete. Review matches before applying."
    }
  }

  func resolveDuplicates() async {
    await perform {
      guard let plan = self.plan, self.duplicates.allSatisfy({ !$0.selected.isEmpty }) else {
        throw ConnectionError.invalidResponse
      }
      let payload: [String: JSONValue] = [
        "resolutions": .array(
          self.duplicates.map {
            .object([
              "targetBookId": .number(Double($0.id)), "selectedSourceBookId": .string($0.selected),
            ])
          })
      ]
      self.plan = try await self.read(
        "migration/plans/\(plan.id)/resolve-duplicates", method: "POST",
        body: JSONEncoder().encode(payload))
      self.receiveDuplicates()
    }
  }

  func apply() async {
    await perform {
      guard self.sourceSaved, self.mappingsSaved, self.duplicates.isEmpty, self.run == nil,
        let plan = self.plan,
        let session = self.session
      else { throw ConnectionError.invalidResponse }
      self.runRevision += 1
      self.report = nil
      self.progress = nil
      do { self.run = try await self.api.migrationRun(planID: plan.id, session: session) } catch {
        try await self.restore()
        throw error
      }
      try await self.checkSession()
    }
  }

  func cancel() async { await changeRun("cancel") }
  func retry() async { await changeRun("retry") }
  private func changeRun(_ action: String) async {
    await perform {
      guard let run = self.run else { throw ConnectionError.invalidResponse }
      self.runRevision += 1
      if action == "retry" {
        self.report = nil
        self.progress = nil
      }
      self.run = try await self.read("migration/runs/\(run.id)/\(action)", method: "POST")
      try await self.refresh(runID: run.id)
    }
  }

  func poll() async {
    while attached, running, !Task.isCancelled {
      guard let run else { return }
      do {
        try await refresh(runID: run.id)
        try await Task.sleep(for: .seconds(2))
      } catch is CancellationError { return } catch {
        message = "Connection interrupted. Reload to reconcile the server run before retrying."
        return
      }
    }
  }

  func reload() async { await perform { try await self.restore() } }
  private func refresh(runID: Int) async throws {
    guard let session else { throw ConnectionError.expiredSession }
    let revision = runRevision
    let value = try await api.migrationProgress(runID: runID, session: session)
    try await checkSession()
    guard revision == runRevision else { return }
    let currentReport: MigrationRunReportApi?
    if value.run.state != "running" {
      currentReport = try await api.migrationReport(runID: runID, session: session)
      try await checkSession()
    } else {
      currentReport = nil
    }
    guard revision == runRevision else { return }
    progress = value
    report = currentReport
    run = value.run
  }

  private func receiveDuplicates() {
    guard case .array(let rows) = plan?.plan["duplicateBookMatches"] else {
      duplicates = []
      return
    }
    duplicates = rows.compactMap { row in
      guard case .object(let fields) = row, case .number(let id) = fields["targetBookId"],
        case .array(let sourceIDs) = fields["sourceBookIds"]
      else { return nil }
      return MigrationDuplicateChoice(
        id: Int(id),
        candidates: sourceIDs.compactMap {
          if case .string(let id) = $0 { return id }
          return nil
        })
    }
  }

  private func read<T: Decodable & Sendable>(
    _ path: String, method: String = "GET", body: Data? = nil
  ) async throws -> T {
    guard let session else { throw ConnectionError.expiredSession }
    let value: T = try await api.boundedJSON(
      path, method: method, body: body, byteLimit: 8 * 1024 * 1024, session: session)
    try await checkSession()
    return value
  }

  private func checkSession() async throws {
    guard attached, let session, try await api.authenticatedSessionGeneration() == session else {
      throw ConnectionError.expiredSession
    }
  }

  private func perform(_ action: () async throws -> Void) async {
    guard !busy, attached else { return }
    busy = true
    message = nil
    defer { busy = false }
    do { try await action() } catch {
      if case ConnectionError.denied = error { denied = true }
      if case ConnectionError.expiredSession = error {
        denied = true
        draft.clearSecrets()
      }
      message = error.localizedDescription
    }
  }

  func configureAnother() {
    guard !running, !busy else { return }
    runRevision += 1
    draft = MigrationSourceDraft()
    source = nil
    profile = nil
    plan = nil
    run = nil
    userMappings = []
    pathMappings = []
    duplicates = []
    report = nil
    progress = nil
    matchPage = nil
    message =
      "Configure a new source and create a fresh dry-run before applying."
  }

  func loadMatches(offset: Int = 0) async {
    await perform { try await self.loadMatchPage(offset: offset) }
  }
  private func loadMatchPage(offset: Int) async throws {
    guard let plan else { return }
    matchPage = try await read(
      "migration/plans/\(plan.id)/matches?kind=\(previewKind)&offset=\(offset)&limit=40")
  }

  func detach() {
    attached = false
    draft.clearSecrets()
    session = nil
  }
}
