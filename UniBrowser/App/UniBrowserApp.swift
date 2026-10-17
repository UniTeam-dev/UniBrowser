import SwiftUI

@main
struct UniBrowserApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("UniBrowser", id: "main") {
            MainWindow()
                .environment(model)
                .environment(model.store)
                .frame(minWidth: 820, minHeight: 520)
                .task { await model.passwords.apple.probe() }
                .onAppear { appDelegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands { BrowserCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor weak var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.store.saveNow() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            urls.forEach { model?.store.newTab(url: $0) }
        }
    }
}
