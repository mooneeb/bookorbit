import Foundation

struct FixedPageLayout: Equatable {
  let pageCount: Int
  let facing: Bool
  let singlePrefix: Int
  let revision: Int
  private let widePages: Set<Int>
  private let runs: [PairRun]

  init(pageCount: Int, facing: Bool, singlePrefix: Int, widePages: [Int] = [], revision: Int = 0) {
    self.pageCount = pageCount
    self.facing = facing
    self.singlePrefix = singlePrefix
    self.revision = revision
    let prefix = facing ? min(singlePrefix, pageCount) : pageCount
    let bounded = facing ? Set(widePages.filter { (prefix..<pageCount).contains($0) }).sorted() : []
    self.widePages = Set(bounded)
    var runs: [PairRun] = []
    var cursor = prefix
    var unit = prefix
    for page in bounded {
      if page > cursor {
        let count = (page - cursor + 1) / 2
        runs.append(PairRun(firstPage: cursor, endPage: page, firstUnit: unit, count: count))
        unit += count
      }
      runs.append(PairRun(firstPage: page, endPage: page + 1, firstUnit: unit, count: 1))
      unit += 1
      cursor = page + 1
    }
    if !bounded.isEmpty, cursor < pageCount {
      runs.append(
        PairRun(
          firstPage: cursor, endPage: pageCount, firstUnit: unit,
          count: (pageCount - cursor + 1) / 2))
    }
    self.runs = bounded.isEmpty ? [] : runs
  }

  var prefix: Int { facing ? min(singlePrefix, pageCount) : pageCount }
  var unitCount: Int {
    if let last = runs.last { return last.firstUnit + last.count }
    return prefix + (max(0, pageCount - prefix) + 1) / 2
  }

  func unit(for page: Int) -> Int {
    let bounded = min(max(0, page), max(0, pageCount - 1))
    if bounded < prefix { return bounded }
    if let run = run(containing: bounded, byPage: true) {
      return run.firstUnit + (bounded - run.firstPage) / 2
    }
    return prefix + (bounded - prefix) / 2
  }

  func pages(in unit: Int) -> [Int] {
    guard (0..<unitCount).contains(unit) else { return [] }
    if unit < prefix { return [unit] }
    if let run = run(containing: unit, byPage: false) {
      let first = run.firstPage + (unit - run.firstUnit) * 2
      return [first, first + 1].filter { $0 < run.endPage }
    }
    let first = prefix + (unit - prefix) * 2
    return [first, first + 1].filter { $0 < pageCount }
  }

  func hasVirtualBlank(in unit: Int) -> Bool {
    let pages = pages(in: unit)
    return facing && unit >= prefix && pages.count == 1 && !widePages.contains(pages[0])
  }

  private func run(containing value: Int, byPage: Bool) -> PairRun? {
    var lower = 0
    var upper = runs.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      let start = byPage ? runs[middle].firstPage : runs[middle].firstUnit
      if start <= value { lower = middle + 1 } else { upper = middle }
    }
    return lower > 0 ? runs[lower - 1] : nil
  }

  func adjacentPage(to page: Int, delta: Int) -> Int? {
    pages(in: unit(for: page) + delta).first
  }

  func visibleWindow(around page: Int) -> Set<Int> {
    let center = unit(for: page)
    return Set([-1, 0, 1].flatMap { pages(in: center + $0) })
  }
}

private struct PairRun: Equatable {
  let firstPage: Int
  let endPage: Int
  let firstUnit: Int
  let count: Int
}
