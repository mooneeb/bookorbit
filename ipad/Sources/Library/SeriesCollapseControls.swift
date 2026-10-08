import SwiftUI

struct SeriesCollapseControls: View {
  @Bindable var model: SeriesCollapsePreferenceModel
  let scope: SeriesCollapseScope
  @Environment(\.scenePhase) private var scenePhase

  private var scopeDescription: String {
    guard model.isLoaded else { return scope.title + ": preference not loaded" }
    if scope.hasOverride(model.preferences) { return scope.title + ": saved override" }
    return scope.title + (scope.canInherit ? ": inherited setting" : ": saved setting")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Toggle(
          "Collapse series",
          isOn: Binding(
            get: { model.effective(in: scope) },
            set: { value in Task { await model.setPreference(in: scope, value: value) } })
        )
        .disabled(!model.isLoaded || model.isBusy || model.pendingScope != nil)
        .accessibilityIdentifier("collapseSeries")
        if model.isBusy {
          ProgressView()
            .accessibilityLabel(
              model.pendingScope == nil
                ? "Refreshing series preference" : "Saving series preference")
        }
      }
      Text(scopeDescription)
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
      if scope.canInherit && scope.hasOverride(model.preferences) {
        Button("Use inherited setting") {
          Task { await model.setPreference(in: scope, value: nil) }
        }
        .frame(minHeight: 44)
        .disabled(model.isBusy || model.pendingScope != nil)
        .accessibilityIdentifier("clearSeriesCollapseOverride")
      }
      if let pendingScope = model.pendingScope {
        Text("Series preference pending for " + pendingScope.title.lowercased())
          .font(.caption)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("seriesCollapsePending")
      }
      if let error = model.error {
        Text(error)
          .font(.body)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("seriesCollapseError")
      }
      if model.error != nil || (model.pendingScope != nil && !model.isBusy) {
        HStack {
          Button("Retry") { Task { await model.retry() } }
            .frame(minHeight: 44)
            .accessibilityIdentifier("retrySeriesCollapse")
          if model.pendingScope != nil {
            Button("Use server setting") { Task { await model.revert() } }
              .frame(minHeight: 44)
              .accessibilityIdentifier("revertSeriesCollapse")
          }
        }
        .disabled(model.isBusy)
      }
    }
    .font(.body)
    .buttonStyle(.plain)
    .foregroundStyle(Color(uiColor: .label))
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(Color(uiColor: .systemBackground))
    .task {
      if !model.isLoaded { await model.reconcile() }
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
        if scenePhase == .active { await model.reconcile() }
      }
    }
    .onChange(of: scenePhase) {
      if scenePhase == .active { Task { await model.reconcile() } }
    }
  }
}
