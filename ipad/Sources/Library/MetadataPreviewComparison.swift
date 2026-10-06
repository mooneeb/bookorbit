import Foundation

@MainActor struct MetadataPreviewOffer: Identifiable {
  let id = UUID()
  let label: String
  let summary: String
  let fields: [MetadataComparisonField]
  let covers: [CoverMedium: String]
}

@MainActor enum MetadataPreviewComparison {
  static func fields(_ value: BookMetadataRefreshPreviewFields, draft: MetadataDraft)
    -> [MetadataComparisonField]
  {
    var builder = Builder(draft: draft)
    builder.text("title", "Title", value.title, \.title)
    builder.text("subtitle", "Subtitle", value.subtitle, \.subtitle)
    builder.text("description", "Description", value.description, \.description)
    builder.text("publisher", "Publisher", value.publisher, \.publisher)
    builder.text("language", "Language", value.language, \.language)
    builder.text(
      "pageCount", "Page count", value.pageCount.map { $0.map(String.init) }, \.pageCount)
    builder.names("authors", "Authors", value.authors, \.authors)
    builder.names("genres", "Genres", value.genres, \.genres)
    builder.publication(date: value.publishedDate, year: value.publishedYear)
    builder.series(
      name: value.seriesName, index: value.seriesIndex, memberships: value.seriesMemberships)
    for field in MetadataProviderField.fields {
      builder.identifier(field, value[keyPath: field.preview])
    }
    builder.comic(value.comicMetadata)
    if let audio = value.audioMetadata, draft.extra.hasAudio {
      builder.audio(names: audio.narrators, duration: audio.durationSeconds)
      if let abridged = audio.abridged {
        let proposed = abridged.map { $0 ? "Yes" : "No" }.text
        builder.add(
          "abridged", "Abridged", current: draft.extra.abridged ? "Yes" : "No", proposed: proposed
        ) { draft in
          draft.extra.abridged = abridged.value ?? false
          draft.extra.clearsAbridged = abridged == .clear
        }
      }
      if let chapters = audio.chapters {
        builder.add(
          "chapters", "Audio chapters",
          current: draft.extra.chapters.map(\.title).joined(separator: "\n"),
          proposed: chapters.map(\.title).joined(separator: "\n"), locks: []
        ) { draft in
          draft.extra.chapters = chapters.map {
            MetadataChapterDraft(title: $0.title, start: String($0.startMs))
          }
        }
      }
    }
    if let ratings = value.communityRatings {
      builder.add(
        "communityRating", "Community ratings",
        current: draft.extra.ratings.map { "\($0.provider): \($0.rating)" }.joined(separator: "\n"),
        proposed: ratings.map { "\($0.provider): \($0.rating)" }.joined(separator: "\n")
      ) { draft in
        draft.extra.ratings = ratings.map {
          MetadataRatingDraft(
            provider: $0.provider, rating: String($0.rating),
            count: $0.ratingCount.map(String.init) ?? "")
        }
      }
    }
    return builder.fields
  }

  static func fields(_ value: BookFileMetadataResponse, draft: MetadataDraft)
    -> [MetadataComparisonField]
  {
    var builder = Builder(draft: draft)
    builder.text("title", "Title", value.title, \.title)
    builder.text("subtitle", "Subtitle", value.subtitle, \.subtitle)
    builder.text("description", "Description", value.description, \.description)
    builder.text("publisher", "Publisher", value.publisher, \.publisher)
    builder.text("language", "Language", value.language, \.language)
    builder.text("isbn10", "ISBN-10", value.isbn10, \.isbn10)
    builder.text("isbn13", "ISBN-13", value.isbn13, \.isbn13)
    builder.text(
      "pageCount", "Page count", value.pageCount.map { $0.map(String.init) }, \.pageCount)
    builder.names("authors", "Authors", value.authors, \.authors)
    builder.names("genres", "Genres", value.genres, \.genres)
    builder.publication(date: value.publishedDate, year: value.publishedYear)
    builder.series(name: value.seriesName, index: value.seriesIndex, memberships: nil)
    for field in MetadataProviderField.fields {
      builder.identifier(field, value[keyPath: field.file])
    }
    builder.fileComic(value.comicMetadata)
    if draft.extra.hasAudio {
      builder.audio(names: value.narrators, duration: value.durationSeconds)
    }
    for proposed in value.customMetadata ?? [] {
      guard let field = draft.customFields.first(where: { $0.id == proposed.fieldId }) else {
        continue
      }
      builder.add(
        "customMetadata\(field.id)", field.field.label, current: field.value.displayText,
        proposed: proposed.value.displayText, locks: []
      ) { draft in
        guard let index = draft.customFields.firstIndex(where: { $0.id == proposed.fieldId }) else {
          return
        }
        switch proposed.value {
        case .null:
          draft.customFields[index].text = ""
          draft.customFields[index].boolean = "unset"
        case .boolean(let value): draft.customFields[index].boolean = value ? "yes" : "no"
        case .string(let value): draft.customFields[index].text = value
        case .number(let value): draft.customFields[index].text = String(value)
        }
      }
    }
    return builder.fields
  }
}

@MainActor private struct Builder {
  let draft: MetadataDraft
  var fields: [MetadataComparisonField] = []

  mutating func add(
    _ id: String, _ label: String, current: String, proposed: String,
    locks: Set<String>? = nil, apply: @escaping (MetadataDraft) -> Void
  ) {
    fields.append(
      .init(
        id: id, label: label, current: current, proposed: proposed,
        locks: locks ?? [id], apply: apply))
  }

  mutating func text(
    _ id: String, _ label: String, _ offered: FieldUpdate<String>?,
    _ key: ReferenceWritableKeyPath<MetadataDraft, String>
  ) {
    guard let offered else { return }
    add(id, label, current: draft[keyPath: key], proposed: offered.text) {
      $0[keyPath: key] = offered.text
    }
  }

  mutating func names(
    _ id: String, _ label: String, _ offered: [String]?,
    _ key: ReferenceWritableKeyPath<MetadataDraft, String>
  ) {
    text(id, label, offered.map { .set($0.joined(separator: "\n")) }, key)
  }

  mutating func identifier(_ field: MetadataProviderField, _ offered: FieldUpdate<String>?) {
    guard let offered else { return }
    add(
      field.id, "\(field.provider) identifier", current: draft.extra.identifiers[field.id] ?? "",
      proposed: offered.text
    ) { $0.extra.identifiers[field.id] = offered.text }
  }

  mutating func publication(date: FieldUpdate<String>?, year: FieldUpdate<Int>?) {
    if let date {
      let proposed =
        date.text.isEmpty ? year?.map(String.init).text ?? draft.publishedYear : date.text
      add(
        "publishedYear", "Publication date and year",
        current: draft.publishedDate.isEmpty ? draft.publishedYear : draft.publishedDate,
        proposed: proposed
      ) { draft in
        draft.setPublishedDate(date.text)
        if date.text.isEmpty, let year { draft.setPublishedYear(year.map(String.init).text) }
      }
    } else if let year {
      add(
        "publishedYear", "Publication year", current: draft.publishedYear,
        proposed: year.map(String.init).text
      ) { $0.setPublishedYear(year.map(String.init).text) }
    }
  }

  mutating func series(
    name: FieldUpdate<String>?, index: FieldUpdate<String>?,
    memberships: FieldUpdate<[MetadataSeriesMembership]>?
  ) {
    guard name != nil || index != nil || memberships != nil else { return }
    let rows: [MetadataSeriesDraft]
    if let memberships {
      rows = (memberships.value ?? []).map { member in
        MetadataSeriesDraft(
          name: member.seriesName, index: member.seriesIndex ?? "",
          expectedCount: draft.extra.series.first { $0.name == member.seriesName }?.expectedCount
            ?? "")
      }
    } else if let name {
      rows =
        name.text.isEmpty
        ? []
        : [
          MetadataSeriesDraft(
            name: name.text, index: index?.text ?? "",
            expectedCount: draft.extra.series.first { $0.name == name.text }?.expectedCount ?? "")
        ]
    } else {
      var modified = draft.extra.series
      if !modified.isEmpty { modified[0].index = index?.text ?? "" }
      rows = modified
    }
    add(
      "seriesName", "Series memberships", current: seriesText(draft.extra.series),
      proposed: seriesText(rows), locks: ["seriesName", "seriesIndex"]
    ) { $0.extra.series = rows }
  }

  private func seriesText(_ rows: [MetadataSeriesDraft]) -> String {
    rows.map { $0.name + ($0.index.isEmpty ? "" : " #" + $0.index) }.joined(separator: "\n")
  }

  mutating func audio(names: [String]?, duration: FieldUpdate<Int>?) {
    if let names {
      add(
        "narrators", "Narrators", current: draft.extra.narrators,
        proposed: names.joined(separator: "\n")
      ) {
        $0.extra.narrators = names.joined(separator: "\n")
      }
    }
    if let duration {
      add(
        "durationSeconds", "Duration in seconds", current: draft.extra.duration,
        proposed: duration.map(String.init).text
      ) {
        $0.extra.duration = duration.map(String.init).text
      }
    }
  }

  mutating func fileComic(_ value: BookFileComicMetadata?) {
    guard let value, draft.extra.hasComic else { return }
    comic(
      .init(
        pencillers: value.pencillers, inkers: value.inkers, colorists: value.colorists,
        letterers: value.letterers, coverArtists: value.coverArtists, characters: value.characters,
        teams: value.teams, locations: value.locations, storyArcs: value.storyArcs))
    for (id, offered) in [("issueNumber", value.issueNumber), ("volumeName", value.volumeName)] {
      guard let offered,
        let field = MetadataComicField.fields.first(where: { $0.id == id })
      else { continue }
      add(
        field.lock, field.label, current: draft.extra.comic[id] ?? "", proposed: offered.text
      ) { $0.extra.comic[id] = offered.text }
    }
  }

  mutating func comic(_ value: ComicMetadataFields?) {
    guard let value, draft.extra.hasComic else { return }
    for field in MetadataComicField.fields where field.offered(value) {
      let proposed = field.read(value)
      add(field.lock, field.label, current: draft.extra.comic[field.id] ?? "", proposed: proposed) {
        $0.extra.comic[field.id] = proposed
      }
    }
  }
}

extension FieldUpdate {
  fileprivate var value: Value? { if case .set(let value) = self { value } else { nil } }

  fileprivate func map<Output>(_ transform: (Value) -> Output) -> FieldUpdate<Output>
  where Output: Encodable & Sendable & Equatable {
    switch self {
    case .clear: .clear
    case .set(let value): .set(transform(value))
    }
  }
}

extension FieldUpdate where Value == String {
  fileprivate var text: String { value ?? "" }
}
