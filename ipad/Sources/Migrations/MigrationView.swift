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
                    if !duplicate.selected.isEmpty,
                      !duplicate.candidates.contains(duplicate.selected)
                    {
                      Text("Selected source \(duplicate.selected)").tag(duplicate.selected)
                    }
                    ForEach(duplicate.candidates, id: \.self) { Text($0).tag($0) }
                  }.disabled(model.busy)
                  Text(
                    pageRange(
                      offset: duplicate.offset, count: duplicate.candidates.count,
                      total: duplicate.total)
                  )
                  .accessibilityIdentifier("migrationCandidateRange\(duplicate.id)")
                  if duplicate.loading { ProgressView("Loading source candidates") }
                  if let error = duplicate.error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry source candidates") {
                      Task {
                        await model.loadCandidates(
                          targetBookID: duplicate.id, offset: duplicate.requestedOffset)
                      }
                    }.disabled(model.busy)
                  }
                  HStack {
                    Button("Previous sources") {
                      Task {
                        await model.loadCandidates(
                          targetBookID: duplicate.id,
                          offset: max(0, duplicate.offset - duplicate.limit))
                      }
                    }.disabled(duplicate.offset == 0 || model.busy)
                      .accessibilityIdentifier("migrationPreviousCandidates\(duplicate.id)")
                    Button("Next sources") {
                      if let offset = duplicate.nextOffset {
                        Task {
                          await model.loadCandidates(targetBookID: duplicate.id, offset: offset)
                        }
                      }
                    }.disabled(duplicate.nextOffset == nil || model.busy)
                      .accessibilityIdentifier("migrationNextCandidates\(duplicate.id)")
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
      Picker("Report section", selection: $model.reportKind) {
        Text("Matched books").tag("matched")
        Text("Unresolved books").tag("unresolved")
        Text("Duplicate matches").tag("duplicate")
        Text("Users").tag("users")
      }.disabled(model.busy || model.reportLoading)
        .accessibilityIdentifier("migrationReportKind")
        .onChange(of: model.reportKind, reportKindChanged)
      if model.reportLoading { ProgressView("Loading report details") }
      if let error = model.reportError {
        Text(error).foregroundStyle(.secondary)
        Button("Retry report details", action: reloadReport).disabled(model.busy)
      }
      if let page = model.reportPage, page.kind == model.reportKind, page.runId == report.run.id {
        LabeledContent(
          "Report items shown",
          value: pageRange(offset: page.offset, count: page.items.count, total: page.total)
        )
        .accessibilityIdentifier("migrationReportRange")
        ForEach(Array(page.items.enumerated()), id: \.offset) { _, row in
          if page.kind == "matched", case .number(let target) = row["targetBookId"] {
            NavigationLink {
              BookDetailView(
                api: model.api, bookID: Int(target),
                canEditMetadata: model.user.hasPermission(.libraryEditMetadata),
                canRead: model.user.hasPermission(.libraryDownload), userID: model.user.id)
            } label: {
              reportRow(row)
            }.accessibilityIdentifier("migrationBook\(Int(target))")
          } else {
            reportRow(row).accessibilityIdentifier("migrationReportItem")
          }
        }
        HStack {
          Button("Previous report items", action: previousReport).disabled(
            page.offset == 0 || model.busy || model.reportLoading
          )
          .accessibilityIdentifier("migrationPreviousReport")
          Button("Next report items", action: nextReport).disabled(
            page.nextOffset == nil || model.busy || model.reportLoading
          )
          .accessibilityIdentifier("migrationNextReport")
        }
      }
    }.accessibilityIdentifier("migrationReport")
  }

  @ViewBuilder
  private var matchPreview: some View {
    Picker("Preview section", selection: $model.previewKind) {
      Text("Matched books").tag("matched")
      Text("Unresolved books").tag("unresolved")
      Text("Duplicate matches").tag("duplicate")
    }.disabled(model.busy)
      .accessibilityIdentifier("migrationPreviewKind")
      .onChange(of: model.previewKind, previewKindChanged)
    if model.matchLoading { ProgressView("Loading preview") }
    if let error = model.matchError {
      Text(error).foregroundStyle(.secondary)
      Button("Retry preview", action: reloadMatches).disabled(model.busy)
    }
    if let page = model.matchPage, page.kind == model.previewKind {
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
    if case .string(let reason) = row["reason"] { parts.append(reason) }
    return parts.joined(separator: ": ")
  }
  private func pageRange(offset: Int, count: Int, total: Int) -> String {
    count == 0 ? "0 of \(total)" : "\(offset + 1)-\(offset + count) of \(total)"
  }
  private func reportString(_ key: String, in row: [String: JSONValue]) -> String? {
    if case .string(let value) = row[key] { return value }
    return nil
  }
  private func reportRow(_ row: [String: JSONValue]) -> some View {
    VStack(alignment: .leading) {
      Text(
        reportString("targetTitle", in: row) ?? reportString("title", in: row)
          ?? reportString("username", in: row) ?? matchDescription(row))
      if let reason = reportString("reason", in: row) {
        Text(reason).font(.caption).foregroundStyle(.secondary)
      } else if let strategy = reportString("strategy", in: row) {
        Text("Matched by \(strategy)").font(.caption).foregroundStyle(.secondary)
      }
    }
  }
  private func previewKindChanged() { Task { await model.loadMatches() } }
  private func reportKindChanged() { Task { await model.loadReport() } }
  private func reloadMatches() {
    Task { await model.loadMatches(offset: model.matchRequestedOffset) }
  }
  private func reloadReport() {
    Task { await model.loadReport(offset: model.reportRequestedOffset) }
  }
  private func previousReport() {
    Task {
      await model.loadReport(
        offset: max(0, (model.reportPage?.offset ?? 0) - (model.reportPage?.limit ?? 40)))
    }
  }
  private func nextReport() {
    if let offset = model.reportPage?.nextOffset { Task { await model.loadReport(offset: offset) } }
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
