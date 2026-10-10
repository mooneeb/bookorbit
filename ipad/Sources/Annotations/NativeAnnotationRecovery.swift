import Foundation

struct NativeAnnotationRecoveryDraft: Codable, Sendable, Equatable, Identifiable {
  var id: String
  var bookId: Int
  var item: NativeAnnotationItem?
  var operation: NativeAnnotationOperation
  var reason: String
  var createdAt: String
  var snapshotUnavailableReason: String? = nil
}

struct NativeAnnotationRecoveryPage: Sendable {
  var items: [NativeAnnotationRecoveryDraft]
  var nextCursor: Int?
}

enum NativeAnnotationStorageError: LocalizedError {
  case unavailable
  case full
  case corrupt
  case newerChanges
  case recoveryRequired
  case publicationPending
  case paginationChanged

  var errorDescription: String? {
    switch self {
    case .unavailable: "Annotation storage is unavailable. Your saved work has been preserved."
    case .full: "Annotation storage is full. Export or synchronize pending work before adding more."
    case .corrupt: "Saved annotations could not be read. Keep this device's data for recovery."
    case .newerChanges: "Newer changes exist. Undo the latest change first."
    case .recoveryRequired:
      "This change needs review. Its original content is available in recovery."
    case .publicationPending:
      "Ink is saved on this iPad. Source PDF publication is unconfirmed. Retry synchronization."
    case .paginationChanged:
      "The connection changed. Restart this search to browse annotations saved on this iPad."
    }
  }
}

struct NativeAnnotationQueuedChange: Codable, Sendable {
  var operation: NativeAnnotationOperation
  var before: NativeAnnotationItem?
  var after: NativeAnnotationItem
  var attempted: Bool
  var status: String
  var acknowledged: NativeAnnotationItem?
  var undoOperationId: String? = nil
}

enum NativeAnnotationUndoOutcome {
  case cancelled, queued

  var message: String {
    switch self {
    case .cancelled: "Ink undone"
    case .queued: "Undo queued. The saved change will be checked when connected."
    }
  }
}
