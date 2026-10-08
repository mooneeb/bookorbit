import SwiftUI

struct NativeTTSSleepTimerView: View {
  let model: NativeTTSModel
  @State private var showsPresets = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      DisclosureGroup("Speech sleep timer", isExpanded: $showsPresets) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Pause text to speech after the selected time.")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
            ForEach(NativeTTSSleepTimerModel.presets, id: \.self) { minutes in
              Button("\(minutes) minutes") { model.startSleepTimer(minutes: minutes) }
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(!model.canSetSleepTimer)
                .accessibilityLabel("Pause speech in \(minutes) minutes")
                .accessibilityAddTraits(
                  model.sleepTimer.activeMinutes == minutes ? [.isSelected] : []
                )
                .accessibilityIdentifier("nativeTTSSleepPreset\(minutes)")
            }
          }
        }
        .padding(.top, 8)
      }
      .animation(reduceMotion ? nil : .default, value: showsPresets)
      .accessibilityIdentifier("nativeTTSSleepOptions")
      if let remaining = model.sleepTimer.remainingLabel {
        Text("Speech pauses in \(remaining)")
          .font(.body.monospacedDigit()).fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("Speech sleep timer remaining")
          .accessibilityValue(remaining)
          .accessibilityIdentifier("nativeTTSSleepRemaining")
        Button("Cancel speech sleep timer", action: cancelTimer)
          .frame(minHeight: 44)
          .accessibilityIdentifier("nativeTTSSleepCancel")
      }
      if model.sleepTimer.didExpire {
        Text("Speech sleep timer finished.")
          .font(.callout).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("nativeTTSSleepExpired")
      }
    }
    .buttonStyle(.bordered)
    .accessibilityElement(children: .contain)
  }

  private func cancelTimer() { model.sleepTimer.cancel() }
}
