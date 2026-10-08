import SwiftUI

struct AudioSleepControlsView: View {
  let model: AudioPlayerModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker(
        "Sleep timer",
        selection: Binding(get: { model.sleepTimer.selection }, set: select)
      ) {
        Text("Off").tag(AudioSleepTimerSelection.off)
        ForEach([1, 15, 30, 45, 60], id: \.self) { minutes in
          Text("\(minutes) minutes").tag(AudioSleepTimerSelection.minutes(minutes))
        }
        Text("End of chapter").tag(AudioSleepTimerSelection.chapterEnd)
      }
      .frame(minHeight: 44)
      .disabled(!model.canSetSleepTimer)
      .accessibilityHint("Without a known current chapter, chapter-end sleep uses 30 minutes.")
      .accessibilityIdentifier("audiobookSleepTimer")
      Text(model.sleepTimer.status).monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("audiobookSleepStatus")
      if model.sleepTimer.isActive {
        if case .minutes = model.sleepTimer.selection {
          Button(action: model.extendSleepTimer) {
            Text("Extend by 15 minutes").fixedSize(horizontal: false, vertical: true)
              .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
          }
          .disabled(!model.canExtendSleepTimer)
          .accessibilityHint("Adds 15 minutes to the time remaining.")
          .accessibilityIdentifier("audiobookSleepExtend")
        }
        Button(action: model.cancelSleepTimer) {
          Text("Cancel sleep timer").fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .disabled(!model.canCancelSleepTimer)
        .accessibilityIdentifier("audiobookSleepCancel")
      }
    }
    .font(.body)
  }

  private func select(_ selection: AudioSleepTimerSelection) {
    switch selection {
    case .off: model.cancelSleepTimer()
    case .minutes(let minutes): model.setSleepTimer(minutes: minutes)
    case .chapterEnd: model.setEndOfChapterSleep()
    }
  }
}
