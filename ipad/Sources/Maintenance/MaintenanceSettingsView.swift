import SwiftUI

struct MaintenanceSettingsView: View {
  @State private var model: MaintenanceSettingsModel
  @Environment(\.scenePhase) private var scenePhase

  init(api: BookOrbitAPI, user: AuthUser) {
    _model = State(initialValue: MaintenanceSettingsModel(api: api, user: user))
  }

  var body: some View {
    @Bindable var model = model
    Form {
      if model.canManageSettings {
        Section("Uploads") {
          TextField("Maximum upload size (MB)", text: $model.uploadLimit)
            .keyboardType(.numberPad).accessibilityIdentifier("maintenanceUploadLimit")
          Text("Choose a whole number from 1 to 4096 MB.").font(.caption)
          Button("Save upload limit", action: model.saveUploadLimit)
            .disabled(!model.uploadLimitChanged || !model.validUploadLimit || model.isSaving)
            .accessibilityIdentifier("maintenanceSaveUploadLimit")
        }
        Section("Updates") {
          Toggle("Check for server updates", isOn: $model.updateChecksEnabled)
            .disabled(!model.loaded || model.isSaving)
            .accessibilityIdentifier("maintenanceUpdateChecks")
          Button("Save update checks", action: model.saveUpdateChecks)
            .disabled(!model.updateChecksChanged || model.isSaving)
            .accessibilityIdentifier("maintenanceSaveUpdateChecks")
        }
        Section("Recommendations") {
          Text("Rebuild the recommendation index for all books on this server.")
          Text(model.statusMessage(model.recommendationStatus, action: .recommendations))
            .accessibilityIdentifier("maintenanceRecommendationStatus")
          Button("Review recommendation rebuild") { model.confirmation = .recommendations }
            .disabled(model.isMonitoring || !model.loaded)
            .accessibilityIdentifier("maintenanceReviewRecommendations")
        }
        if model.canBackfill {
          Section("Achievements") {
            Text("Grant missing achievements from existing activity for all active users.")
            Text(model.statusMessage(model.achievementStatus, action: .achievements))
              .accessibilityIdentifier("maintenanceAchievementStatus")
            Button("Review achievement backfill") { model.confirmation = .achievements }
              .disabled(model.isMonitoring || !model.loaded)
              .accessibilityIdentifier("maintenanceReviewAchievements")
          }
        }
        Section {
          Text(
            "Run progress belongs to the current server process. After a server restart, retry safely if the previous run is no longer reported."
          )
          .font(.caption).foregroundStyle(.secondary)
          if model.isMonitoring { ProgressView("Monitoring server progress") }
          if model.isSaving { ProgressView("Saving settings") }
        }
      }
      if let result = model.result {
        Section("Result") { Text(result).accessibilityIdentifier("maintenanceSettingsResult") }
      }
      if let error = model.error {
        Section("Action needs attention") {
          Text(error).accessibilityIdentifier("maintenanceSettingsError")
          Button("Reconnect and refresh") { Task { await model.load() } }
            .accessibilityIdentifier("maintenanceSettingsRetry")
        }
      }
    }
    .navigationTitle("Maintenance settings")
    .toolbar {
      Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }
        .accessibilityIdentifier("maintenanceSettingsRefresh")
    }
    .task { await model.load() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await model.load() } }
    }
    .sheet(item: $model.confirmation) { action in
      NavigationStack {
        Form {
          Section("Review server action") { Text(action.explanation) }
          Button("Confirm and run", action: model.performConfirmedAction)
            .accessibilityIdentifier("maintenanceSettingsConfirm")
        }
        .navigationTitle(action.title)
        .toolbar { Button("Cancel") { model.confirmation = nil } }
      }
    }
  }
}
