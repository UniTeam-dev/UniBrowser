import SwiftUI

@main
struct UniBrowserMobileApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            BrowserScreen()
                .environment(model)
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
                    case .background:
                        model.saveAll()
                        model.relay.appWentToBackground()
                    default:
                        break
                    }
                }
        }
    }
}
