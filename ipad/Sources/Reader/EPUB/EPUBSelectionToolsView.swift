import SwiftUI

struct EPUBSelectionToolsView: View {
  let model: EPUBSelectionToolsModel

  var body: some View {
    NavigationStack {
      List {
        if let presentation = model.presentation {
          Section("Selected passage") {
            Text(verbatim: presentation.passage.text).font(.body)
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
              .accessibilityIdentifier("epubLanguageToolsSelection")
          }
          if presentation.tool == .translation {
            Section("Translate to") {
              Picker("Target language", selection: targetBinding) {
                ForEach(NativeTranslationVocabulary.languages, id: \.code) { language in
                  Text(language.name).tag(language.code)
                }
              }
              .pickerStyle(.menu).frame(minHeight: 44)
              .accessibilityIdentifier("epubTranslationTarget")
            }
          }
          if model.isLoading {
            Section {
              ProgressView(
                presentation.tool == .dictionary ? "Looking up definitions…" : "Translating…"
              )
              .frame(minHeight: 44).accessibilityIdentifier("epubLanguageToolsLoading")
            }
          } else if let error = model.error {
            Section {
              Text(error).font(.body).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("epubLanguageToolsError")
              retryButton
            }
          } else if model.notFound {
            Section {
              Text("No definition found.").font(.body)
                .accessibilityIdentifier("epubDictionaryNoResult")
              retryButton
            }
          } else if let dictionary = model.dictionary {
            dictionaryResult(dictionary)
          } else if let translation = model.translation {
            Section("Translation") {
              Text(verbatim: translation.translatedText).font(.body)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .accessibilityIdentifier("epubTranslationResult")
              Text("Translated with \(translation.provider)").font(.caption)
              Button(
                model.copied ? "Copied translation" : "Copy translation",
                action: model.copyTranslation
              )
              .frame(minHeight: 44).keyboardShortcut("c", modifiers: [.command, .shift])
              .accessibilityIdentifier("epubTranslationCopy")
            }
          }
        }
      }
      .buttonStyle(.plain)
      .navigationTitle(model.presentation?.tool == .dictionary ? "Dictionary" : "Translation")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(model.isLoading ? "Cancel" : "Done", action: model.dismiss)
            .frame(minHeight: 44).keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("epubLanguageToolsClose")
        }
      }
    }
    .presentationDetents([.large])
    .onDisappear(perform: model.dismiss)
  }

  private var targetBinding: Binding<String> {
    Binding(get: { model.targetLanguage }, set: model.setTargetLanguage)
  }

  private var retryButton: some View {
    Button("Retry", action: model.retry).frame(minHeight: 44)
      .keyboardShortcut("r", modifiers: .command)
      .accessibilityIdentifier("epubLanguageToolsRetry")
  }

  @ViewBuilder private func dictionaryResult(_ result: DictionaryResult) -> some View {
    Section {
      Text(verbatim: result.word).font(.title2.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("epubDictionaryWord")
      if let phonetic = result.phonetic, !phonetic.isEmpty {
        Text(verbatim: phonetic).font(.body).accessibilityIdentifier("epubDictionaryPhonetic")
      }
      if result.audioUrl != nil {
        Button(pronunciationLabel, action: model.playPronunciation)
          .frame(minHeight: 44)
          .disabled(!model.canPronounce)
          .accessibilityIdentifier("epubDictionaryPronunciation")
        if !model.canPronounce {
          Text("Stop narration to hear pronunciation.").font(.body)
        }
      }
      if let error = model.pronunciationError {
        Text(error).font(.body).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("epubDictionaryPronunciationError")
      }
    }
    ForEach(Array(result.entries.enumerated()), id: \.offset) { index, entry in
      Section {
        if index == 0 || result.entries[index - 1].sourceWord != entry.sourceWord {
          Text(verbatim: entry.sourceWord).font(.headline).fixedSize(
            horizontal: false, vertical: true
          )
          .accessibilityIdentifier("epubDictionarySourceWord")
        }
        if !entry.partOfSpeech.isEmpty {
          Text(verbatim: entry.partOfSpeech).font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(entry.definitions.enumerated()), id: \.offset) { _, definition in
          VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: definition.definition).font(.body)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("epubDictionaryDefinition")
            if let example = definition.example, !example.isEmpty {
              Text(verbatim: example).font(.body.italic())
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
    }
  }

  private var pronunciationLabel: String {
    if model.isLoadingPronunciation { return "Cancel pronunciation" }
    return model.isPronouncing ? "Stop pronunciation" : "Play pronunciation"
  }
}
