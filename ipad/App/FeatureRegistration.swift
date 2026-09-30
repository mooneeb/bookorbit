import BookOrbitFeatures

// The app shell's one extension point. Every feature target already has its line here: a feature
// ticket fills in its target's `screens` or `entryPoint` and usually leaves this file alone. Screens
// appear as tabs in this order; readers appear on a book's detail page when they can open one of
// its formats.
extension FeatureRegistry {
    static let app = FeatureRegistry(
        screens: [LibraryFeature.screen]
            + MyLibraryFeature.screens
            + ListeningFeature.screens
            + SettingsFeature.screens
            + AdminFeature.screens,
        readers: [
            PDFReaderFeature.entryPoint,
            EPUBReaderFeature.entryPoint,
            ComicsReaderFeature.entryPoint,
        ].compactMap { $0 }
    )
}
