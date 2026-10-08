import SwiftUI

struct AudioProofView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: AudioProofModel

  init(api: BookOrbitAPI, bookID: Int, file: BookDetailFile) {
    _model = State(initialValue: AudioProofModel(api: api, bookID: bookID, fileID: file.id))
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if let manifest = model.manifest {
            Text(manifest.book.title).font(.title).fixedSize(horizontal: false, vertical: true)
            Text(manifest.book.authors.joined(separator: ", "))
            if let asset = model.currentAsset {
              Text("Track \(asset.sequence + 1) of \(manifest.assets.count)").font(.headline)
                .accessibilityIdentifier("audioCurrentTrack")
            }
            Text(model.timeLabel).font(.title2).monospacedDigit()
              .accessibilityIdentifier("audioPlaybackTime")
            Text(model.isReady ? "Ready to play" : "Preparing audio…")
              .accessibilityIdentifier("audioPlaybackState")
            Button(action: model.togglePlayback) {
              actionLabel(model.isPlaying ? "Pause" : "Play")
            }.disabled(!model.isReady).accessibilityIdentifier("audioPlayPause")
            TextField("Seek time in seconds", text: $model.seekSeconds)
              .textFieldStyle(.roundedBorder).keyboardType(.decimalPad)
              .accessibilityLabel("Seek time in seconds")
              .accessibilityIdentifier("audioSeekSeconds")
            Button {
              Task { await model.seek() }
            } label: {
              actionLabel("Seek")
            }.disabled(!model.isReady).accessibilityIdentifier("audioSeek")
            Button {
              Task { await model.save() }
            } label: {
              actionLabel(model.isSaving ? "Saving…" : "Save progress")
            }.disabled(!model.canSave).accessibilityIdentifier("audioSaveProgress")
            if let progressMessage = model.progressMessage {
              Text(progressMessage).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("audioProgressMessage")
            }
            Text("Tracks").font(.headline)
            ForEach(manifest.assets, id: \.assetId) { asset in
              Button {
                model.select(asset)
              } label: {
                actionLabel("Track \(asset.sequence + 1), \(asset.format.uppercased())")
              }.disabled(!model.canSelectTrack).accessibilityIdentifier(
                "audioTrack\(asset.sequence)")
            }
            if !manifest.chapters.isEmpty {
              Text("Chapters").font(.headline)
              if manifest.assets.contains(where: { ($0.durationMs ?? 0) <= 0 }) {
                Text("Chapter positions are unavailable until all track durations are known.")
              } else {
                ForEach(manifest.chapters) { chapter in
                  Button {
                    model.selectChapter(chapter)
                  } label: {
                    actionLabel(chapter.title)
                  }.disabled(!model.canSelectTrack)
                    .accessibilityIdentifier("audioChapter\(chapter.sequence)")
                }
              }
            }
            Text(model.deliveryLabel).font(.caption).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("audioRangeDiagnostics")
          } else if model.isLoading {
            ProgressView("Opening audiobook…")
          } else {
            Button {
              Task { await model.open() }
            } label: {
              actionLabel("Retry")
            }.accessibilityIdentifier("audioRetry")
          }
          if let error = model.error {
            Text(error).fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("audioError")
            if model.manifest != nil {
              Button(action: model.retryPlayback) {
                actionLabel("Retry playback")
              }.disabled(!model.canSelectTrack).accessibilityIdentifier("audioRetryPlayback")
            }
          }
        }.padding()
      }
      .buttonStyle(AudioProofActionStyle())
      .navigationTitle("Audio proof")
      .safeAreaInset(edge: .top) {
        HStack {
          Spacer()
          Button {
            model.close()
            dismiss()
          } label: {
            Text("Done")
              .font(.body)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.horizontal, 16)
              .frame(minWidth: 44, minHeight: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(AudioProofActionStyle())
          .accessibilityIdentifier("audioDone")
        }
        .padding(.horizontal)
        .background(Color(uiColor: .systemBackground))
      }
    }
    .task { await model.open() }
    .onDisappear(perform: model.close)
  }

  private func actionLabel(_ text: String) -> some View {
    Text(text).fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
      .contentShape(Rectangle())
  }
}

private struct AudioProofActionStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.foregroundStyle(Color(uiColor: .label))
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}
