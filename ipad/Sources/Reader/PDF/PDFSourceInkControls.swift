import SwiftUI

struct PDFSourceInkControls: View {
  let editor: PDFSourceInkEditor

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if editor.canEdit {
        ScrollView(.horizontal) {
          HStack(spacing: 16) {
            PencilModeControls(mode: editor.mode)
            Button("Draw ink", systemImage: "pencil.tip", action: editor.draw)
              .accessibilityIdentifier("pdfInkDraw")
            Button("Select ink", systemImage: "cursorarrow", action: editor.selectTool)
              .accessibilityIdentifier("pdfInkSelect")
            Button("Lasso", systemImage: "lasso", action: editor.lassoTool)
              .accessibilityIdentifier("pdfInkLasso")
            Button("Undo", systemImage: "arrow.uturn.backward", action: editor.undo)
              .disabled(!editor.canUndo || editor.isSaving)
              .accessibilityIdentifier("pdfInkUndo")
            Button("Copy", systemImage: "doc.on.doc", action: editor.copySelected)
              .disabled(editor.selected == nil || editor.isSaving)
              .accessibilityIdentifier("pdfInkCopy")
            Button("Paste", systemImage: "doc.on.clipboard", action: editor.paste)
              .disabled(!editor.canPaste)
              .accessibilityIdentifier("pdfInkPaste")
            Button("Move right", systemImage: "arrow.right", action: editor.moveRight)
              .disabled(editor.selected == nil || editor.isSaving)
              .accessibilityIdentifier("pdfInkMoveRight")
            Button(
              "Enlarge", systemImage: "arrow.up.left.and.arrow.down.right", action: editor.grow
            )
            .disabled(editor.selected == nil || editor.isSaving)
            .accessibilityIdentifier("pdfInkGrow")
            Button(
              "Delete ink", systemImage: "trash", role: .destructive,
              action: editor.deleteSelected
            )
            .disabled(editor.selected == nil || editor.isSaving)
            .accessibilityIdentifier("pdfInkDelete")
            if ProcessInfo.processInfo.environment["BOOKORBIT_ANNOTATION_INPUT_FIXTURE"] == "1" {
              Button("Feed fixture ink", action: editor.feedFixture)
                .disabled(editor.isSaving)
                .accessibilityIdentifier("pdfInkFixtureStroke")
                .accessibilityHint("Automated Pencil input boundary substitution")
              if ProcessInfo.processInfo.arguments.contains("--annotation-input-driver") {
                Button("Feed fixture lasso", action: editor.feedFixtureLasso)
                  .disabled(editor.isSaving)
                  .accessibilityIdentifier("pdfInkFixtureLasso")
                  .accessibilityHint("Automated lasso gesture input boundary substitution")
              }
            }
          }
          .buttonStyle(.plain)
          .frame(minHeight: 44)
        }
        .accessibilityIdentifier("pdfInkToolbar")
        if editor.mode.isWriting && editor.tool != .draw {
          ScrollView(.horizontal) {
            LazyHStack {
              ForEach(editor.groups(on: editor.currentPage)) { item in
                Button("Ink item \(item.id > 0 ? String(item.id) : "pending")") {
                  editor.select(item)
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("pdfInkSelectItem\(editor.identity(item))")
                .accessibilityAddTraits(
                  editor.identity(item) == editor.selectedIdentity ? .isSelected : [])
              }
            }
          }
          .accessibilityIdentifier("pdfInkGroups")
        }
      }
      if !editor.status.isEmpty {
        Text(editor.status).font(.caption)
          .accessibilityIdentifier("pdfInkStatus")
      }
      if let error = editor.error ?? editor.repository?.error {
        Text(error).font(.caption).foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("pdfInkError")
        if !editor.draft.strokes.isEmpty {
          Button("Retry saving ink", action: editor.retryDraft)
            .frame(minHeight: 44)
            .disabled(editor.isSaving)
            .accessibilityIdentifier("pdfInkRetry")
        }
        if editor.repository?.error != nil {
          Button("Retry ink synchronization", action: editor.retrySynchronization)
            .frame(minHeight: 44)
            .disabled(editor.repository?.isSynchronizing == true)
            .accessibilityIdentifier("pdfInkRetrySync")
        }
      }
    }
    .padding(.horizontal)
  }
}
