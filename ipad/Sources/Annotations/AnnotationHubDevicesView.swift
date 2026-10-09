import SwiftUI

struct AnnotationHubDevicesView: View {
  let api: BookOrbitAPI
  @State private var items: [NativeAnnotationHubDevice] = []
  @State private var cursor: String?
  @State private var nextCursor: String?
  @State private var previousCursors: [String?] = []
  @State private var error: String?
  @State private var isBusy = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("Each entry shows the last annotation revision a device acknowledged for one book.")
            .fixedSize(horizontal: false, vertical: true)
        }
        if isBusy { Section { ProgressView("Loading devices…") } }
        if let error {
          Section("Could not load device details") {
            Text(error).accessibilityIdentifier("annotationHubDevicesError")
            Button("Try again", action: reload)
          }
        }
        ForEach(Array(items.enumerated()), id: \.offset) { _, device in
          Section {
            LabeledContent("Device", value: device.deviceId)
            LabeledContent("Book", value: String(device.bookId))
            LabeledContent("Acknowledged revision", value: device.cursor.formatted())
            if let date = AnnotationHubLabels.date(device.updatedAt) {
              Text(date, format: .dateTime.year().month().day().hour().minute())
            }
          }
        }
        if !isBusy, items.isEmpty, error == nil {
          Text("No device acknowledgements are available.")
        }
        Section {
          Button("Previous", action: previous).disabled(previousCursors.isEmpty || isBusy)
          Button("Next", action: next).disabled(nextCursor == nil || isBusy)
        }
      }.font(.body).buttonStyle(.plain).foregroundStyle(Color(uiColor: .label))
        .navigationTitle("Annotation devices")
        .safeAreaInset(edge: .top) {
          Button(action: dismiss.callAsFunction) {
            Text("Done")
              .font(.body)
              .fixedSize(horizontal: false, vertical: true)
              .frame(minWidth: 44, minHeight: 44)
              .contentShape(Rectangle())
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal).padding(.vertical, 8).background(.background)
        }
        .task { await load() }
    }
  }

  private func reload() { Task { await load() } }

  private func next() {
    guard let nextCursor else { return }
    previousCursors.append(cursor)
    cursor = nextCursor
    Task { await load() }
  }

  private func previous() {
    guard !previousCursors.isEmpty else { return }
    cursor = previousCursors.removeLast()
    Task { await load() }
  }

  private func load() async {
    guard !isBusy else { return }
    isBusy = true
    error = nil
    defer { isBusy = false }
    do {
      var query = [URLQueryItem(name: "limit", value: "40")]
      if let cursor { query.append(.init(name: "cursor", value: cursor)) }
      let response: NativeAnnotationHubDeviceResponse = try await api.boundedJSON(
        "annotations/native/hub/devices", query: query, byteLimit: 128 * 1024)
      guard response.items.count <= 40 else { throw ConnectionError.invalidResponse }
      items = response.items
      nextCursor = response.nextCursor
    } catch { self.error = error.localizedDescription }
  }
}
