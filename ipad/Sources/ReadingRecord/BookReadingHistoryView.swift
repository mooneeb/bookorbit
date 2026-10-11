import SwiftUI

struct BookReadingHistoryView: View {
  @State private var model: BookReadingHistoryModel
  @State private var showsManual = false
  @State private var showsHistoryEditor = false
  @State private var sessionToDelete: BookReadingSession?
  @State private var attemptToDelete: ReadingAttempt?
  @State private var confirmsReread = false
  @State private var showsRecovery = false
  @State private var resetProgress = false
  @Environment(\.dismiss) private var dismiss

  init(api: BookOrbitAPI, book: BookDetail) {
    _model = State(initialValue: BookReadingHistoryModel(api: api, book: book))
  }

  var body: some View {
    NavigationStack {
      List {
        if let error = model.error {
          Section { Text(error).accessibilityIdentifier("readingHistoryError") }
        }
        if let message = model.message {
          Section { Text(message).accessibilityIdentifier("readingHistorySyncState") }
        }
        Section {
          Button("Add manual session") { showsManual = true }
            .accessibilityIdentifier("readingHistoryAddManual")
          Button(
            model.hasHistoryDraft ? "Continue local history draft" : "Add past reading attempt"
          ) {
            model.beginHistory()
            showsHistoryEditor = true
          }.accessibilityIdentifier("readingHistoryAddAttempt")
          Button("Start reread") { confirmsReread = true }
            .accessibilityIdentifier("readingHistoryReread")
          Button("Retry pending reading records") { Task { await model.retryPending() } }
            .accessibilityIdentifier("readingHistoryRetryPending")
          Button("Review local reading recovery") { showsRecovery = true }
            .accessibilityIdentifier("readingHistoryRecovery")
        } header: {
          Text("Reading record").foregroundStyle(Color(uiColor: .label))
        }
        .tint(Color(uiColor: .label))
        if let result = model.sessions {
          Section {
            LabeledContent("Sessions", value: String(Int(result.stats.totalSessions)))
              .font(.body)
              .accessibilityIdentifier("readingHistorySessionCount")
            LabeledContent("Reading time", value: Self.duration(result.stats.totalSeconds))
              .font(.body)
              .accessibilityIdentifier("readingHistoryTotalTime")
            LabeledContent("Average session", value: Self.duration(result.stats.avgDurationSeconds))
              .font(.body)
            ForEach(result.stats.bySource, id: \.bucket) { source in
              LabeledContent(source.bucket.capitalized, value: Self.duration(source.totalSeconds))
            }
          } header: {
            Text("Session totals").foregroundStyle(Color(uiColor: .label))
          }
        }
        Section("Filters") {
          Picker("Format", selection: $model.format) {
            Text("All formats").tag("")
            ForEach(model.formats, id: \.self) { Text($0.uppercased()).tag($0) }
          }
          TextField("From YYYY-MM-DD", text: $model.dateFrom)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          TextField("Through YYYY-MM-DD", text: $model.dateTo)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          Picker("Sort sessions", selection: $model.sortBy) {
            Text("Started").tag("startedAt")
            Text("Duration").tag("durationSeconds")
            Text("Progress change").tag("progressDelta")
            Text("End progress").tag("endProgress")
          }
          Picker("Order", selection: $model.sortDir) {
            Text("Newest or highest first").tag("desc")
            Text("Oldest or lowest first").tag("asc")
          }
          Button("Apply filters") {
            model.page = 1
            Task { await model.load() }
          }
          .accessibilityIdentifier("readingHistoryApplyFilters")
        }
        if let result = model.sessions {
          Section("Sessions") {
            if result.items.isEmpty { Text("No reading sessions in this range.") }
            ForEach(result.items) { session in
              VStack(alignment: .leading, spacing: 8) {
                Text(session.startedAt).font(.headline)
                Text(
                  "\(Self.duration(Double(session.durationSeconds))) · \(session.source ?? "Unknown source") · \(session.sessionType ?? "read")"
                )
                if let progress = session.endProgress {
                  Text("End progress: \(progress, specifier: "%.1f")%")
                }
                if let format = session.format { Text(format.uppercased()) }
                if let attemptID = session.attemptId { Text("Reading attempt \(attemptID)") }
                if model.canDelete {
                  Button("Delete session", role: .destructive) { sessionToDelete = session }
                    .frame(minHeight: 44).accessibilityIdentifier(
                      "readingHistoryDeleteSession\(session.id)")
                }
              }.accessibilityElement(children: .contain)
                .accessibilityIdentifier("readingHistorySession\(session.id)")
            }
            pagination(
              page: model.page, total: result.total, size: result.pageSize, attempts: false)
          }
        }
        if let result = model.attempts {
          Section("Reading history") {
            if result.items.isEmpty { Text("No reading attempts yet.") }
            ForEach(result.items) { attempt in
              VStack(alignment: .leading, spacing: 8) {
                Text(attempt.outcome?.capitalized ?? "In progress").font(.headline)
                Text(
                  "\(attempt.startedOn ?? "Unknown start") to \(attempt.endedOn ?? "Still reading")"
                )
                Text(
                  "\(Int(attempt.totalSessions)) sessions · \(Self.duration(attempt.totalSeconds)) · \(attempt.origin)"
                )
                Button("Edit attempt") {
                  if model.edit(attempt) { showsHistoryEditor = true }
                }
                .disabled(model.historyHasPending).frame(minHeight: 44).accessibilityIdentifier(
                  "readingHistoryEditAttempt\(attempt.id)")
                if model.canDelete {
                  Button("Delete attempt", role: .destructive) { attemptToDelete = attempt }
                    .frame(minHeight: 44).accessibilityIdentifier(
                      "readingHistoryDeleteAttempt\(attempt.id)")
                }
              }.accessibilityIdentifier("readingHistoryAttempt\(attempt.id)")
            }
            pagination(
              page: model.attemptPage, total: result.total, size: result.pageSize, attempts: true)
          }
        }
        if model.isLoading { ProgressView("Loading your reading record…") }
      }
      .navigationTitle("Sessions and history")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done", action: dismiss.callAsFunction).font(.body)
            .accessibilityIdentifier("readingHistoryClose")
        }
      }
      .disabled(model.isSaving)
      .task { await model.load() }
      .refreshable { await model.load() }
      .sheet(isPresented: $showsManual) { manualEditor }
      .sheet(isPresented: $showsHistoryEditor) { historyEditor }
      .onChange(of: model.historyDraft) { Task { await model.preserveHistoryDraft() } }
      .sheet(isPresented: $showsRecovery) { ReadingRecordRecoveryView(api: model.api) }
      .confirmationDialog(
        "Delete this reading session?",
        isPresented: Binding(
          get: { sessionToDelete != nil }, set: { if !$0 { sessionToDelete = nil } })
      ) {
        Button("Delete session", role: .destructive) {
          if let session = sessionToDelete { Task { await model.deleteSession(session) } }
          sessionToDelete = nil
        }
      } message: {
        Text("Its time is removed from your statistics. Delayed native retries cannot restore it.")
      }
      .confirmationDialog(
        "Delete this reading attempt?",
        isPresented: Binding(
          get: { attemptToDelete != nil }, set: { if !$0 { attemptToDelete = nil } })
      ) {
        Button("Delete attempt", role: .destructive) {
          if let attempt = attemptToDelete { Task { await model.deleteAttempt(attempt) } }
          attemptToDelete = nil
        }
      }
      .sheet(isPresented: $confirmsReread) {
        NavigationStack {
          Form {
            Text("Start a new reading attempt for this book.")
            Toggle("Reset reading positions", isOn: $resetProgress)
              .accessibilityIdentifier("readingHistoryResetProgress")
            Button("Start reread") {
              Task {
                await model.startReread(resetProgress: resetProgress)
                confirmsReread = false
              }
            }.accessibilityIdentifier("readingHistoryConfirmReread")
          }.navigationTitle("Start reread")
            .toolbar {
              ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { confirmsReread = false }
              }
            }
        }
      }
    }
  }

  private var manualEditor: some View {
    NavigationStack {
      Form {
        Text(
          "Manual entries are distinct from measured reading or listening and do not award time-based achievements."
        )
        DatePicker("Started", selection: $model.manualStarted, in: ...Date())
          .accessibilityIdentifier("readingManualStarted")
        Stepper(
          "Duration: \(model.manualMinutes) minutes", value: $model.manualMinutes, in: 1...1440
        )
        .accessibilityIdentifier("readingManualDuration")
        TextField("End progress (%)", text: $model.manualProgress).keyboardType(.decimalPad)
          .accessibilityIdentifier("readingManualEndProgress")
        Picker("Format", selection: $model.manualFormat) {
          Text("Unspecified").tag("")
          ForEach(model.formats, id: \.self) { Text($0.uppercased()).tag($0) }
        }
        if let validation = model.manualValidation { Text(validation) }
        if let error = model.error { Text(error).accessibilityIdentifier("readingManualError") }
      }.navigationTitle("Manual session")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showsManual = false } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
              Task {
                await model.createManual()
                if model.error == nil { showsManual = false }
              }
            }.disabled(model.isSaving || model.manualValidation != nil)
              .accessibilityIdentifier("readingManualSave")
          }
        }
    }
  }

  private var historyEditor: some View {
    NavigationStack {
      Form {
        Group {
          TextField("Started YYYY-MM-DD", text: $model.historicalStarted)
            .accessibilityIdentifier("readingAttemptStarted")
          TextField("Finished YYYY-MM-DD", text: $model.historicalFinished)
            .accessibilityIdentifier("readingAttemptFinished")
          Picker("Outcome", selection: $model.historicalOutcome) {
            if model.editingAttempt != nil { Text("In progress").tag("") }
            Text("Completed").tag("completed")
            Text("Skimmed").tag("skimmed")
            Text("Abandoned").tag("abandoned")
          }.accessibilityIdentifier("readingAttemptOutcome")
        }.disabled(model.historyHasPending)
        Text("Dates use your account's time zone: \(model.timeZone.identifier).")
        if let validation = model.historyValidation { Text(validation) }
        if let message = model.message {
          Text(message).accessibilityIdentifier("readingAttemptSyncState")
        }
        if let error = model.error { Text(error).accessibilityIdentifier("readingAttemptError") }
      }.navigationTitle(
        model.editingAttempt == nil ? "Past reading attempt" : "Edit reading attempt"
      )
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { showsHistoryEditor = false }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            Task {
              await model.saveHistory()
              if model.error == nil { showsHistoryEditor = false }
            }
          }
          .disabled(model.isSaving || model.historyValidation != nil || model.historyHasPending)
          .accessibilityIdentifier("readingAttemptSave")
        }
      }
    }
  }

  private func pagination(page: Int, total: Int, size: Int, attempts: Bool) -> some View {
    HStack {
      Button("Previous") {
        if attempts { model.attemptPage -= 1 } else { model.page -= 1 }
        Task { await model.load() }
      }.disabled(page <= 1).accessibilityIdentifier(
        attempts ? "readingAttemptPrevious" : "readingSessionPrevious")
      Spacer()
      Text("Page \(page)")
      Spacer()
      Button("Next") {
        if attempts { model.attemptPage += 1 } else { model.page += 1 }
        Task { await model.load() }
      }.disabled(page * size >= total).accessibilityIdentifier(
        attempts ? "readingAttemptNext" : "readingSessionNext")
    }
  }

  private static func duration(_ seconds: Double) -> String {
    let minutes = Int(max(0, seconds) / 60)
    return "\(minutes / 60)h \(minutes % 60)m"
  }
}
