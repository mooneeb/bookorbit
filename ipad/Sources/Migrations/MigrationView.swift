import SwiftUI

struct MigrationView: View {
  @State private var model: MigrationModel
  @Environment(\.dismiss) private var dismiss

  init(api: BookOrbitAPI, user: AuthUser) {
    _model = State(initialValue: MigrationModel(api: api, user: user))
  }

  var body: some View {
    NavigationStack {
      List {
        if model.denied {
          Section {
            Text("Your account no longer has access to this migration.").accessibilityIdentifier(
              "migrationDenied")
          }
        } else {
          if model.run == nil {
            sourceFields
          } else if let source = model.source {
            Section("Source") {
              LabeledContent("Provider", value: providerName(source.type))
              LabeledContent("Name", value: source.name)
            }
          }
          if model.source != nil, model.run == nil { mappings }
          if let plan = model.plan, model.run == nil {
            Section("Dry-run") {
              LabeledContent("Matched books", value: String(plan.summary.matchedBooks ?? 0))
              LabeledContent("Unresolved books", value: String(plan.summary.unresolvedBooks ?? 0))
              Text(
                "Matching uses ISBN, ASIN, file hash, mapped paths, then title and author. Unmatched books are reported and skipped."
              ).fixedSize(horizontal: false, vertical: true)
              Text("Existing newer reading data and passage notes are preserved.").fixedSize(
                horizontal: false, vertical: true)
              if !model.duplicates.isEmpty {
                ForEach($model.duplicates) { $duplicate in
                  Picker("Source for book \(duplicate.id)", selection: $duplicate.selected) {
                    Text("Choose source").tag("")
                    ForEach(duplicate.candidates, id: \.self) { Text($0).tag($0) }
                  }
                }
                Button("Resolve duplicate matches", action: resolve).accessibilityIdentifier(
                  "migrationResolveDuplicates"
                )
                .disabled(model.busy || model.duplicates.contains { $0.selected.isEmpty })
              }
              matchPreview
              Button("Apply reviewed migration", action: apply).accessibilityIdentifier(
                "migrationApply"
              )
              .disabled(!model.canApply)
            }.accessibilityIdentifier("migrationDryRun")
          }
          if let run = model.run { runSection(run) }
          if let report = model.report, report.run.id == model.run?.id,
            model.run?.state != "running"
          {
            reportSection(report)
          }
        }
        if model.busy {
          ProgressView("Contacting server").accessibilityIdentifier("migrationLoading")
        }
        if let message = model.message {
          Section {
            Text(message).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(
              "migrationMessage")
          }
        }
      }
      .navigationTitle("Migrations")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done", action: dismiss.callAsFunction)
        }
      }
      .task { await model.load() }
      .task(id: model.run.map { "\($0.id)-\($0.state)" }) { await model.poll() }
    }
    .onDisappear { model.detach() }
  }

  private func runSection(_ run: MigrationRunApi) -> some View {
    Section("Migration run \(run.id)") {
      LabeledContent("Run ID") {
        Text(String(run.id)).accessibilityIdentifier("migrationRunID")
      }.accessibilityElement(children: .contain)
      LabeledContent("State") {
        Text(run.state).accessibilityIdentifier("migrationRunState")
      }.accessibilityElement(children: .contain)
      if let stage = run.currentStage {
        LabeledContent("Stage") { Text(stage).accessibilityIdentifier("migrationRunStage") }
      }
      if let progress = model.progress {
        LabeledContent("Processed", value: String(progress.totals.processed))
        LabeledContent("Imported", value: String(progress.totals.imported))
        LabeledContent("Skipped", value: String(progress.totals.skipped))
        LabeledContent("Failed", value: String(progress.totals.failed))
      }
      if model.running {
        Button("Stop migration", action: cancel).accessibilityIdentifier("migrationCancel")
      }
      if run.state == "failed" {
        Button("Retry migration", action: retry).accessibilityIdentifier("migrationRetry")
      }
      if !model.running {
        Button("Configure another migration", action: configureAnother)
          .accessibilityIdentifier("migrationConfigureAnother")
      }
      Button("Reload server state", action: reload).accessibilityIdentifier(
        "migrationReload")
      if let error = run.errorMessage {
        Text(error).fixedSize(horizontal: false, vertical: true)
      }
    }.accessibilityIdentifier("migrationProgress")
  }

  private func reportSection(_ report: MigrationRunReportApi) -> some View {
    Section("Report") {
      Text(
        "Imported \(report.totals.imported), skipped \(report.totals.skipped), unresolved \(report.totals.unresolved), failed \(report.totals.failed)"
      )
      .accessibilityIdentifier("migrationReportSummary")
      ForEach(Array(report.details.matchedBooks.enumerated()), id: \.offset) { _, match in
        NavigationLink {
          BookDetailView(
            api: model.api, bookID: match.targetBookId,
            canEditMetadata: model.user.hasPermission(.libraryEditMetadata),
            canRead: model.user.hasPermission(.libraryDownload), userID: model.user.id)
        } label: {
          VStack(alignment: .leading) {
            Text(match.targetTitle ?? "Book \(match.targetBookId)")
            Text("Matched by \(match.strategy)").font(.caption).foregroundStyle(.secondary)
          }
        }.accessibilityIdentifier("migrationBook\(match.targetBookId)")
      }
      ForEach(Array(report.details.unresolvedBooks.enumerated()), id: \.offset) { _, row in
        VStack(alignment: .leading) {
          Text(row.title ?? row.sourceBookId)
          Text(row.reason).font(.caption).foregroundStyle(.secondary)
        }
      }
      DisclosureGroup("Browse all matched books") { matchPreview }
    }.accessibilityIdentifier("migrationReport")
  }

  @ViewBuilder
  private var matchPreview: some View {
    if let page = model.matchPage {
      LabeledContent("Matches shown") {
        Text(
          page.items.isEmpty
            ? "0 of \(page.total)"
            : "\(page.offset + 1)-\(page.offset + page.items.count) of \(page.total)"
        )
        .accessibilityIdentifier("migrationMatchRange")
      }
      ForEach(Array(page.items.enumerated()), id: \.offset) { _, row in
        if let run = model.run, run.state == "completed",
          case .number(let target) = row["targetBookId"]
        {
          NavigationLink {
            BookDetailView(
              api: model.api, bookID: Int(target),
              canEditMetadata: model.user.hasPermission(.libraryEditMetadata),
              canRead: model.user.hasPermission(.libraryDownload), userID: model.user.id)
          } label: {
            Text(matchDescription(row))
          }.accessibilityIdentifier("migrationPagedBook\(Int(target))")
        } else {
          Text(matchDescription(row)).accessibilityIdentifier("migrationPreviewMatch")
        }
      }
      HStack {
        Button("Previous matches", action: previousMatches).disabled(
          page.offset == 0 || model.busy
        ).accessibilityIdentifier("migrationPreviousMatches")
        Button("Next matches", action: nextMatches).disabled(
          page.nextOffset == nil || model.busy
        ).accessibilityIdentifier("migrationNextMatches")
      }
    }
  }

  private var sourceFields: some View {
    Section("Source configuration") {
      Text(
        "Scan the provider's book files into a server library first. Migration matches those files and imports their metadata and permitted reading data. All paths below belong to your BookOrbit server."
      )
      .fixedSize(horizontal: false, vertical: true)
      Picker("Provider", selection: $model.draft.type) {
        ForEach(model.types, id: \.self) { Text(providerName($0)).tag($0) }
      }.accessibilityIdentifier("migrationProvider")
      TextField("Source name", text: $model.draft.name).accessibilityIdentifier(
        "migrationSourceName")
      if model.draft.type == "audiobookshelf" {
        Picker("Connection mode", selection: $model.draft.mode) {
          Text("API").tag("api")
          Text("Backup").tag("backup")
        }
        .accessibilityIdentifier("migrationABSMode")
        if model.draft.mode == "api" {
          TextField("Server URL", text: $model.draft.baseURL).textInputAutocapitalization(.never)
            .autocorrectionDisabled().accessibilityIdentifier("migrationBaseURL")
          SecureField("API token", text: $model.draft.apiToken).accessibilityIdentifier(
            "migrationAPIToken")
          Toggle("Allow private network", isOn: $model.draft.allowPrivateNetwork)
        } else {
          TextField("Server backup path", text: $model.draft.backupPath).accessibilityIdentifier(
            "migrationBackupPath")
        }
      } else if model.draft.type == "calibre_web_automated" {
        Text("Stop the source before taking its SQLite snapshots.")
        TextField("Server app database path", text: $model.draft.appDatabasePath)
          .accessibilityIdentifier("migrationAppDatabasePath")
        TextField("Server metadata database path", text: $model.draft.metadataDatabasePath)
          .accessibilityIdentifier("migrationMetadataDatabasePath")
      } else {
        TextField("Database host", text: $model.draft.host).accessibilityIdentifier("migrationHost")
        TextField("Database port", text: $model.draft.port).keyboardType(.numberPad)
          .accessibilityIdentifier("migrationPort")
        TextField("Database name", text: $model.draft.database).accessibilityIdentifier(
          "migrationDatabase")
        TextField("Database user", text: $model.draft.username).accessibilityIdentifier(
          "migrationUsername")
        SecureField("Database password", text: $model.draft.password).accessibilityIdentifier(
          "migrationPassword")
        Toggle("Use TLS", isOn: $model.draft.ssl)
        TextField("Server media root path", text: $model.draft.mediaRootPath)
          .accessibilityIdentifier("migrationMediaRootPath")
      }
      Button("Validate and save source", action: save).accessibilityIdentifier(
        "migrationSaveSource"
      )
      .disabled(
        model.busy || model.running || model.run != nil
          || model.draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
    }.disabled(model.running || model.run != nil)
  }

  private var mappings: some View {
    Section("Mappings") {
      ForEach($model.userMappings, id: \.sourceUserId) { $mapping in
        Picker(
          model.sourceUserNames[mapping.sourceUserId] ?? mapping.sourceUserId,
          selection: $mapping.targetUserId
        ) {
          Text("Do not import this user").tag(nil as Int?)
          ForEach(model.targetUsers, id: \.id) { Text($0.username).tag(Optional($0.id)) }
        }.accessibilityIdentifier("migrationUser\(mapping.sourceUserId)")
      }
      ForEach(Array(model.pathMappings.indices), id: \.self) { index in
        TextField("Source path prefix", text: $model.pathMappings[index].sourcePrefix)
          .accessibilityIdentifier("migrationSourcePrefix\(index)")
        TextField("BookOrbit server path prefix", text: $model.pathMappings[index].targetPrefix)
          .accessibilityIdentifier("migrationTargetPrefix\(index)")
      }
      Button("Add path mapping", action: addMapping).accessibilityIdentifier(
        "migrationAddPathMapping")
      Button("Validate mappings and dry-run", action: preview).accessibilityIdentifier(
        "migrationPreview"
      )
      .disabled(
        model.busy || !model.sourceSaved || !model.userMappings.contains { $0.targetUserId != nil })
    }.disabled(model.busy)
  }

  private func providerName(_ type: String) -> String {
    switch type {
    case "booklore": "Booklore"
    case "grimmory": "Grimmory"
    case "audiobookshelf": "Audiobookshelf"
    case "calibre_web_automated": "Calibre-Web Automated"
    default: type
    }
  }
  private func matchDescription(_ row: [String: JSONValue]) -> String {
    var parts: [String] = []
    if case .string(let source) = row["sourceBookId"] { parts.append("Source \(source)") }
    if case .number(let target) = row["targetBookId"] { parts.append("Book \(Int(target))") }
    if case .string(let strategy) = row["strategy"] { parts.append(strategy) }
    return parts.joined(separator: ": ")
  }
  private func nextMatches() {
    if let offset = model.matchPage?.nextOffset { Task { await model.loadMatches(offset: offset) } }
  }
  private func previousMatches() {
    Task { await model.loadMatches(offset: max(0, (model.matchPage?.offset ?? 0) - 40)) }
  }
  private func configureAnother() { model.configureAnother() }
  private func addMapping() {
    model.pathMappings.append(MigrationPathMapping(sourcePrefix: "", targetPrefix: ""))
  }
  private func save() { Task { await model.saveSource() } }
  private func preview() { Task { await model.preview() } }
  private func resolve() { Task { await model.resolveDuplicates() } }
  private func apply() { Task { await model.apply() } }
  private func cancel() { Task { await model.cancel() } }
  private func retry() { Task { await model.retry() } }
  private func reload() { Task { await model.reload() } }
}
