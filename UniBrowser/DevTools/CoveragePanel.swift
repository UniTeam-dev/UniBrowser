import SwiftUI

/// Panel «Покрытие» (spec «Покрытие»): its model and view. Stub.
@MainActor
@Observable
final class CoverageModel {
    /// Called once by `DevToolsSession.init`: register message handlers with `session.on`.
    func bind(_ session: DevToolsSession) {}
}

struct CoveragePanel: View {
    let session: DevToolsSession

    var body: some View {
        DevToolsPlaceholder(panel: .coverage)
    }
}
