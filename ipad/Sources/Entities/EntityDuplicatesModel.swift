import Foundation
import Observation

@MainActor @Observable
final class EntityDuplicatesModel {
  let api: BookOrbitAPI
  let kind: EntityKind
  var minimumSimilarity = 0.7
  var showDismissed = false
  private(set) var clusters: [DuplicateCluster] = []
  private(set) var dismissed: [DismissedPairInfo] = []
  private(set) var status: DuplicateScanStatus?
  private(set) var page = 1
  private(set) var total = 0
  private(set) var busy = false
  var error: String?
  var outcome: String?
  private var generation = UUID()

  init(api: BookOrbitAPI, kind: EntityKind) {
    self.api = api
    self.kind = kind
  }

  func load(page: Int = 1) async {
    let request = UUID()
    generation = request
    busy = true
    error = nil
    defer { if generation == request { busy = false } }
    do {
      let session = try await api.authenticatedSessionGeneration()
      if showDismissed {
        let result: EntityDismissedPairsPage = try await api.boundedJSON(
          "entity-manager/\(kind.rawValue)/duplicates/dismissed-page",
          query: [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: "20"),
          ], session: session)
        guard result.page == page, result.pageSize == 20, result.items.count <= 20,
          result.total >= 0
        else {
          throw ConnectionError.invalidResponse
        }
        guard generation == request else { return }
        dismissed = result.items
        total = result.total
      } else {
        let result: DuplicateScanResponse = try await api.boundedJSON(
          "entity-manager/\(kind.rawValue)/duplicates/scan",
          query: [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: "20"),
            URLQueryItem(name: "minSimilarity", value: String(minimumSimilarity)),
          ], session: session)
        guard result.pageSize == 20, result.clusters.count <= 20, result.total >= 0 else {
          throw ConnectionError.invalidResponse
        }
        guard generation == request else { return }
        clusters = result.clusters
        total = result.total
        status = try await api.boundedJSON(
          "entity-manager/\(kind.rawValue)/duplicates/status", session: session)
      }
      guard generation == request else { return }
      self.page = page
    } catch {
      guard generation == request, !Task.isCancelled else { return }
      self.error = error.localizedDescription
    }
  }

  func refreshScan() async {
    guard !busy else { return }
    busy = true
    error = nil
    do {
      let session = try await api.authenticatedSessionGeneration()
      let request = EntityRefreshDuplicatesRequest(minSimilarity: minimumSimilarity)
      status = try await api.boundedJSON(
        "entity-manager/\(kind.rawValue)/duplicates/refresh", method: "POST",
        body: JSONEncoder().encode(request), session: session)
    } catch { self.error = error.localizedDescription }
    busy = false
    if error == nil { await load() }
  }

  func dismiss(_ pair: PairDetail, reload: Bool = true) async {
    guard !busy else { return }
    busy = true
    error = nil
    do {
      let request = EntityDismissPairRequest(
        entityIdA: pair.idA.entityNumber.map(Double.init),
        entityIdB: pair.idB.entityNumber.map(Double.init),
        valueA: pair.idA.entityValue, valueB: pair.idB.entityValue,
        reason: "Reviewed in native entity management")
      try await api.sendEmpty(
        "entity-manager/\(kind.rawValue)/duplicates/dismiss", method: "POST",
        body: JSONEncoder().encode(request))
      outcome = "Duplicate pair dismissed."
    } catch { self.error = error.localizedDescription }
    busy = false
    if error == nil && reload { await load(page: page) }
  }

  func restore(_ pair: DismissedPairInfo) async {
    guard !busy else { return }
    busy = true
    error = nil
    do {
      let request = EntityUndismissPairRequest(
        entityIdA: pair.idA.entityNumber.map(Double.init),
        entityIdB: pair.idB.entityNumber.map(Double.init),
        valueA: pair.idA.entityValue, valueB: pair.idB.entityValue)
      try await api.sendEmpty(
        "entity-manager/\(kind.rawValue)/duplicates/undismiss", method: "POST",
        body: JSONEncoder().encode(request))
      outcome = "Duplicate pair restored for review."
    } catch { self.error = error.localizedDescription }
    busy = false
    if error == nil { await load(page: page) }
  }
}

@MainActor @Observable
final class EntityDuplicateClusterModel {
  let api: BookOrbitAPI
  let kind: EntityKind
  let clusterID: String
  let pageSize: Int
  private(set) var entities: [ClusterEntity]
  private(set) var pairs: [PairDetail]
  private(set) var entityTotal: Int
  private(set) var pairTotal: Int
  private(set) var page = 1
  private(set) var nextPage: Int?
  private(set) var busy = false
  var error: String?

  init(api: BookOrbitAPI, kind: EntityKind, cluster: DuplicateCluster) {
    self.api = api
    self.kind = kind
    clusterID = cluster.clusterId
    pageSize = cluster.detailsPageSize ?? 10
    entities = cluster.entities
    pairs = cluster.pairDetails
    entityTotal = cluster.entityTotal ?? cluster.entities.count
    pairTotal = cluster.pairTotal ?? cluster.pairDetails.count
    nextPage = cluster.nextPage
  }

  func load(page: Int = 1) async {
    guard !busy else { return }
    busy = true
    error = nil
    defer { busy = false }
    do {
      let session = try await api.authenticatedSessionGeneration()
      let result: EntityDuplicateClusterPage = try await api.boundedJSON(
        "entity-manager/\(kind.rawValue)/duplicates/cluster",
        query: [
          URLQueryItem(name: "clusterId", value: clusterID),
          URLQueryItem(name: "page", value: String(page)),
          URLQueryItem(name: "pageSize", value: String(pageSize)),
        ], session: session)
      guard result.clusterId == clusterID, result.page == page, result.pageSize == pageSize,
        result.entities.count <= pageSize, result.pairDetails.count <= pageSize,
        result.entityTotal >= 0, result.pairTotal >= 0
      else { throw ConnectionError.invalidResponse }
      entities = result.entities
      pairs = result.pairDetails
      entityTotal = result.entityTotal
      pairTotal = result.pairTotal
      self.page = page
      nextPage = result.nextPage
    } catch {
      if !Task.isCancelled { self.error = error.localizedDescription }
    }
  }
}
