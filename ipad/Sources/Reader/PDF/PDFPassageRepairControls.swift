import SwiftUI

struct PDFPassageRepairControls: View {
  let model: PDFPassageRepairModel
  let confirm: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Repair passage location").font(.headline)
      if let preview = model.preview {
        Text("Selected passage, page \(preview.page + 1)").font(.subheadline)
        Text(preview.text).lineLimit(4)
          .accessibilityIdentifier("pdfRepairSelectionPreview")
        Text("Your note and handwriting will be kept.").font(.caption)
        HStack {
          Button("Confirm passage repair", action: confirm)
            .disabled(model.isPreparing || model.isConfirmed)
            .accessibilityIdentifier("pdfRepairConfirmPassage")
          Button("Choose another passage", action: model.cancelPreview)
            .disabled(model.isPreparing)
            .accessibilityIdentifier("pdfRepairCancelSelection")
        }
        .frame(minHeight: 44)
      } else {
        Text("Select text on one PDF page, then preview the passage before repairing its location.")
          .font(.caption).fixedSize(horizontal: false, vertical: true)
        if !model.selectedText.isEmpty {
          Text(model.selectedText).lineLimit(2)
            .accessibilityIdentifier("pdfRepairSelectedText")
        }
        HStack {
          Button("Preview selected passage", action: model.previewSelection)
            .disabled(!model.canPreview)
            .accessibilityIdentifier("pdfRepairPreviewSelection")
          if ProcessInfo.processInfo.environment["BOOKORBIT_ANNOTATION_INPUT_FIXTURE"] == "1" {
            Button("Feed fixture passage selection", action: model.feedFixtureSelection)
              .disabled(model.isPreparing || model.isConfirmed)
              .accessibilityIdentifier("pdfRepairFixtureSelection")
              .accessibilityHint("Automated PDF text selection boundary substitution")
          }
        }
        .frame(minHeight: 44)
      }
      if model.isPreparing { ProgressView("Checking this PDF page…") }
      if let error = model.error {
        Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("pdfRepairSelectionError")
      }
    }
    .padding()
  }
}
