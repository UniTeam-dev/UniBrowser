import SwiftUI

@main
struct UniBrowserApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()
    @AppStorage("appearance") private var appearance = Appearance.system

    var body: some Scene {
        Window("UniBrowser", id: "main") {
            MainWindow()
                .environment(model)
                .environment(model.store)
                .frame(minWidth: 820, minHeight: 520)
                .task { await model.passwords.apple.probe() }
                .onAppear { appDelegate.model = model; appearance.apply() }
                .onChange(of: appearance) { appearance.apply() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            BrowserCommands(model: model)
            LibraryCommands(model: model)
        }

        Window("История", id: "history") {
            HistoryWindow()
                .environment(model)
                .environment(model.store)
        }

        Window("Закладки", id: "bookmarks") {
            BookmarksWindow()
                .environment(model)
                .environment(model.store)
        }

        Window("iPhone", id: "iphone") {
            ViaMacWindow()
                .environment(model.viaMac)
        }
        .windowResizability(.contentSize)

        Settings {
            Form {
                Picker("Оформление", selection: $appearance) {
                    ForEach(Appearance.allCases, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.segmented)
            }
            .padding(20)
            .frame(width: 360)
        }
    }
}

enum Appearance: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "Как в системе"
        case .light: "Светлое"
        case .dark: "Тёмное"
        }
    }

    /// App-wide, so web views and every window follow it; nil means follow macOS.
    @MainActor func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
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
