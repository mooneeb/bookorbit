import Foundation
import Observation

@MainActor @Observable
final class MetadataExtraDraft {
  private(set) var original: BookDetail
  var identifiers: [String: String]
  var series: [MetadataSeriesDraft]
  var rating: String
  var ratings: [MetadataRatingDraft]
  var narrators: String
  var duration: String
  var abridged: Bool
  var chapters: [MetadataChapterDraft]
  var comic: [String: String]
  private var originalSeries: [MetadataSeriesDraft]
  private var originalRatings: [MetadataRatingDraft]
  private var originalChapters: [MetadataChapterDraft]

  init(book: BookDetail) {
    original = book
    identifiers = Dictionary(
      uniqueKeysWithValues: MetadataProviderField.fields.map {
        ($0.id, book[keyPath: $0.read] ?? "")
      })
    var loadedSeries = (book.seriesMemberships ?? []).map {
      MetadataSeriesDraft(
        name: $0.seriesName, index: $0.seriesIndex ?? "",
        expectedCount: $0.expectedBookCount.map(String.init) ?? "")
    }
    if loadedSeries.isEmpty, let name = book.seriesName {
      loadedSeries = [MetadataSeriesDraft(name: name, index: book.seriesIndex ?? "")]
    }
    series = loadedSeries
    originalSeries = loadedSeries
    rating = book.rating.map { String(Int($0)) } ?? ""
    let loadedRatings = book.communityRatings.map {
      MetadataRatingDraft(
        provider: $0.provider, rating: String($0.rating),
        count: $0.ratingCount.map(String.init) ?? "")
    }
    ratings = loadedRatings
    originalRatings = loadedRatings
    narrators = book.audioMetadata?.narrators.map(\.name).joined(separator: "\n") ?? ""
    duration = book.audioMetadata?.durationSeconds.map(String.init) ?? ""
    abridged = book.audioMetadata?.abridged ?? false
    let loadedChapters = (book.audioMetadata?.chapters ?? []).map {
      MetadataChapterDraft(title: $0.title, start: String($0.startMs))
    }
    chapters = loadedChapters
    originalChapters = loadedChapters
    comic = Dictionary(
      uniqueKeysWithValues: MetadataComicField.fields.map {
        ($0.id, $0.read(book.comicMetadata))
      })
  }

  var hasAudio: Bool { original.coverMedia.contains(.audio) }

  func acknowledge(_ book: BookDetail) {
    original = book
    series = series.map {
      MetadataSeriesDraft(name: $0.name, index: $0.index, expectedCount: $0.expectedCount)
    }
    originalSeries = series
    originalRatings = ratings
    originalChapters = chapters
  }
  var hasComic: Bool {
    original.comicMetadata != nil
      || original.files.contains { ["cbz", "cbr", "cb7"].contains($0.format ?? "") }
  }

  var validationMessage: String? {
    for field in MetadataProviderField.fields {
      if (identifiers[field.id] ?? "").unicodeScalars.count > field.maximum {
        return "\(field.id) must be no longer than \(field.maximum) characters."
      }
    }
    if let message = series.compactMap(\.validationMessage).first { return message }
    if let message = ratings.compactMap(\.validationMessage).first { return message }
    if Set(ratings.map(\.provider)).count != ratings.count {
      return "Use one community rating per provider."
    }
    if !rating.isEmpty && Int(rating).map({ (1...5).contains($0) }) != true {
      return "Rating must be a whole number from 1 to 5, or blank."
    }
    if !duration.isEmpty && Int(duration).map({ (0...Int(Int32.max)).contains($0) }) != true {
      return "Duration must be a nonnegative whole number of seconds, or blank."
    }
    if let message = chapters.compactMap(\.validationMessage).first { return message }
    for field in MetadataComicField.fields {
      if let maximum = field.maximum, (comic[field.id] ?? "").unicodeScalars.count > maximum {
        return "\(field.label) must be no longer than \(maximum) characters."
      }
    }
    return nil
  }

  func write(to payload: inout BookMetadataUpdatePayload) {
    for field in MetadataProviderField.fields {
      payload[keyPath: field.write] = Self.update(
        identifiers[field.id] ?? "", original: original[keyPath: field.read])
    }
    if series != originalSeries { payload.seriesMemberships = .set(series.map(\.payload)) }
    if ratings != originalRatings { payload.communityRatings = .set(ratings.map(\.payload)) }
    if rating != original.rating.map({ String(Int($0)) }) ?? "" {
      payload.rating = Int(rating).map { .set(Double($0)) } ?? .clear
    }
    writeAudio(to: &payload)
    writeComic(to: &payload)
  }

  private func writeAudio(to payload: inout BookMetadataUpdatePayload) {
    var value = AudioMetadataUpdatePayload()
    var changed = false
    let names = Self.names(narrators)
    if names != original.audioMetadata?.narrators.map(\.name) ?? [] {
      value.narrators = names
      changed = true
    }
    if duration != original.audioMetadata?.durationSeconds.map(String.init) ?? "" {
      value.durationSeconds = Int(duration).map(FieldUpdate.set) ?? .clear
      changed = true
    }
    if abridged != original.audioMetadata?.abridged ?? false {
      value.abridged = .set(abridged)
      changed = true
    }
    if chapters != originalChapters {
      value.chapters = .set(chapters.map(\.payload))
      changed = true
    }
    if changed { payload.audioMetadata = value }
  }

  private func writeComic(to payload: inout BookMetadataUpdatePayload) {
    var value = ComicMetadataUpdatePayload()
    var changed = false
    for field in MetadataComicField.fields {
      let text = comic[field.id] ?? ""
      if text != field.read(original.comicMetadata) {
        field.write(text, &value)
        changed = true
      }
    }
    if changed { payload.comicMetadata = value }
  }

  static func update(_ text: String, original: String?) -> FieldUpdate<String>? {
    guard text != original ?? "" else { return nil }
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .clear : .set(text)
  }

  static func names(_ text: String) -> [String] {
    text.components(separatedBy: .newlines).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
  }
}

@MainActor struct MetadataComicField: Identifiable {
  let id: String
  let label: String
  let lock: String
  let maximum: Int?
  let read: (ComicMetadataFields?) -> String
  let offered: (ComicMetadataFields) -> Bool
  let write: (String, inout ComicMetadataUpdatePayload) -> Void

  static let fields: [MetadataComicField] = [
    .init(
      id: "issueNumber", label: "Issue number", lock: "comicIssueNumber", maximum: 50,
      read: { $0?.issueNumber ?? "" }, offered: { $0.issueNumber != nil },
      write: { $1.issueNumber = $0.isEmpty ? .clear : .set($0) }),
    .init(
      id: "volumeName", label: "Volume name", lock: "comicVolumeName", maximum: 500,
      read: { $0?.volumeName ?? "" }, offered: { $0.volumeName != nil },
      write: { $1.volumeName = $0.isEmpty ? .clear : .set($0) }),
    list("pencillers", "Pencillers", "comicPencillers", \.pencillers, \.pencillers),
    list("inkers", "Inkers", "comicInkers", \.inkers, \.inkers),
    list("colorists", "Colorists", "comicColorists", \.colorists, \.colorists),
    list("letterers", "Letterers", "comicLetterers", \.letterers, \.letterers),
    list("coverArtists", "Cover artists", "comicCoverArtists", \.coverArtists, \.coverArtists),
    list("characters", "Characters", "comicCharacters", \.characters, \.characters),
    list("teams", "Teams", "comicTeams", \.teams, \.teams),
    list("locations", "Locations", "comicLocations", \.locations, \.locations),
    list("storyArcs", "Story arcs", "comicStoryArcs", \.storyArcs, \.storyArcs),
  ]

  private static func list(
    _ id: String, _ label: String, _ lock: String,
    _ read: KeyPath<ComicMetadataFields, [String]?>,
    _ write: WritableKeyPath<ComicMetadataUpdatePayload, [String]?>
  ) -> MetadataComicField {
    .init(
      id: id, label: label, lock: lock, maximum: nil,
      read: { $0?[keyPath: read]?.joined(separator: "\n") ?? "" },
      offered: { $0[keyPath: read] != nil },
      write: { $1[keyPath: write] = MetadataExtraDraft.names($0) })
  }
}
