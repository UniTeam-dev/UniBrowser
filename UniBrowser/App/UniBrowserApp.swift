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
                // The design is light-only; dark mode would draw white titles on the white selected row.
                .preferredColorScheme(.light)
                .task { await model.passwords.apple.probe() }
                .onAppear { appDelegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands { BrowserCommands(model: model) }

        Window("iPhone", id: "iphone") {
            ViaMacWindow()
                .environment(model.viaMac)
                .preferredColorScheme(.light)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor weak var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.store.saveNow() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls {
                // A folder with manifest.json dropped on the app is an unpacked extension.
                if url.isFileURL, FileManager.default.fileExists(atPath: url.appending(path: "manifest.json").path(percentEncoded: false)) {
                    Task { await model?.store.environment.extensions.installFolder(url) }
                } else {
                    model?.store.newTab(url: url)
                }
            }
        }
    }
}
