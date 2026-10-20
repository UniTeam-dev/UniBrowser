import SwiftUI

@main
struct UniBrowserMobileApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = Appearance.system

    var body: some Scene {
        WindowGroup {
            BrowserScreen()
                .environment(model)
                .preferredColorScheme(appearance.colorScheme)
                // The Mac's QR code is a unibrowser://pair link; the Camera opens it here.
                .onOpenURL { url in
                    guard url.scheme == PairingPayload.scheme else { return }
                    model.switchMode(to: .viaMac)
                    Task { await model.relay.pair(using: url.absoluteString) }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active:
                        model.relay.appBecameActive()
                        model.resumeSSHSessions()
                    case .background:
                        model.saveAll()
                        model.closeSSHSessionsForBackground()
                        model.relay.appWentToBackground()
                    default:
                        break
                    }
                }
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

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
