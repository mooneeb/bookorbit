import SwiftUI

struct ReadingAchievementsView: View {
  @Bindable var model: ReadingStatisticsModel

  var body: some View {
    List {
      if let error = model.achievementsError {
        Section {
          Label(error, systemImage: "exclamationmark.triangle")
            .accessibilityIdentifier("readingAchievementsError")
          Button("Retry", action: refresh).accessibilityIdentifier("retryReadingAchievements")
        }
      }
      if let catalogue = model.catalogue {
        Section {
          Text(
            "\(Int(catalogue.totalEarned)) of \(Int(catalogue.totalAvailable)) achievements earned"
          )
          .accessibilityIdentifier("readingAchievementsTotal")
          Picker("Show achievements", selection: $model.achievementFilter) {
            ForEach(ReadingAchievementFilter.allCases) { filter in
              Text(filter.title).tag(filter)
            }
          }.accessibilityIdentifier("readingAchievementsFilter")
          Picker("Achievement category", selection: $model.achievementCategory) {
            Text("All categories").tag("all")
            ForEach(catalogue.categories, id: \.key) { category in
              Text(categoryTitle(category.key)).tag(category.key)
            }
          }.accessibilityIdentifier("readingAchievementsCategory")
        }
        Section {
          ForEach(model.visibleAchievements, id: \.key) { achievement in
            row(achievement)
          }
          if model.matchingAchievements.isEmpty {
            Text("No achievements match these filters.")
          }
        }
        Section {
          Text("Page \(model.achievementPage + 1) of \(model.achievementPageCount)")
            .accessibilityIdentifier("readingAchievementsPage")
          HStack {
            Button("Previous", action: model.previousAchievementPage)
              .disabled(model.achievementPage == 0)
            Spacer()
            Button("Next", action: model.nextAchievementPage)
              .disabled(model.achievementPage + 1 >= model.achievementPageCount)
          }.frame(minHeight: 44)
        }
      }
      if model.isLoadingAchievements { ProgressView("Loading achievements…") }
    }
    .navigationTitle("Achievements")
    .task { await model.loadAchievements() }
    .refreshable { await model.loadAchievements() }
    .onChange(of: model.achievementFilter) { model.resetAchievementPage() }
    .onChange(of: model.achievementCategory) { model.resetAchievementPage() }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
          .disabled(model.isLoadingAchievements)
          .accessibilityIdentifier("refreshReadingAchievements")
      }
    }
  }

  private func row(_ achievement: AchievementItem) -> some View {
    let hidden = achievement.hidden && !achievement.earned
    return VStack(alignment: .leading, spacing: 8) {
      Label(
        hidden ? String(localized: "Secret achievement") : achievement.name,
        systemImage: achievement.earned ? "checkmark.seal.fill" : "lock"
      )
      .font(.headline)
      if hidden {
        Text("Keep reading to discover this achievement.")
      } else {
        Text(achievement.description)
        Text(achievement.earned ? String(localized: "Earned") : String(localized: "Locked"))
        if !achievement.earned, let threshold = achievement.threshold, threshold > 0,
          let current = achievement.currentProgress
        {
          ProgressView(value: min(max(0, current), threshold), total: threshold)
            .accessibilityLabel("Achievement progress")
          Text("\(current.formatted()) of \(threshold.formatted())")
        }
      }
      if let awarded = achievement.awardedAt,
        let date = ISO8601DateFormatter().date(from: awarded)
          ?? ReadingStatisticsModel.date(String(awarded.prefix(10)))
      {
        Text("Earned on \(date.formatted(date: .abbreviated, time: .omitted))")
          .font(.footnote)
      }
      if achievement.earned, let book = achievement.contextBookTitle { Text(book).font(.footnote) }
    }
    .fixedSize(horizontal: false, vertical: true)
    .padding(.vertical, 8)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("readingAchievement\(achievement.key)")
  }

  private func categoryTitle(_ key: String) -> String {
    switch key {
    case "reading": String(localized: "Reading")
    case "library": String(localized: "Library")
    case "exploration": String(localized: "Exploration")
    case "dedication": String(localized: "Dedication")
    case "devices": String(localized: "Devices")
    default: key
    }
  }

  private func refresh() { Task { await model.loadAchievements() } }
}
