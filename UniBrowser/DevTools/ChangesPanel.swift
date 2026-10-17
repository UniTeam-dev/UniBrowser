import SwiftUI

/// Panel «Изменения» (spec «Изменения»): its model and view. Stub.
@MainActor
@Observable
final class ChangesModel {
    /// Called once by `DevToolsSession.init`: register message handlers with `session.on`.
    func bind(_ session: DevToolsSession) {}
}

struct ChangesPanel: View {
    let session: DevToolsSession

    var body: some View {
        DevToolsPlaceholder(panel: .changes)
    }
}
