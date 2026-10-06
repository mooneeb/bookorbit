import SwiftUI

struct MetadataExtraFieldsView: View {
  @Bindable var draft: MetadataDraft
  @Bindable var extra: MetadataExtraDraft

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 24) {
      seriesSection
      ratingsSection
      if extra.hasAudio { audioSection }
      if extra.hasComic {
        VStack(alignment: .leading, spacing: 16) {
          Text("Comic metadata").font(.title2)
          ForEach(MetadataComicField.fields) { field in
            input(
              field.label,
              text: Binding(
                get: { extra.comic[field.id] ?? "" }, set: { extra.comic[field.id] = $0 }),
              lock: field.lock, identifier: "metadataComic\(field.id)")
          }
        }
      }
      VStack(alignment: .leading, spacing: 16) {
        Text("Provider identifiers").font(.title2)
        ForEach(MetadataProviderField.fields) { field in
          input(
            field.id == "hardcoverEditionId" ? "Hardcover edition" : field.provider,
            text: Binding(
              get: { extra.identifiers[field.id] ?? "" },
              set: { extra.identifiers[field.id] = $0 }),
            lock: field.id, identifier: "metadataProvider\(field.id)")
        }
      }
    }
    .foregroundStyle(Color(uiColor: .label))
  }

  private var seriesSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Series memberships").font(.title2)
      Text("Expected book counts apply to the shared series.")
        .fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 16) {
        ForEach($extra.series) { $series in
          VStack(alignment: .leading, spacing: 12) {
            textInput("Series name", text: $series.name, identifier: "metadataSeriesName")
            textInput("Series index", text: $series.index, identifier: "metadataSeriesIndex")
            textInput(
              "Expected book count", text: $series.expectedCount,
              identifier: "metadataSeriesExpectedCount")
            Button("Remove series", role: .destructive) {
              extra.series.removeAll { $0.id == series.id }
            }
            .frame(minHeight: 44)
          }
        }
        Button("Add series") { extra.series.append(MetadataSeriesDraft()) }
          .frame(minHeight: 44).disabled(extra.series.count >= 64)
          .accessibilityIdentifier("metadataAddSeries")
      }
      .disabled(
        draft.lockedFields.contains("seriesName") || draft.lockedFields.contains("seriesIndex"))
      MetadataFieldLock(
        draft: draft, field: "seriesName", label: "Lock series names",
        identifier: "metadataSeriesNameLock")
      MetadataFieldLock(
        draft: draft, field: "seriesIndex", label: "Lock series indices",
        identifier: "metadataSeriesIndexLock")
    }
  }

  private var ratingsSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Ratings").font(.title2)
      input("Rating (1 to 5)", text: $extra.rating, lock: "rating", identifier: "metadataRating")
      VStack(alignment: .leading, spacing: 16) {
        ForEach($extra.ratings) { $rating in
          VStack(alignment: .leading, spacing: 12) {
            Picker("Community rating provider", selection: $rating.provider) {
              ForEach(MetadataVocabulary.providers, id: \.self) { Text($0).tag($0) }
            }
            .frame(minHeight: 44)
            textInput(
              "Community rating (0 to 5)", text: $rating.rating,
              identifier: "metadataCommunityRating")
            textInput(
              "Rating count", text: $rating.count, identifier: "metadataCommunityRatingCount")
            Button("Remove community rating", role: .destructive) {
              extra.ratings.removeAll { $0.id == rating.id }
            }
            .frame(minHeight: 44)
          }
        }
        if let provider = MetadataVocabulary.providers.first(where: { candidate in
          !extra.ratings.contains { $0.provider == candidate }
        }) {
          Button("Add community rating") {
            extra.ratings.append(MetadataRatingDraft(provider: provider, rating: "0"))
          }
          .frame(minHeight: 44).accessibilityIdentifier("metadataAddCommunityRating")
        }
      }
      .disabled(draft.lockedFields.contains("communityRating"))
      MetadataFieldLock(
        draft: draft, field: "communityRating", label: "Lock community ratings",
        identifier: "metadataCommunityRatingLock")
    }
  }

  private var audioSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Audio metadata").font(.title2)
      input(
        "Narrators (one per line)", text: $extra.narrators, lock: "narrators",
        identifier: "metadataNarrators")
      input(
        "Duration in seconds", text: $extra.duration, lock: "durationSeconds",
        identifier: "metadataDurationSeconds")
      Toggle("Abridged", isOn: $extra.abridged)
        .disabled(draft.lockedFields.contains("abridged"))
        .accessibilityIdentifier("metadataAbridged")
      MetadataFieldLock(
        draft: draft, field: "abridged", label: "Lock abridged", identifier: "metadataAbridgedLock")
      Text("Audio chapters").font(.headline)
      ForEach($extra.chapters) { $chapter in
        VStack(alignment: .leading, spacing: 12) {
          textInput("Chapter title", text: $chapter.title, identifier: "metadataChapterTitle")
          textInput(
            "Start in milliseconds", text: $chapter.start, identifier: "metadataChapterStart")
          Button("Remove chapter", role: .destructive) {
            extra.chapters.removeAll { $0.id == chapter.id }
          }
          .frame(minHeight: 44)
        }
      }
      Button("Add chapter") { extra.chapters.append(MetadataChapterDraft()) }
        .frame(minHeight: 44).disabled(extra.chapters.count >= 1000)
        .accessibilityIdentifier("metadataAddChapter")
    }
  }

  private func input(_ label: String, text: Binding<String>, lock: String, identifier: String)
    -> some View
  {
    VStack(alignment: .leading, spacing: 8) {
      textInput(label, text: text, identifier: identifier)
        .disabled(draft.lockedFields.contains(lock))
      Button("Clear \(label.lowercased())") { text.wrappedValue = "" }
        .frame(minHeight: 44)
        .disabled(draft.lockedFields.contains(lock) || text.wrappedValue.isEmpty)
        .accessibilityIdentifier("\(identifier)Clear")
      MetadataFieldLock(
        draft: draft, field: lock, label: "Lock \(label.lowercased())",
        identifier: "\(identifier)Lock")
    }
  }

  private func textInput(_ label: String, text: Binding<String>, identifier: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(label).font(.headline)
      TextField("", text: text, axis: .vertical).textFieldStyle(.roundedBorder)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .frame(minHeight: 44).accessibilityLabel(label).accessibilityIdentifier(identifier)
    }
  }
}
