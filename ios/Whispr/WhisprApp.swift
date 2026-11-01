import SwiftUI

@main
struct WhisprApp: App {
    @State private var model = AppModel()
    @State private var auth = AuthStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(auth)
                .preferredColorScheme(.dark)
        }
    }
}
