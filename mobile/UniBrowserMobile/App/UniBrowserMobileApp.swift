import SwiftUI

@main
struct UniBrowserMobileApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            BrowserScreen()
                .environment(model)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.saveAll() }
                }
        }
    }
}
