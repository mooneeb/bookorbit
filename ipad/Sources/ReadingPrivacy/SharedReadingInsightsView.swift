import Charts
import SwiftUI

struct SharedReadingInsightsView: View {
  let api: BookOrbitAPI
  @Environment(\.scenePhase) private var scenePhase
  @State private var model: SharedReadingInsightsModel

  init(api: BookOrbitAPI) {
    self.api = api
    _model = State(initialValue: SharedReadingInsightsModel(api: api))
  }

  var body: some View {
    List {
      Section {
        TextField("Search readers sharing insights", text: $model.search)
          .textInputAutocapitalization(.never)
          .onSubmit { Task { await model.loadAccounts() } }
          .accessibilityIdentifier("sharedReadingSearch")
        Button("Search readers") { Task { await model.loadAccounts() } }
          .disabled(model.isBusy)
          .accessibilityIdentifier("sharedReadingSearchAccounts")
      }
      if let accounts = model.accounts {
        Section("Readers") {
          ForEach(accounts.items) { account in
            Button {
              Task { await model.open(account) }
            } label: {
              LabeledContent(account.name, value: account.readingInsightsSharingLevel.capitalized)
            }
            .disabled(model.isBusy || account.readingInsightsSharingLevel == "private")
            .accessibilityLabel(
              "\(account.name), \(account.readingInsightsSharingLevel) reading insights"
            )
            .accessibilityIdentifier("sharedReadingAccount\(account.id)")
          }
          if accounts.items.isEmpty { Text("No readers match your search.") }
          HStack {
            Button("Previous readers") {
              Task { await model.loadAccounts(page: accounts.page - 1) }
            }
            .disabled(model.isBusy || accounts.page <= 1)
            Spacer()
            Button("Next readers") { Task { await model.loadAccounts(page: accounts.page + 1) } }
              .disabled(model.isBusy || accounts.page * accounts.pageSize >= accounts.total)
          }
        }
      }
      if let account = model.selectedAccount {
        Section("\(account.name)'s shared insights") {
          Button("Refresh shared insights") { Task { await model.refresh() } }
            .disabled(model.isBusy)
            .accessibilityIdentifier("sharedReadingRefresh")
          if let summary = model.summary {
            ReadingInsightsContent(summary: summary, detail: model.detail)
          }
        }
      }
      if model.isBusy { ProgressView("Loading permitted insights") }
      if let error = model.error {
        Text(error).foregroundStyle(.red).accessibilityIdentifier("sharedReadingError")
      }
      Section {
        Text(
          "Insights respect the reader's consent and your library access and content restrictions. Personal notes, highlights and book files are never included."
        )
        .font(.footnote).foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Shared reading insights")
    .task { await model.loadAccounts() }
    .refreshable {
      if model.selectedAccount != nil { await model.refresh() } else { await model.loadAccounts() }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await model.refresh() } }
    }
  }
}

struct ReadingInsightsContent: View {
  let summary: SharedReadingInsightsSummary
  let detail: SharedReadingInsightsDetail?

  var body: some View {
    LabeledContent("Sharing", value: summary.sharingLevel.capitalized)
      .accessibilityIdentifier("readingInsightSharingLevel")
    LabeledContent("Reading time", value: ReadingPrivacyFormatting.duration(summary.readingSeconds))
      .accessibilityIdentifier("readingInsightReadingTime")
    LabeledContent("Sessions", value: String(summary.sessionsCount))
      .accessibilityIdentifier("readingInsightSessionCount")
    LabeledContent("Active days", value: String(Int(summary.activeDays)))
    LabeledContent("Books started", value: String(Int(summary.booksStarted)))
    LabeledContent("Books completed", value: String(Int(summary.booksCompleted)))
    Text("Last \(Int(summary.periodDays)) days").font(.footnote).foregroundStyle(.secondary)
    if !summary.trend.isEmpty {
      Chart(summary.trend, id: \.day) { day in
        BarMark(x: .value("Day", day.day), y: .value("Minutes", day.readingSeconds / 60))
      }
      .frame(height: 180)
      .accessibilityLabel("Daily reading minutes")
      .accessibilityIdentifier("readingInsightTrend")
    }
    DisclosureGroup("Daily reading") {
      ForEach(summary.trend, id: \.day) { day in
        LabeledContent(
          day.day,
          value:
            "\(ReadingPrivacyFormatting.duration(day.readingSeconds)), \(day.sessionsCount) sessions"
        )
      }
    }
    DisclosureGroup("Formats and genres") {
      ForEach(summary.formatDistribution, id: \.name) { item in
        LabeledContent(item.name, value: ReadingPrivacyFormatting.duration(item.readingSeconds))
      }
      ForEach(summary.genreDistribution, id: \.name) { item in
        LabeledContent(
          item.name.replacingOccurrences(of: "_", with: " ").capitalized,
          value: ReadingPrivacyFormatting.duration(item.readingSeconds))
      }
    }
    DisclosureGroup("Reading sources") {
      ForEach(summary.sourceCoverage, id: \.source) { item in
        LabeledContent(
          item.source.capitalized,
          value:
            "\(ReadingPrivacyFormatting.duration(item.readingSeconds)), \(item.sessionsCount) sessions"
        )
      }
    }
    if let detail {
      DisclosureGroup("Recent books") {
        ForEach(detail.recentBooks, id: \.bookId) { book in bookRow(book) }
      }
      .accessibilityIdentifier("readingInsightRecentBooks")
      DisclosureGroup("Top books") {
        ForEach(detail.topBooks, id: \.bookId) { book in bookRow(book) }
      }
      rankings("Top authors", detail.topAuthors)
      rankings("Top genres", detail.topGenres)
      rankings("Top series", detail.topSeries)
      rankings("Top narrators", detail.topNarrators)
    }
  }

  private func bookRow(_ book: SharedReadingBookItem) -> some View {
    VStack(alignment: .leading) {
      Text(book.title ?? "Untitled book")
      Text(
        "\(ReadingPrivacyFormatting.duration(book.readingSeconds)): \(ReadingPrivacyFormatting.date(book.lastReadAt))"
      )
      .font(.footnote).foregroundStyle(.secondary)
      if let status = book.status {
        Text(status.capitalized).font(.footnote).foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier("readingInsightBook\(book.bookId)")
  }

  private func rankings(_ label: String, _ items: [SharedReadingRankedItem]) -> some View {
    DisclosureGroup(label) {
      ForEach(items, id: \.name) { item in
        LabeledContent(item.name, value: ReadingPrivacyFormatting.duration(item.readingSeconds))
      }
    }
  }
}
