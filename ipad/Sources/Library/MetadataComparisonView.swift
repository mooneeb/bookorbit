import SwiftUI

struct MetadataComparisonView: View {
  let api: BookOrbitAPI
  private let reference: String
  private let sourceURL: String?
  private let candidateCover: String?
  private let fixedCovers: [CoverMedium: String]
  private let summary: String?
  @Bindable var draft: MetadataDraft
  let applied: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var selected: Set<String> = []
  @State private var mergeGenres = false
  @State private var includesCover = false
  @State private var medium: CoverMedium
  @State private var selectedCovers: Set<CoverMedium> = []
  private let fields: [MetadataComparisonField]

  init(api: BookOrbitAPI, match: MetadataMatch, draft: MetadataDraft, applied: @escaping () -> Void)
  {
    self.api = api
    reference = "\(match.candidate.provider): \(match.candidate.providerId)"
    sourceURL = match.candidate.sourceUrl
    candidateCover = match.candidate.coverUrl
    fixedCovers = [:]
    summary = nil
    self.draft = draft
    self.applied = applied
    fields = MetadataComparison.fields(candidate: match.candidate, draft: draft)
    _medium = State(initialValue: draft.extra.original.coverMedia == [.audio] ? .audio : .ebook)
  }

  init(
    api: BookOrbitAPI, offer: MetadataPreviewOffer, draft: MetadataDraft,
    applied: @escaping () -> Void
  ) {
    self.api = api
    self.draft = draft
    self.applied = applied
    reference = offer.label
    sourceURL = nil
    candidateCover = nil
    fixedCovers = offer.covers
    summary = offer.summary
    fields = offer.fields
    _medium = State(initialValue: draft.extra.original.coverMedia == [.audio] ? .audio : .ebook)
  }

  var body: some View {
    VStack(spacing: 0) {
      Text("Compare metadata").font(.title2).padding()
        .accessibilityAddTraits(.isHeader)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 24) {
          Text("Choose values to copy into your draft. Save metadata to persist them.")
            .fixedSize(horizontal: false, vertical: true)
          Text(reference)
          if let summary { Text(summary).fixedSize(horizontal: false, vertical: true) }
          if let source = sourceURL, let url = URL(string: source),
            ["http", "https"].contains(url.scheme?.lowercased() ?? "")
          {
            Link("Open provider record", destination: url).frame(minHeight: 44)
          }
          ForEach(fields) { field in
            VStack(alignment: .leading, spacing: 8) {
              Toggle(
                field.label,
                isOn: Binding(
                  get: { selected.contains(field.id) },
                  set: { if $0 { selected.insert(field.id) } else { selected.remove(field.id) } })
              )
              .disabled(field.isLocked(in: draft))
              .accessibilityIdentifier("metadataCompare\(field.id)")
              if field.isLocked(in: draft) { Label("Locked", systemImage: "lock") }
              Text("Current").font(.headline)
              Text(field.current.isEmpty ? "Not set" : field.current)
                .fixedSize(horizontal: false, vertical: true)
              Text("Proposed").font(.headline)
              Text(field.proposed.isEmpty ? "Not set" : field.proposed)
                .fixedSize(horizontal: false, vertical: true)
              if field.id == "genres" {
                Toggle("Merge with existing genres", isOn: $mergeGenres)
                  .disabled(field.isLocked(in: draft))
              }
            }
          }
          if let url = candidateCover {
            VStack(alignment: .leading, spacing: 12) {
              Text("Proposed cover").font(.headline)
              RemoteCoverPreview(api: api, url: url)
              if draft.extra.original.coverMedia.count > 1 {
                Picker("Cover to replace", selection: $medium) {
                  ForEach(draft.extra.original.coverMedia) { Text($0.label).tag($0) }
                }.frame(minHeight: 44)
              }
              Toggle("Use this \(medium.rawValue) cover", isOn: $includesCover)
                .disabled(draft.lockedFields.contains(medium.lockField))
                .accessibilityIdentifier("metadataCompareCover")
              if draft.lockedFields.contains(medium.lockField) {
                Label("This cover is locked.", systemImage: "lock")
              }
            }
          }
          ForEach(fixedCovers.keys.sorted { $0.rawValue < $1.rawValue }) { slot in
            if let url = fixedCovers[slot] {
              VStack(alignment: .leading, spacing: 12) {
                Text("Proposed \(slot.rawValue) cover").font(.headline)
                RemoteCoverPreview(api: api, url: url)
                Toggle(
                  "Use this \(slot.rawValue) cover",
                  isOn: Binding(
                    get: { selectedCovers.contains(slot) },
                    set: {
                      if $0 { selectedCovers.insert(slot) } else { selectedCovers.remove(slot) }
                    })
                )
                .disabled(draft.lockedFields.contains(slot.lockField))
                .accessibilityIdentifier("metadataCompare\(slot.rawValue)Cover")
                if draft.lockedFields.contains(slot.lockField) {
                  Label("This cover is locked.", systemImage: "lock")
                }
              }
            }
          }
        }.padding()
      }
      .scrollEdgeEffectHidden().clipped()
      HStack {
        Button(action: dismiss.callAsFunction) {
          Text("Cancel").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        Spacer()
        Button(action: apply) {
          Text("Apply to draft").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .disabled(selected.isEmpty && !includesCover && selectedCovers.isEmpty)
        .accessibilityIdentifier("metadataApplyComparison")
      }
      .font(.body).buttonStyle(.plain).foregroundStyle(Color(uiColor: .label))
      .padding(.horizontal).background(Color(uiColor: .systemBackground))
    }
    .background(Color(uiColor: .systemBackground))
    .onChange(of: medium) {
      if draft.lockedFields.contains(medium.lockField) { includesCover = false }
    }
  }

  private func apply() {
    MetadataComparison.apply(fields, selected: selected, draft: draft, mergeGenres: mergeGenres)
    if includesCover, !draft.lockedFields.contains(medium.lockField),
      let url = candidateCover
    {
      draft.coverURLs[medium] = url
    }
    for slot in selectedCovers where !draft.lockedFields.contains(slot.lockField) {
      if let url = fixedCovers[slot] { draft.coverURLs[slot] = url }
    }
    applied()
  }
}
