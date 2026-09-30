import BookOrbitFeatures
import SwiftUI

struct MainView: View {
    let model: SessionModel
    let context: FeatureContext

    var body: some View {
        TabView {
            ForEach(context.registry.screens) { screen in
                screen.makeView(context)
                    .tabItem {
                        Label {
                            Text(screen.title)
                        } icon: {
                            Image(systemName: screen.systemImage)
                        }
                    }
            }
            AccountView(model: model, session: context.session)
                .tabItem {
                    Label("Account", systemImage: "person.crop.circle")
                }
        }
    }
}
