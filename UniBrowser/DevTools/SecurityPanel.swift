import SwiftUI

/// Panel «Безопасность» (spec «Безопасность»): its model and view. Stub.
@MainActor
@Observable
final class SecurityModel {
    /// Called once by `DevToolsSession.init`: register message handlers with `session.on`.
    func bind(_ session: DevToolsSession) {}
}

struct SecurityPanel: View {
    let session: DevToolsSession

    var body: some View {
        DevToolsPlaceholder(panel: .security)
    }
}
