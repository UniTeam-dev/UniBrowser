import SwiftUI

/// Panel «Источники» (spec «Источники»): its model and view. Stub.
@MainActor
@Observable
final class SourcesModel {
    /// Called once by `DevToolsSession.init`: register message handlers with `session.on`.
    func bind(_ session: DevToolsSession) {}
}

struct SourcesPanel: View {
    let session: DevToolsSession

    var body: some View {
        DevToolsPlaceholder(panel: .sources)
    }
}
