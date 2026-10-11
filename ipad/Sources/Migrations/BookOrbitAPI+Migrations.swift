import Foundation

extension BookOrbitAPI {
  func migrationState(session: UUID) async throws -> MigrationWorkflowStateApi {
    try await boundedJSON(
      "migration/state", byteLimit: 8 * 1024 * 1024, session: session, expectedStatus: 200)
  }

  func migrationCreateSource(_ payload: CreateMigrationSourcePayload, session: UUID) async throws
    -> MigrationSourceApi
  {
    try await boundedJSON(
      "migration/sources", method: "POST", body: JSONEncoder().encode(payload), session: session,
      expectedStatus: 201)
  }

  func migrationCreateProfile(_ payload: CreateMigrationProfilePayload, session: UUID) async throws
    -> MigrationProfileApi
  {
    try await boundedJSON(
      "migration/profiles", method: "POST", body: JSONEncoder().encode(payload), session: session,
      expectedStatus: 201)
  }

  func migrationDryRun(profileID: Int, session: UUID) async throws -> MigrationPlanArtifactApi {
    try await boundedJSON(
      "migration/plans/dry-run", method: "POST",
      body: JSONEncoder().encode(CreateMigrationDryRunPayload(profileId: profileID)),
      byteLimit: 8 * 1024 * 1024, session: session, expectedStatus: 201)
  }

  func migrationRun(planID: Int, session: UUID) async throws -> MigrationRunApi {
    try await boundedJSON(
      "migration/runs/live", method: "POST",
      body: JSONEncoder().encode(StartMigrationRunPayload(planArtifactId: planID)),
      session: session, expectedStatus: 201)
  }

  func migrationProgress(runID: Int, session: UUID) async throws -> MigrationRunProgressApi {
    try await boundedJSON("migration/runs/\(runID)/progress", session: session, expectedStatus: 200)
  }

  func migrationReport(runID: Int, session: UUID) async throws -> MigrationRunReportApi {
    try await boundedJSON(
      "migration/runs/\(runID)/report", byteLimit: 8 * 1024 * 1024, session: session,
      expectedStatus: 200)
  }

  func migrationCandidates(planID: Int, targetBookID: Int, offset: Int, session: UUID) async throws
    -> MigrationDuplicateCandidatePageApi
  {
    try await boundedJSON(
      "migration/plans/\(planID)/duplicates/\(targetBookID)/candidates?offset=\(offset)&limit=40",
      session: session, expectedStatus: 200)
  }

  func migrationReportPage(runID: Int, kind: String, offset: Int, session: UUID) async throws
    -> MigrationReportPageApi
  {
    try await boundedJSON(
      "migration/runs/\(runID)/report/details?kind=\(kind)&offset=\(offset)&limit=40",
      session: session, expectedStatus: 200)
  }
}
