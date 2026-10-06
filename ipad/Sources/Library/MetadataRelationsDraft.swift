import Foundation

struct MetadataSeriesDraft: Identifiable, Equatable {
  let id = UUID()
  var name: String
  var index: String
  var expectedCount: String
  let originalExpectedCount: String

  init(name: String = "", index: String = "", expectedCount: String = "") {
    self.name = name
    self.index = index
    self.expectedCount = expectedCount
    originalExpectedCount = expectedCount
  }

  var payload: BookSeriesMembershipUpdatePayload {
    var value = BookSeriesMembershipUpdatePayload(
      seriesName: name.trimmingCharacters(in: .whitespacesAndNewlines),
      seriesIndex: index.isEmpty ? .clear : .set(index))
    if expectedCount != originalExpectedCount {
      value.expectedBookCount = Int(expectedCount).map(FieldUpdate.set) ?? .clear
    }
    return value
  }

  var validationMessage: String? {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty || name.unicodeScalars.count > 500 {
      return "Enter a series name with at most 500 characters."
    }
    if !index.isEmpty
      && (index.count > 20
        || index.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) == nil)
    {
      return "Series index must be a nonnegative decimal with at most 20 characters."
    }
    if !expectedCount.isEmpty && (Int(expectedCount).map { (1...10000).contains($0) } != true) {
      return "Expected book count must be a whole number from 1 to 10,000, or blank."
    }
    return nil
  }
}

struct MetadataChapterDraft: Identifiable, Equatable {
  let id = UUID()
  var title: String
  var start: String

  init(title: String = "", start: String = "0") {
    self.title = title
    self.start = start
  }

  var validationMessage: String? {
    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Enter a chapter title."
    }
    if Int(start).map({ (0...Int(Int32.max)).contains($0) }) != true {
      return "Chapter start must be a nonnegative whole number of milliseconds."
    }
    return nil
  }

  var payload: AudiobookChapterUpdatePayload {
    AudiobookChapterUpdatePayload(title: title, startMs: Int(start) ?? 0)
  }
}

struct MetadataRatingDraft: Identifiable, Equatable {
  let id = UUID()
  var provider: String
  var rating: String
  var count: String

  init(provider: String, rating: String = "", count: String = "") {
    self.provider = provider
    self.rating = rating
    self.count = count
  }

  var validationMessage: String? {
    guard let value = Double(rating), value.isFinite, (0...5).contains(value) else {
      return "Community rating must be a number from 0 to 5."
    }
    if !count.isEmpty && Int(count).map({ (0...Int(Int32.max)).contains($0) }) != true {
      return "Rating count must be a nonnegative whole number, or blank."
    }
    return nil
  }

  var payload: BookCommunityRatingUpdatePayload {
    BookCommunityRatingUpdatePayload(
      provider: provider, rating: Double(rating) ?? 0, ratingCount: Int(count))
  }
}
