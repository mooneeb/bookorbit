import Charts
import SwiftUI

struct ReadingStatisticsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: ReadingStatisticsModel
  @State private var showingGoalEditor = false

  init(api: BookOrbitAPI, user: AuthUser) {
    _model = State(initialValue: ReadingStatisticsModel(api: api, user: user))
  }

  var body: some View {
    NavigationStack {
      List {
        if let error = model.error {
          Section {
            Label(error, systemImage: "exclamationmark.triangle")
              .accessibilityIdentifier("readingStatisticsError")
            Button("Retry", action: refresh).accessibilityIdentifier("retryReadingStatistics")
          }
        }
        if let notice = model.notice {
          Section { Text(notice).accessibilityIdentifier("readingStatisticsNotice") }
        }
        if let activity = model.activity {
          summary(activity)
          dailyChart
          sourceBreakdown(activity)
          goal(activity)
          rhythm(activity)
          Section {
            Toggle(
              "Track reading achievements",
              isOn: Binding(
                get: { activity.achievementsEnabled },
                set: { value in Task { await model.saveAchievementPreference(value) } })
            )
            .disabled(model.isSavingGoal || model.isSavingPreferences)
            .accessibilityIdentifier("readingAchievementsEnabled")
            if model.isSavingPreferences { ProgressView("Saving achievement preferences…") }
            if let error = model.preferencesError {
              Text(error).accessibilityIdentifier("readingAchievementPreferenceError")
              Button("Retry saving preferences", action: retryPreferences)
            }
            if activity.achievementsEnabled {
              NavigationLink {
                ReadingAchievementsView(model: model)
              } label: {
                Label("Achievements", systemImage: "medal")
              }.accessibilityIdentifier("readingAchievements")
            } else {
              Label("Achievements are turned off for this account.", systemImage: "medal")
            }
            Text(
              "Activity uses saved sessions in \(activity.timezone). Manual entries remain attributed to BookOrbit."
            )
            .font(.footnote)
            .fixedSize(horizontal: false, vertical: true)
          }
        } else if !model.isLoading && model.error == nil {
          ContentUnavailableView("No reading activity", systemImage: "chart.bar")
        }
        if model.isLoading { ProgressView("Loading reading activity…") }
      }
      .navigationTitle("Reading activity")
      .refreshable { await model.load() }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Done", action: done)
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
            .disabled(model.isLoading || model.isSavingGoal || model.isSavingPreferences)
            .accessibilityIdentifier("refreshReadingStatistics")
        }
      }
      .task { await model.load() }
      .sheet(isPresented: $showingGoalEditor) { ReadingGoalEditorView(model: model) }
    }
  }

  @ViewBuilder
  private func summary(_ activity: ActivityOverviewResponse) -> some View {
    Section("Last seven days") {
      metric(
        "Total time", seconds: activity.snapshot.lastSevenDays.totalSeconds,
        id: "readingSevenDayTotal")
      metric(
        "Reading", seconds: activity.snapshot.lastSevenDays.readingSeconds,
        id: "readingSevenDayReading")
      metric(
        "Listening", seconds: activity.snapshot.lastSevenDays.listeningSeconds,
        id: "readingSevenDayListening")
      LabeledContent(
        "Current streak", value: String(localized: "\(Int(activity.snapshot.currentStreak)) days"))
      LabeledContent(
        "Longest streak", value: String(localized: "\(Int(activity.snapshot.longestStreak)) days"))
      LabeledContent(
        "Completed this year", value: Int(activity.snapshot.completedBooksYtd).formatted()
      )
      .accessibilityIdentifier("readingCompletedThisYear")
    }
    Section("Today") {
      metric("Reading", seconds: activity.snapshot.today.readingSeconds, id: "readingTodayReading")
      metric(
        "Listening", seconds: activity.snapshot.today.listeningSeconds, id: "readingTodayListening")
    }
  }

  private var dailyChart: some View {
    Section("Reading and listening") {
      Picker("Chart period", selection: $model.chartDays) {
        Text("14 days").tag(14)
        Text("28 days").tag(28)
        Text("84 days").tag(84)
      }.accessibilityIdentifier("readingChartPeriod")
      Chart(model.dailyPoints) { day in
        BarMark(x: .value("Day", day.date), y: .value("Minutes", day.readingSeconds / 60))
          .foregroundStyle(by: .value("Activity", String(localized: "Reading")))
        BarMark(x: .value("Day", day.date), y: .value("Minutes", day.listeningSeconds / 60))
          .foregroundStyle(by: .value("Activity", String(localized: "Listening")))
      }
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 5)) { value in
          AxisGridLine()
          AxisTick()
          AxisValueLabel {
            if let date = value.as(Date.self) {
              Text(ReadingStatisticsModel.dayTitle(date))
            }
          }
        }
      }
      .chartYAxisLabel("Minutes")
      .frame(height: 220)
      .accessibilityLabel("Reading and listening time by day")
      .accessibilityIdentifier("readingDailyChart")
      DisclosureGroup("Daily totals") {
        ForEach(model.dailyPoints.reversed()) { day in
          VStack(alignment: .leading, spacing: 6) {
            Text(ReadingStatisticsModel.dayTitle(day.date)).font(.headline)
            Text("Reading: \(ReadingStatisticsModel.duration(day.readingSeconds))")
            Text("Listening: \(ReadingStatisticsModel.duration(day.listeningSeconds))")
          }.accessibilityElement(children: .combine)
        }
      }
    }
  }

  private func sourceBreakdown(_ activity: ActivityOverviewResponse) -> some View {
    Section("Sources in the last year") {
      if activity.sources.slices.isEmpty { Text("No saved sessions yet.") }
      ForEach(activity.sources.slices, id: \.bucket) { source in
        LabeledContent(
          ReadingStatisticsModel.sourceTitle(source.bucket),
          value: ReadingStatisticsModel.duration(source.totalSeconds)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("readingSource\(source.bucket)")
        .accessibilityValue(String(localized: "\(Int(source.totalSeconds)) seconds"))
      }
    }
  }

  private func goal(_ activity: ActivityOverviewResponse) -> some View {
    Section("Annual reading goal") {
      Text("\(activity.goal.year.formatted(.number.grouping(.never))) reading goal").font(.headline)
      if let books = activity.goal.goalBooks, books > 0 {
        Text("\(Int(activity.goal.completedBooks)) of \(Int(books)) books completed")
          .accessibilityIdentifier("readingGoalProgress")
        ProgressView(value: min(activity.goal.completedBooks, books), total: books)
          .accessibilityLabel("Annual reading goal progress")
        Text(goalStatus(activity.goal.status))
        Chart(model.goalPoints) { point in
          LineMark(x: .value("Month", point.month), y: .value("Books", point.completed))
            .foregroundStyle(by: .value("Series", String(localized: "Completed")))
          if let target = point.target {
            LineMark(x: .value("Month", point.month), y: .value("Books", target))
              .foregroundStyle(by: .value("Series", String(localized: "Goal")))
              .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
          }
        }
        .chartXScale(domain: 1...12)
        .chartYAxisLabel("Books")
        .frame(height: 200)
        .accessibilityLabel("Completed books and goal by month")
        .accessibilityIdentifier("readingGoalChart")
      } else {
        Text("Set a goal to track books completed this year.")
      }
      Button("Edit reading goal", action: editGoal).accessibilityIdentifier("editReadingGoal")
      Text(
        "Goal progress follows completed books, including completed audiobooks. Session time does not add books to your goal."
      )
      .font(.footnote)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func rhythm(_ activity: ActivityOverviewResponse) -> some View {
    Section("Your reading rhythm") {
      Text("\(Int(activity.rhythm.sessionsCount)) sessions in the last year")
      if let duration = activity.pace.medianDurationSeconds {
        LabeledContent("Typical session", value: ReadingStatisticsModel.duration(duration))
      }
      if let delta = activity.pace.medianProgressDelta {
        LabeledContent("Typical progress", value: delta.formatted(.percent.scale(1)))
      }
      Text(
        "\(Int(activity.pace.eligibleSessions)) sessions with both time and progress contribute to pace."
      )
      .font(.footnote)
    }
  }

  private func metric(_ title: LocalizedStringKey, seconds: Double, id: String) -> some View {
    LabeledContent(title) { Text(ReadingStatisticsModel.duration(seconds)) }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier(id)
      .accessibilityValue(String(localized: "\(Int(seconds)) seconds"))
  }

  private func goalStatus(_ status: String?) -> String {
    switch status {
    case "ahead": String(localized: "Ahead of your goal pace")
    case "behind": String(localized: "Behind your goal pace")
    default: String(localized: "On pace for your goal")
    }
  }

  private func refresh() { Task { await model.load() } }
  private func retryPreferences() { Task { await model.retryAchievementPreference() } }
  private func done() {
    model.close()
    dismiss()
  }
  private func editGoal() {
    model.goalError = nil
    showingGoalEditor = true
  }
}
