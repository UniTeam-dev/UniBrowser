import SwiftUI

/// Panel «Приложение» (spec «Приложение»): its model and view. Stub.
@MainActor
@Observable
final class ApplicationModel {
    /// Called once by `DevToolsSession.init`: register message handlers with `session.on`.
    func bind(_ session: DevToolsSession) {}
}

struct ApplicationPanel: View {
    let session: DevToolsSession

    var body: some View {
        DevToolsPlaceholder(panel: .application)
    }
}
