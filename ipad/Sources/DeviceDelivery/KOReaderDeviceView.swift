import SwiftUI

struct KOReaderDeviceView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: KOReaderManagementModel
  let deviceID: String
  @State private var pattern: String
  @State private var series: String
  @State private var standalone: String
  @State private var confirmRetirement = false
  @State private var confirmRemoval = false

  init(model: KOReaderManagementModel, deviceID: String) {
    self.model = model
    self.deviceID = deviceID
    let values = model.patterns(deviceID)
    _pattern = State(initialValue: values.pattern)
    _series = State(initialValue: values.series)
    _standalone = State(initialValue: values.standalone)
  }

  var body: some View {
    Form {
      KOReaderFeedbackView(model: model)
      Section("Device status") {
        LabeledContent("Identifier", value: deviceID)
        LabeledContent("Status", value: model.isRetired(deviceID) ? "Retired" : "Active")
        if let device = model.device(deviceID) {
          LabeledContent("Last sync", value: device.lastSyncAt)
          LabeledContent("Last book", value: device.lastBookTitle ?? "None")
        }
        if let sweep = model.sweep(deviceID) {
          LabeledContent("Plugin", value: sweep.pluginVersion ?? "Unknown")
          LabeledContent("Last sweep", value: sweep.lastSweepAt)
          LabeledContent("Matched books", value: sweep.lastSweepBooksMatched.formatted())
          LabeledContent("Page statistics", value: sweep.lastSweepPageStats.formatted())
          LabeledContent("Annotations", value: sweep.lastSweepAnnotations.formatted())
          if sweep.requiresManualUpdate || sweep.updateAvailable == true {
            Text("Install the latest plugin package from KOReader setup.")
          }
        }
      }
      Section("File naming patterns") {
        TextField("Device pattern", text: $pattern, axis: .vertical)
          .accessibilityIdentifier("koreaderDevicePattern")
        TextField("Series pattern", text: $series, axis: .vertical)
          .accessibilityIdentifier("koreaderDeviceSeriesPattern")
        TextField("Standalone pattern", text: $standalone, axis: .vertical)
          .accessibilityIdentifier("koreaderDeviceStandalonePattern")
        KOReaderPatternHelp()
        Button("Save device patterns", action: savePatterns)
          .accessibilityIdentifier("koreaderDevicePatternsSave")
        Button("Reset to account default", action: resetPatterns)
          .accessibilityIdentifier("koreaderDevicePatternsReset")
      }
      .autocorrectionDisabled().textInputAutocapitalization(.never)
      Section("Device management") {
        Button(
          model.isRetired(deviceID) ? "Restore device" : "Retire device", action: confirmRetire
        )
        .accessibilityIdentifier("koreaderDeviceRetire")
        Text("Retirement keeps its history and excludes its statistics from active plugin totals.")
          .font(.footnote).foregroundStyle(.secondary)
        Button("Remove device", role: .destructive, action: confirmRemove)
          .accessibilityIdentifier("koreaderDeviceRemove")
      }
    }
    .disabled(model.isMutating || model.isBusy || !model.hasCredentials || !model.isPermitted)
    .navigationTitle(model.deviceName(deviceID))
    .confirmationDialog(
      model.isRetired(deviceID) ? "Restore this device?" : "Retire this device?",
      isPresented: $confirmRetirement
    ) {
      Button(model.isRetired(deviceID) ? "Restore device" : "Retire device", action: retire)
    }
    .confirmationDialog("Remove this device and its sync history?", isPresented: $confirmRemoval) {
      Button("Remove device", role: .destructive, action: remove)
    }
  }

  private func savePatterns() {
    Task {
      await model.saveDevicePatterns(
        deviceID, pattern: pattern, series: series, standalone: standalone)
    }
  }
  private func resetPatterns() {
    Task {
      await model.clearDevicePatterns(deviceID)
      if model.error == nil {
        pattern = ""
        series = ""
        standalone = ""
      }
    }
  }
  private func confirmRetire() { confirmRetirement = true }
  private func confirmRemove() { confirmRemoval = true }
  private func retire() {
    Task { await model.retireDevice(deviceID, retired: !model.isRetired(deviceID)) }
  }
  private func remove() {
    Task {
      await model.removeDevice(deviceID)
      if model.error == nil { dismiss() }
    }
  }
}
