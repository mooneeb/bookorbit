import BookOrbitFeatures
import SwiftUI

struct MainView: View {
    let model: SessionModel
    let context: FeatureContext

    var body: some View {
        TabView {
            ForEach(context.registry.screens) { screen in
                Tab {
                    screen.makeView(context)
                } label: {
                    Label {
                        Text(screen.label.title)
                    } icon: {
                        Image(systemName: screen.label.systemImage)
                    }
                }
            }
            Tab("Account", systemImage: "person.crop.circle") {
                AccountView(model: model, session: context.session)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
