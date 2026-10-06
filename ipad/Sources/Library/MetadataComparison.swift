import Foundation

@MainActor struct MetadataComparisonField: Identifiable {
  let id: String
  let label: String
  let current: String
  let proposed: String
  let locks: Set<String>
  let apply: (MetadataDraft) -> Void

  func isLocked(in draft: MetadataDraft) -> Bool { !locks.isDisjoint(with: draft.lockedFields) }
}

@MainActor enum MetadataComparison {
  static func fields(candidate: MetadataCandidate, draft: MetadataDraft)
    -> [MetadataComparisonField]
  {
    var fields: [MetadataComparisonField] = []
    func text(
      _ id: String, _ label: String, _ value: String?,
      _ key: ReferenceWritableKeyPath<MetadataDraft, String>
    ) {
      guard let value else { return }
      fields.append(
        .init(
          id: id, label: label, current: draft[keyPath: key], proposed: value, locks: [id],
          apply: { $0[keyPath: key] = value }))
    }
    text("title", "Title", candidate.title, \.title)
    text("subtitle", "Subtitle", candidate.subtitle, \.subtitle)
    text("description", "Description", candidate.description, \.description)
    text("publisher", "Publisher", candidate.publisher, \.publisher)
    text("language", "Language", candidate.language, \.language)
    text("isbn10", "ISBN-10", candidate.isbn10, \.isbn10)
    text("isbn13", "ISBN-13", candidate.isbn13, \.isbn13)
    text("authors", "Authors", candidate.authors?.joined(separator: "\n"), \.authors)
    text("genres", "Genres", candidate.genres?.joined(separator: "\n"), \.genres)
    text(
      "pageCount", "Page count", candidate.pageCount.map { $0 > 0 ? String($0) : "" }, \.pageCount)
    if let date = candidate.publishedDate {
      fields.append(
        .init(
          id: "publishedYear", label: "Publication date and year",
          current: draft.publishedDate.isEmpty ? draft.publishedYear : draft.publishedDate,
          proposed: date, locks: ["publishedYear"], apply: { $0.setPublishedDate(date) }))
    } else if let year = candidate.publishedYear {
      fields.append(
        .init(
          id: "publishedYear", label: "Publication year", current: draft.publishedYear,
          proposed: String(year), locks: ["publishedYear"],
          apply: { $0.setPublishedYear(String(year)) }))
    }
    addSeries(candidate, draft, to: &fields)
    addAudio(candidate, draft, to: &fields)
    addRatingsAndComic(candidate, draft, to: &fields)
    addIdentifiers(candidate, draft, to: &fields)
    return fields
  }

  private static func addSeries(
    _ candidate: MetadataCandidate, _ draft: MetadataDraft,
    to fields: inout [MetadataComparisonField]
  ) {
    let memberships =
      candidate.seriesMemberships
      ?? candidate.seriesName.map {
        [MetadataSeriesMembership(seriesName: $0, seriesIndex: candidate.seriesIndex)]
      }
    guard let memberships else { return }
    let proposed = memberships.map { $0.seriesName + ($0.seriesIndex.map { " #" + $0 } ?? "") }
      .joined(separator: "\n")
    let current = draft.extra.series.map { $0.name + ($0.index.isEmpty ? "" : " #" + $0.index) }
      .joined(separator: "\n")
    fields.append(
      .init(
        id: "seriesName", label: "Series memberships", current: current, proposed: proposed,
        locks: ["seriesName", "seriesIndex"],
        apply: { draft in
          draft.extra.series = memberships.map { membership in
            let expected =
              draft.extra.series.first { $0.name == membership.seriesName }?.expectedCount ?? ""
            return MetadataSeriesDraft(
              name: membership.seriesName, index: membership.seriesIndex ?? "",
              expectedCount: expected)
          }
        }))
  }

  private static func addAudio(
    _ candidate: MetadataCandidate, _ draft: MetadataDraft,
    to fields: inout [MetadataComparisonField]
  ) {
    guard draft.extra.hasAudio else { return }
    if let names = candidate.narrators {
      fields.append(
        .init(
          id: "narrators", label: "Narrators", current: draft.extra.narrators,
          proposed: names.joined(separator: "\n"), locks: ["narrators"],
          apply: { $0.extra.narrators = names.joined(separator: "\n") }))
    }
    if let duration = candidate.durationSeconds {
      fields.append(
        .init(
          id: "durationSeconds", label: "Duration in seconds", current: draft.extra.duration,
          proposed: String(duration), locks: ["durationSeconds"],
          apply: { $0.extra.duration = String(duration) }))
    }
    if let abridged = candidate.abridged {
      fields.append(
        .init(
          id: "abridged", label: "Abridged", current: draft.extra.abridged ? "Yes" : "No",
          proposed: abridged ? "Yes" : "No", locks: ["abridged"],
          apply: { $0.extra.abridged = abridged }))
    }
    if let chapters = candidate.chapters {
      fields.append(
        .init(
          id: "chapters", label: "Audio chapters",
          current: draft.extra.chapters.map(\.title).joined(separator: "\n"),
          proposed: chapters.map(\.title).joined(separator: "\n"), locks: [],
          apply: { draft in
            draft.extra.chapters = chapters.map {
              MetadataChapterDraft(title: $0.title, start: String($0.startMs))
            }
          }))
    }
  }

  private static func addRatingsAndComic(
    _ candidate: MetadataCandidate, _ draft: MetadataDraft,
    to fields: inout [MetadataComparisonField]
  ) {
    if let value = candidate.communityRating {
      let current = draft.extra.ratings.first { $0.provider == candidate.provider }?.rating ?? ""
      fields.append(
        .init(
          id: "communityRating", label: "\(candidate.provider) community rating", current: current,
          proposed: String(value), locks: ["communityRating"],
          apply: { draft in
            let row = MetadataRatingDraft(
              provider: candidate.provider, rating: String(value),
              count: candidate.communityRatingCount.map(String.init) ?? "")
            if let index = draft.extra.ratings.firstIndex(where: {
              $0.provider == candidate.provider
            }) {
              draft.extra.ratings[index] = row
            } else {
              draft.extra.ratings.append(row)
            }
          }))
    }
    if let comic = candidate.comicMetadata, draft.extra.hasComic {
      for field in MetadataComicField.fields where field.offered(comic) {
        let value = field.read(comic)
        fields.append(
          .init(
            id: field.lock, label: field.label, current: draft.extra.comic[field.id] ?? "",
            proposed: value, locks: [field.lock], apply: { $0.extra.comic[field.id] = value }))
      }
    }
  }

  private static func addIdentifiers(
    _ candidate: MetadataCandidate, _ draft: MetadataDraft,
    to fields: inout [MetadataComparisonField]
  ) {
    if let field = MetadataProviderField.byProvider[candidate.provider] {
      let value =
        candidate.provider == "audnexus"
        ? candidate.audibleId ?? candidate.providerId : candidate.providerId
      fields.append(
        .init(
          id: field, label: "\(candidate.provider) identifier",
          current: draft.extra.identifiers[field] ?? "", proposed: value, locks: [field],
          apply: { $0.extra.identifiers[field] = value }))
    }
    if let edition = candidate.hardcoverEditionId {
      fields.append(
        .init(
          id: "hardcoverEditionId", label: "Hardcover edition",
          current: draft.extra.identifiers["hardcoverEditionId"] ?? "", proposed: edition,
          locks: ["hardcoverEditionId"],
          apply: { $0.extra.identifiers["hardcoverEditionId"] = edition }))
    }
  }

  static func apply(
    _ fields: [MetadataComparisonField], selected: Set<String>, draft: MetadataDraft,
    mergeGenres: Bool
  ) {
    for field in fields where selected.contains(field.id) && !field.isLocked(in: draft) {
      if field.id == "genres", mergeGenres {
        var seen = Set<String>()
        draft.genres =
          (MetadataExtraDraft.names(draft.genres) + MetadataExtraDraft.names(field.proposed)).filter
        {
          seen.insert($0.lowercased()).inserted
        }.joined(separator: "\n")
      } else {
        field.apply(draft)
      }
    }
  }
}
