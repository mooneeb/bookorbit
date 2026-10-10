import Foundation

enum PDFReadRefreshError {
  static func isConnectivity(_ error: any Error) -> Bool {
    guard let error = error as? URLError else { return false }
    switch error.code {
    case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
      .dnsLookupFailed, .timedOut:
      return true
    default:
      return false
    }
  }

  static func isCancellation(_ error: any Error) -> Bool {
    (error as? URLError)?.code == .cancelled
  }
}
