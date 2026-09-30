import BookOrbitFeatures

// The app shell's one extension point. A feature ticket registers its top-level screens and reader
// entry points here, one line each, and builds everything else inside its own package target:
//
//     screens: [LibraryFeature.screen, AnnotationsHubFeature.screen],
//     readers: [PDFReaderFeature.entryPoint, EPUBReaderFeature.entryPoint],
//
// Screens appear as tabs in this order. Readers appear as buttons on a book's detail page when
// they can open one of its formats, and are presented full screen.
extension FeatureRegistry {
    static let app = FeatureRegistry(
        screens: [
            LibraryFeature.screen,
        ],
        readers: [
        ]
    )
}
