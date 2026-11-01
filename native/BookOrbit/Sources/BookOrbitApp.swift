import SwiftUI

@main
struct BookOrbitApp: App {
    @State private var library = LibraryModel()
    var body: some Scene {
        WindowGroup { LibraryScreen(library: library).task { await library.restore() } }
    }
}
