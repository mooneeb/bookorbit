import SwiftUI

struct ReadingPrivacyView: View {
  let api: BookOrbitAPI
  let user: AuthUser
  @Environment(\.dismiss) private var dismiss
  @State private var model: ReadingPrivacyModel

  init(api: BookOrbitAPI, user: AuthUser) {
    self.api = api
    self.user = user
    _model = State(initialValue: ReadingPrivacyModel(api: api))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("Share reading insights", selection: $model.selectedLevel) {
            Text("Private").tag("private")
            Text("Summary").tag("summary")
            Text("Detailed").tag("detailed")
          }
          .accessibilityIdentifier("readingPrivacySharingLevel")
          .disabled(model.isBusy || model.settings == nil)
          Text(levelDescription).font(.footnote).foregroundStyle(.secondary)
          saveFeedback
          if let consent = model.settings?.consentedAt {
            Text("Consent recorded: \(ReadingPrivacyFormatting.date(consent))")
              .font(.footnote).foregroundStyle(.secondary)
          }
        } header: {
          Text("Reading privacy")
        } footer: {
          Text(
            "Shared insights exclude personal notes, highlights, handwriting, bookmarks and source files. Other readers only see books their library access and content restrictions permit."
          )
        }

        Section("Preview and access") {
          Button("Preview shared insights") { Task { await model.loadPreview() } }
            .disabled(model.isBusy)
            .accessibilityIdentifier("readingPrivacyPreview")
          if let preview = model.preview {
            switch preview {
            case .settings:
              Text("Your reading insights are private.")
                .accessibilityIdentifier("readingPrivacyPrivatePreview")
            case .summary(let summary): ReadingInsightsContent(summary: summary, detail: nil)
            case .detailed(let preview):
              ReadingInsightsContent(summary: preview.summary, detail: preview.detail)
            }
          }
          Button("Refresh access history") { Task { await model.loadHistory() } }
            .disabled(model.isBusy)
            .accessibilityIdentifier("readingPrivacyAccessHistory")
          if let history = model.history {
            if history.items.isEmpty {
              Text("No shared insight access has been recorded.").foregroundStyle(.secondary)
            }
            ForEach(history.items) { item in
              VStack(alignment: .leading) {
                Text(item.viewerUsername)
                Text(
                  "\(item.sharingLevel.capitalized): \(ReadingPrivacyFormatting.date(item.viewedAt))"
                )
                .font(.footnote).foregroundStyle(.secondary)
              }
            }
            HStack {
              Button("Previous access page") {
                Task { await model.loadHistory(page: history.page - 1) }
              }
              .disabled(model.isBusy || history.page <= 1)
              Spacer()
              Button("Next access page") {
                Task { await model.loadHistory(page: history.page + 1) }
              }
              .disabled(model.isBusy || history.page * history.pageSize >= history.total)
            }
          }
        }

        Section("Content restrictions") {
          if let restrictions = model.restrictions {
            ContentRestrictionSummary(filters: restrictions)
          }
          if user.hasPermission(.manageUsers) {
            NavigationLink("Manage content restrictions") {
              ContentRestrictionUsersView(api: api)
            }
            .accessibilityIdentifier("readingPrivacyContentRestrictions")
          } else {
            Text("An administrator manages your content restrictions.").font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        if user.hasPermission(.viewUserActivity) {
          Section {
            NavigationLink("View shared reading insights") { SharedReadingInsightsView(api: api) }
              .accessibilityIdentifier("openSharedReadingInsights")
          }
        }
      }
      .accessibilityIdentifier("readingPrivacyContent")
      .navigationTitle("Privacy and sharing")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(action: dismiss.callAsFunction) {
            Text("Done")
              .font(.body)
              .frame(minWidth: 44, minHeight: 44)
              .contentShape(Rectangle())
          }
          .accessibilityIdentifier("readingPrivacyDone")
        }
      }
      .task { await model.load() }
      .refreshable { await model.load() }
    }
  }

  private var saveFeedback: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button("Save sharing setting") { Task { await model.save() } }
        .disabled(model.isBusy || model.settings == nil)
        .accessibilityIdentifier("readingPrivacySave")
      if model.isBusy { ProgressView("Updating privacy settings") }
      if let message = model.message {
        Text(message).accessibilityIdentifier("readingPrivacySaved")
      }
      if let error = model.error {
        Text(error).foregroundStyle(.red).accessibilityIdentifier("readingPrivacyError")
        Button(model.saveFailed ? "Retry saving sharing setting" : "Retry loading privacy settings")
        {
          Task {
            if model.saveFailed {
              await model.save()
            } else {
              await model.load()
            }
          }
        }
        .disabled(model.isBusy)
        .accessibilityIdentifier("readingPrivacyRetry")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var levelDescription: String {
    switch model.selectedLevel {
    case "summary":
      "Share reading totals, broad genres, formats and daily trends with readers permitted to view activity."
    case "detailed":
      "Share summary insights plus book titles and rankings. Personal annotations remain private."
    default:
      "Keep reading insights private. Saving revokes existing shared insight access immediately."
    }
  }
}

enum ReadingPrivacyFormatting {
  static func duration(_ seconds: Double) -> String {
    Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
  }

  static func date(_ value: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: value) else { return value }
    return date.formatted(date: .abbreviated, time: .shortened)
  }
}

struct ContentRestrictionSummary: View {
  let filters: ContentFilterRulesWithNames

  var body: some View {
    rule("Included tags", filters.includeTags)
    rule("Excluded tags", filters.excludeTags)
    rule("Included genres", filters.includeGenres)
    rule("Excluded genres", filters.excludeGenres)
    Text(
      filters.seeOwnRequestedBooks
        ? "Your fulfilled requests can pass content restrictions."
        : "Fulfilled requests follow content restrictions."
    )
    .font(.footnote).foregroundStyle(.secondary)
  }

  private func rule(_ title: String, _ items: [ContentFilterNamedItem]) -> some View {
    LabeledContent(title, value: items.isEmpty ? "None" : items.map(\.name).joined(separator: ", "))
      .font(.body)
  }
}
