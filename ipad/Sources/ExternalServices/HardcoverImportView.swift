import SwiftUI

struct HardcoverImportView: View {
  @State private var model: HardcoverImportModel
  @State private var confirmImport = false

  init(api: BookOrbitAPI) { _model = State(initialValue: HardcoverImportModel(api: api)) }

  var body: some View {
    List {
      Section("Import from Hardcover") {
        Text(
          "Review up to 100 Hardcover books per page. Only accessible books with an empty BookOrbit reading status are eligible. Existing status and progress are preserved."
        )
        .fixedSize(horizontal: false, vertical: true)
        Text(
          "Imports status, dates and up to ten latest reading attempts per book. Rating, personal notes, highlights and audiobook progress are excluded. Broad title matches need an explicit mapping when candidate limits are reached."
        )
        .font(.caption).fixedSize(horizontal: false, vertical: true)
        Toggle("Import eligible ebook progress", isOn: $model.importProgress)
          .disabled(model.result != nil).accessibilityIdentifier("hardcoverImportProgress")
      }
      if let result = model.result {
        Section("Confirmed by BookOrbit") {
          Text(
            "\(result.applied) status records imported, \(result.progressApplied) progress records imported, \(result.failed) record failures, \(result.progressFailed ?? 0) progress failures."
          )
          .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(
            "hardcoverImportResult")
          if result.failed > 0 || (result.progressFailed ?? 0) > 0 {
            Text("Some changes may already be saved. Refresh and review conflicts before retrying.")
          }
        }
      }
      if let page = model.preview {
        Section("Current page") {
          Text(
            "\(model.visited + (page.rows.isEmpty ? 0 : 1))-\(model.visited + page.rows.count): \(page.summary.willUpdate) ready, \(page.summary.needsReview) need review, \(page.summary.conflicts) conflicts, \(page.summary.unmatched) unmatched, \(page.summary.skipped) skipped"
          )
          .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(
            "hardcoverImportSummary")
          if page.rows.isEmpty { Text("No more Hardcover reading records.") }
          Button("Import \(model.selectedIDs.count) selected records") { confirmImport = true }
            .disabled(model.selectedIDs.isEmpty || model.result != nil)
            .accessibilityIdentifier("hardcoverImportApply")
          Button("Refresh current page") { Task { await model.refresh() } }
            .accessibilityIdentifier("hardcoverImportRefresh")
          if page.truncated == true {
            Text("More Hardcover records remain. Finish reviewing this page before continuing.")
              .fixedSize(horizontal: false, vertical: true)
            Button("Review next 100 records") { Task { await model.nextPage() } }
              .accessibilityIdentifier("hardcoverImportNext")
          }
          ForEach(page.rows, id: \.hardcoverUserBookId) { row in
            Button {
              model.toggle(row)
            } label: {
              HStack(alignment: .top) {
                if row.outcome == "will_update" || row.outcome == "needs_review" {
                  Image(
                    systemName: model.selectedIDs.contains(row.hardcoverUserBookId)
                      ? "checkmark.circle.fill" : "circle")
                }
                VStack(alignment: .leading, spacing: 4) {
                  Text(row.hardcoverTitle ?? "Untitled Hardcover book").font(.headline)
                  if let local = row.localTitle { Text("BookOrbit: \(local)") }
                  Text("\(row.hardcoverStatusLabel): \(row.reason)").font(.caption)
                  if model.importProgress { Text(row.progressReason).font(.caption) }
                }
              }.foregroundStyle(.primary)
            }.disabled(
              model.result != nil || (row.outcome != "will_update" && row.outcome != "needs_review")
            )
            .accessibilityIdentifier("hardcoverImportRow\(row.hardcoverUserBookId)")
            .accessibilityValue(
              model.selectedIDs.contains(row.hardcoverUserBookId) ? "Selected" : "Not selected")
          }

        }
      }
      if let error = model.error {
        Section {
          Text(error).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(
            "hardcoverImportError")
          if model.preview == nil {
            Button("Retry preview") { Task { await model.refresh() } }.accessibilityIdentifier(
              "hardcoverImportRetry")
          }
        }
      }
    }.navigationTitle("Import reading records").disabled(model.busy)
      .overlay { if model.busy { ProgressView("Reviewing Hardcover records") } }
      .task { await model.load() }
      .confirmationDialog("Import selected reading records?", isPresented: $confirmImport) {
        Button("Import selected records") { Task { await model.apply() } }
          .accessibilityIdentifier("hardcoverImportConfirm")
      } message: {
        Text(
          "BookOrbit checks access and existing reading status again before saving. Selected title and author matches are treated as reviewed."
        )
      }
  }
}
