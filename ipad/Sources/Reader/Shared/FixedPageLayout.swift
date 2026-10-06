import Foundation

struct FixedPageLayout: Equatable {
  let pageCount: Int
  let facing: Bool
  let singlePrefix: Int

  var prefix: Int { facing ? min(singlePrefix, pageCount) : pageCount }
  var unitCount: Int { prefix + (max(0, pageCount - prefix) + 1) / 2 }

  func unit(for page: Int) -> Int {
    let bounded = min(max(0, page), max(0, pageCount - 1))
    return bounded < prefix ? bounded : prefix + (bounded - prefix) / 2
  }

  func pages(in unit: Int) -> [Int] {
    guard (0..<unitCount).contains(unit) else { return [] }
    if unit < prefix { return [unit] }
    let first = prefix + (unit - prefix) * 2
    return [first, first + 1].filter { $0 < pageCount }
  }

  func adjacentPage(to page: Int, delta: Int) -> Int? {
    pages(in: unit(for: page) + delta).first
  }

  func visibleWindow(around page: Int) -> Set<Int> {
    let center = unit(for: page)
    return Set([-1, 0, 1].flatMap { pages(in: center + $0) })
  }
}
