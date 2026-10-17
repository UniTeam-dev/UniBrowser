import SwiftUI

/// Panel «Сеть» (spec «Сеть»): its model and view. Stub.
@MainActor
@Observable
final class NetworkModel {
    /// Called once by `DevToolsSession.init`: register message handlers with `session.on`.
    func bind(_ session: DevToolsSession) {}
}

struct NetworkPanel: View {
    let session: DevToolsSession

    var body: some View {
        DevToolsPlaceholder(panel: .network)
    }
}
