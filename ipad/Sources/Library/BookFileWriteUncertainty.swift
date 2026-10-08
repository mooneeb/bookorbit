import Foundation

enum BookFileWriteRequestError: LocalizedError {
  case unconfirmed, inProgress, storageUnavailable, tooManyUnconfirmed

  var errorDescription: String? {
    switch self {
    case .unconfirmed:
      "An earlier source-file request is unconfirmed. Review its current status before deliberately repeating it."
    case .inProgress:
      "A source-file request for this book is already being observed. Wait for its response."
    case .storageUnavailable:
      "The source-file request marker is unavailable or could not be saved safely on this device. An automatic repeat will not be sent."
    case .tooManyUnconfirmed:
      "This account has reached the device limit of 128 unconfirmed source-file requests. No new request was sent."
    }
  }
}

enum BookFileWriteUncertainty {
  private static let byteLimit = 4096
  private static let countLimit = 128

  static func contains(_ bookID: Int, profile: ServerProfile, userID: Int) throws -> Bool {
    try read(profile: profile, userID: userID).contains(bookID)
  }

  static func record(_ bookID: Int, profile: ServerProfile, userID: Int) throws {
    var bookIDs = try read(profile: profile, userID: userID)
    guard bookIDs.contains(bookID) || bookIDs.count < countLimit else {
      throw BookFileWriteRequestError.tooManyUnconfirmed
    }
    bookIDs.insert(bookID)
    try save(bookIDs, profile: profile, userID: userID)
  }

  static func clear(_ bookID: Int, profile: ServerProfile, userID: Int) throws {
    var bookIDs = try read(profile: profile, userID: userID)
    bookIDs.remove(bookID)
    try save(bookIDs, profile: profile, userID: userID)
  }

  private static func key(profile: ServerProfile, userID: Int) -> String {
    "bookFileWriteUnconfirmed.v1.\(profile.url.absoluteString).user.\(userID)"
  }

  private static func read(profile: ServerProfile, userID: Int) throws -> Set<Int> {
    guard let data = UserDefaults.standard.data(forKey: key(profile: profile, userID: userID))
    else {
      return []
    }
    guard data.count <= byteLimit,
      let values = try? JSONDecoder().decode([Int].self, from: data),
      values.count <= countLimit, values.allSatisfy({ $0 > 0 })
    else { throw BookFileWriteRequestError.storageUnavailable }
    return Set(values)
  }

  private static func save(_ bookIDs: Set<Int>, profile: ServerProfile, userID: Int) throws {
    let data = try JSONEncoder().encode(bookIDs.sorted())
    guard data.count <= byteLimit else { throw BookFileWriteRequestError.storageUnavailable }
    UserDefaults.standard.set(data, forKey: key(profile: profile, userID: userID))
    guard UserDefaults.standard.synchronize() else {
      throw BookFileWriteRequestError.storageUnavailable
    }
  }
}
