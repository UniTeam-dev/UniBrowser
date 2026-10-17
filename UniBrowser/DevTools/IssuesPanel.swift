import SwiftUI

/// Panel «Проблемы» (spec «Проблемы»): its model and view. Stub.
@MainActor
@Observable
final class IssuesModel {
    /// Called once by `DevToolsSession.init`: register message handlers with `session.on`.
    func bind(_ session: DevToolsSession) {}
}

struct IssuesPanel: View {
    let session: DevToolsSession

    var body: some View {
        DevToolsPlaceholder(panel: .issues)
    }
}
