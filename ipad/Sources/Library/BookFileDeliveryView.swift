import SwiftUI
import UIKit

enum BookFileDeliveryResult {
  case saved, shared, cancelled, failed
}

struct BookFileDeliveryPresentation: Identifiable {
  enum Kind { case save, share }
  let id = UUID()
  let artifact: StagedBookFile
  let kind: Kind
}

struct BookFileDeliveryView: UIViewControllerRepresentable {
  let presentation: BookFileDeliveryPresentation
  let completed: @MainActor (BookFileDeliveryResult, UUID) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(artifactID: presentation.artifact.id, completed: completed)
  }

  func makeUIViewController(context: Context) -> UIViewController {
    switch presentation.kind {
    case .save:
      let picker = UIDocumentPickerViewController(
        forExporting: [presentation.artifact.url], asCopy: true)
      picker.delegate = context.coordinator
      return picker
    case .share:
      let activity = UIActivityViewController(
        activityItems: [presentation.artifact.url], applicationActivities: nil)
      let coordinator = context.coordinator
      activity.completionWithItemsHandler = { _, didComplete, _, error in
        Task { @MainActor in
          coordinator.finish(error != nil ? .failed : (didComplete ? .shared : .cancelled))
        }
      }
      return activity
    }
  }

  func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

  @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate {
    let artifactID: UUID
    let completed: @MainActor (BookFileDeliveryResult, UUID) -> Void
    private var finished = false

    init(artifactID: UUID, completed: @escaping @MainActor (BookFileDeliveryResult, UUID) -> Void) {
      self.artifactID = artifactID
      self.completed = completed
    }

    func documentPicker(
      _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
    ) {
      finish(urls.isEmpty ? .failed : .saved)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      finish(.cancelled)
    }

    func finish(_ result: BookFileDeliveryResult) {
      guard !finished else { return }
      finished = true
      completed(result, artifactID)
    }
  }
}
