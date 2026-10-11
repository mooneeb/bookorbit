import SwiftUI

struct EntityDuplicatesView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: EntityDuplicatesModel
  @State private var selected: BrowseEntityItem?
  @State private var selectedCluster: EntityClusterSelection?

  init(api: BookOrbitAPI, kind: EntityKind) {
    _model = State(initialValue: EntityDuplicatesModel(api: api, kind: kind))
  }

  var body: some View {
    NavigationStack {
      VStack {
        List {
          Section("Review settings") {
            Toggle("Show dismissed pairs", isOn: $model.showDismissed)
              .accessibilityIdentifier("entityShowDismissed")
            if !model.showDismissed {
              Slider(value: $model.minimumSimilarity, in: 0.1...1, step: 0.05) {
                Text("Minimum similarity")
              }
              Text(
                "Minimum similarity: \(model.minimumSimilarity, format: .percent.precision(.fractionLength(0)))"
              )
              Button("Apply similarity") { Task { await model.load() } }
              Button("Recompute duplicates") { Task { await model.refreshScan() } }
                .accessibilityIdentifier("entityRefreshDuplicates")
            }
            Button("Refresh results") { Task { await model.load(page: model.page) } }
              .accessibilityIdentifier("entityRefreshResults")
          }
          if let status = model.status, !model.showDismissed {
            Section("Server scan") {
              Text("Status: \(status.state)").accessibilityIdentifier("entityScanStatus")
              if let progress = status.progressPct {
                ProgressView(value: Double(progress), total: 100)
              }
              if status.state == "computing" {
                Text("The scan continues on the server. Refresh results to check its progress.")
              }
            }
          }
          if let error = model.error {
            Section("Could not complete operation") { Text(error).foregroundStyle(.red) }
          }
          if let outcome = model.outcome {
            Section("Result") { Text(outcome).accessibilityIdentifier("entityDuplicateOutcome") }
          }
          if model.showDismissed {
            ForEach(model.dismissed) { pair in
              Section {
                Text(pair.nameA).font(.headline)
                Text(pair.nameB)
                if let reason = pair.reason { Text(reason).font(.footnote) }
                Button("Restore for review") { Task { await model.restore(pair) } }
                  .accessibilityIdentifier("entityRestorePair\(pair.id)")
              }
            }
          } else {
            ForEach(model.clusters, id: \.clusterId) { cluster in
              Section(
                "Similarity \(cluster.averageSimilarity, format: .percent.precision(.fractionLength(0)))"
              ) {
                Text(
                  "\(cluster.entityTotal ?? cluster.entities.count) entities, \(cluster.pairTotal ?? cluster.pairDetails.count) matching pairs"
                )
                Button("Review component pages") {
                  selectedCluster = EntityClusterSelection(cluster: cluster)
                }
                .accessibilityIdentifier("entityClusterPages\(cluster.clusterId)")
                ForEach(cluster.entities) { entity in
                  Button {
                    selected = BrowseEntityItem(
                      id: entity.id, name: entity.name, bookCount: entity.bookCount)
                  } label: {
                    VStack(alignment: .leading) {
                      Text(entity.name).font(.headline)
                      Text("\(entity.bookCount) books").font(.footnote)
                      ForEach(Array(entity.bookTitles.enumerated()), id: \.offset) { _, title in
                        Text(title).font(.footnote)
                      }
                    }.foregroundStyle(.primary)
                  }
                  .accessibilityIdentifier("entityDuplicate\(entity.id.entityPath)")
                }
                ForEach(Array(cluster.pairDetails.enumerated()), id: \.offset) { _, pair in
                  Button(
                    "Dismiss \(pair.nameA ?? entityName(pair.idA, cluster: cluster)) and \(pair.nameB ?? entityName(pair.idB, cluster: cluster))"
                  ) {
                    Task { await model.dismiss(pair) }
                  }
                  .accessibilityIdentifier(
                    "entityDismiss\(pair.idA.entityPath)-\(pair.idB.entityPath)")
                }
              }
            }
          }
          if model.busy { ProgressView("Loading duplicates") }
          if model.total == 0 && !model.busy && model.error == nil {
            Text("No duplicate pairs to review.")
          }
        }
        HStack {
          Button("Previous") { Task { await model.load(page: model.page - 1) } }
            .disabled(model.page <= 1 || model.busy)
          Spacer()
          Text("Page \(model.page), \(model.total) results").font(.footnote)
          Spacer()
          Button("Next") { Task { await model.load(page: model.page + 1) } }
            .disabled(model.page * 20 >= model.total || model.busy)
        }.padding()
      }
      .disabled(model.busy)
      .navigationTitle("\(model.kind.title) duplicates")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: dismiss.callAsFunction)
        }
      }
      .task { await model.load() }
      .onChange(of: model.showDismissed) { Task { await model.load() } }
      .sheet(item: $selected, onDismiss: { Task { await model.load(page: model.page) } }) { item in
        EntityEditorView(api: model.api, kind: model.kind, item: item)
      }
      .sheet(item: $selectedCluster, onDismiss: { Task { await model.load(page: model.page) } }) {
        selection in
        EntityDuplicateClusterView(api: model.api, kind: model.kind, cluster: selection.cluster)
      }
    }
  }

  private func entityName(_ id: StringOrNumber, cluster: DuplicateCluster) -> String {
    cluster.entities.first { $0.id == id }?.name ?? id.entityPath
  }
}

private struct EntityClusterSelection: Identifiable {
  let cluster: DuplicateCluster
  var id: String { cluster.clusterId }
}

private struct EntityDuplicateClusterView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: EntityDuplicateClusterModel
  @State private var operations: EntityDuplicatesModel
  @State private var selected: BrowseEntityItem?

  init(api: BookOrbitAPI, kind: EntityKind, cluster: DuplicateCluster) {
    _model = State(
      initialValue: EntityDuplicateClusterModel(api: api, kind: kind, cluster: cluster))
    _operations = State(initialValue: EntityDuplicatesModel(api: api, kind: kind))
  }

  var body: some View {
    NavigationStack {
      VStack {
        List {
          Section("Component") {
            Text("\(model.entityTotal) entities, \(model.pairTotal) matching pairs")
              .accessibilityIdentifier("entityClusterTotals")
            Text(
              "Only the current page is loaded. Select an entity to preview a merge, rename or removal."
            )
            .font(.footnote)
          }
          if let error = model.error ?? operations.error {
            Section("Could not load component") {
              Text(error).foregroundStyle(.red)
              Button("Refresh page") { Task { await model.load(page: model.page) } }
            }
          }
          if let outcome = operations.outcome { Text(outcome) }
          Section("Entities on page \(model.page)") {
            ForEach(model.entities) { entity in
              Button {
                selected = BrowseEntityItem(
                  id: entity.id, name: entity.name, bookCount: entity.bookCount)
              } label: {
                VStack(alignment: .leading) {
                  Text(entity.name).font(.headline)
                  Text("\(entity.bookCount) books").font(.footnote)
                  ForEach(Array(entity.bookTitles.enumerated()), id: \.offset) { _, title in
                    Text(title).font(.footnote)
                  }
                }.foregroundStyle(.primary)
              }
              .accessibilityIdentifier("entityClusterMember\(entity.id.entityPath)")
            }
            if model.entities.isEmpty { Text("No entities on this page.") }
          }
          Section("Matching pairs on page \(model.page)") {
            ForEach(Array(model.pairs.enumerated()), id: \.offset) { _, pair in
              VStack(alignment: .leading) {
                Text(pair.nameA ?? entityName(pair.idA))
                Text(pair.nameB ?? entityName(pair.idB))
                Text(
                  "Similarity \(pair.similarity, format: .percent.precision(.fractionLength(0)))"
                ).font(.footnote)
                Button("Dismiss pair") {
                  Task {
                    await operations.dismiss(pair, reload: false)
                    if operations.error == nil { await model.load(page: model.page) }
                  }
                }
                .accessibilityIdentifier(
                  "entityClusterDismiss\(pair.idA.entityPath)-\(pair.idB.entityPath)")
              }
            }
            if model.pairs.isEmpty { Text("No matching pairs on this page.") }
          }
        }
        if model.busy || operations.busy { ProgressView("Loading component") }
        HStack {
          Button("Previous") { Task { await model.load(page: model.page - 1) } }
            .disabled(model.page <= 1 || model.busy || operations.busy)
            .accessibilityIdentifier("entityClusterPrevious")
          Spacer()
          Text("Page \(model.page)").accessibilityIdentifier("entityClusterPage")
          Spacer()
          Button("Next") { if let next = model.nextPage { Task { await model.load(page: next) } } }
            .disabled(model.nextPage == nil || model.busy || operations.busy)
            .accessibilityIdentifier("entityClusterNext")
        }.padding()
      }
      .disabled(model.busy || operations.busy)
      .navigationTitle("Duplicate component")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: dismiss.callAsFunction)
        }
      }
      .sheet(item: $selected, onDismiss: { Task { await model.load(page: model.page) } }) { item in
        EntityEditorView(api: model.api, kind: model.kind, item: item)
      }
    }
  }

  private func entityName(_ id: StringOrNumber) -> String {
    model.entities.first { $0.id == id }?.name ?? id.entityPath
  }
}
