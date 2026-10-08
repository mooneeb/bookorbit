import Foundation
import Observation

enum MetadataPreviewSource: String, Identifiable, Sendable {
  case automatic, embedded
  var id: String { rawValue }
  var label: String { self == .automatic ? "Automatic metadata" : "Metadata from file" }
}

@MainActor @Observable
final class MetadataPreviewModel {
  let api: BookOrbitAPI
  let bookID: Int
  let source: MetadataPreviewSource
  let draft: MetadataDraft
  private(set) var offer: MetadataPreviewOffer?
  private(set) var isLoading = false
  private(set) var hasLoaded = false
  private(set) var summary = ""
  private(set) var error: String?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var operation = UUID()

  init(api: BookOrbitAPI, bookID: Int, source: MetadataPreviewSource, draft: MetadataDraft) {
    self.api = api
    self.bookID = bookID
    self.source = source
    self.draft = draft
  }

  func load() {
    guard !isLoading else { return }
    cancel()
    let current = operation
    isLoading = true
    hasLoaded = false
    error = nil
    offer = nil
    summary = ""
    task = Task { [weak self, api, bookID, source] in
      do {
        let result: MetadataPreviewOffer
        guard let self else { return }
        if source == .automatic {
          let response: BookMetadataRefreshPreviewResponse = try await api.boundedJSON(
            "books/\(bookID)/refresh-metadata", method: "POST",
            query: [URLQueryItem(name: "preview", value: "true")])
          try Task.checkCancellation()
          let diagnostics = response.diagnostics
          guard diagnostics.candidateCount.isFinite, diagnostics.resolvedFieldCount.isFinite,
            diagnostics.candidateCount >= 0, diagnostics.resolvedFieldCount >= 0,
            diagnostics.candidateCount <= 100_000, diagnostics.resolvedFieldCount <= 100_000,
            diagnostics.candidateCount.rounded() == diagnostics.candidateCount,
            diagnostics.resolvedFieldCount.rounded() == diagnostics.resolvedFieldCount
          else { throw ConnectionError.invalidResponse }
          let fields = MetadataPreviewComparison.fields(response.metadata, draft: self.draft)
          var covers: [CoverMedium: String] = [:]
          for (medium, url) in [
            (CoverMedium.ebook, response.metadata.coverUrl),
            (.audio, response.metadata.audioCoverUrl),
          ] {
            if let url, self.draft.extra.original.coverMedia.contains(medium) {
              guard let parsed = URL(string: url),
                ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
                parsed.host?.isEmpty == false
              else { throw ConnectionError.invalidResponse }
              covers[medium] = url
            }
          }
          result = MetadataPreviewOffer(
            label: source.label, summary: Self.describe(diagnostics), fields: fields, covers: covers
          )
        } else {
          let response: BookFileMetadataResponse = try await api.boundedJSON(
            "books/\(bookID)/metadata-from-file")
          try Task.checkCancellation()
          if let custom = response.customMetadata {
            guard Set(custom.map(\.fieldId)).count == custom.count else {
              throw ConnectionError.invalidResponse
            }
          }
          let fields = MetadataPreviewComparison.fields(response, draft: self.draft)
          result = MetadataPreviewOffer(
            label: source.label,
            summary: fields.isEmpty
              ? "No embedded metadata is available in this book's primary file."
              : "Compare metadata read from this book's primary file.",
            fields: fields, covers: [:])
        }
        guard self.operation == current, !Task.isCancelled else { return }
        guard result.fields.count <= 1024, Set(result.fields.map(\.id)).count == result.fields.count
        else {
          throw ConnectionError.invalidResponse
        }
        self.summary = result.summary
        if !result.fields.isEmpty || !result.covers.isEmpty { self.offer = result }
        self.hasLoaded = true
      } catch {
        if !Task.isCancelled, self?.operation == current {
          self?.error = error.localizedDescription
        }
      }
      if self?.operation == current {
        self?.isLoading = false
        self?.task = nil
      }
    }
  }

  func cancel() {
    operation = UUID()
    task?.cancel()
    task = nil
    isLoading = false
  }

  private static func describe(_ value: MetadataFetchDiagnostics) -> String {
    let reason =
      switch value.reason {
      case "no_active_providers": "No metadata providers are enabled."
      case "no_existing_provider_ids":
        "This book has no identifiers for the enabled providers. Find and compare metadata to choose a matching record."
      case "providers_throttled": "Metadata providers are temporarily throttled. Try again later."
      case "no_candidates": "The enabled providers found no metadata for this book."
      case "no_resolved_fields": "No fields were resolved by your metadata rules."
      default:
        "Found \(Int(value.candidateCount)) candidates and resolved \(Int(value.resolvedFieldCount)) fields."
      }
    return reason
      + (value.enabledUnreferencedProviders.isEmpty
        ? ""
        : " Enabled providers outside your field rules: \(value.enabledUnreferencedProviders.joined(separator: ", ")).")
      + (value.throttledProviders.isEmpty
        ? "" : " Temporarily throttled: \(value.throttledProviders.joined(separator: ", ")).")
  }
}
