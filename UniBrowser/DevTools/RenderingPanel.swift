import SwiftUI

/// Panel «Рендеринг» (spec «Рендеринг»): its model and view. Stub.
@MainActor
@Observable
final class RenderingModel {
    /// Called once by `DevToolsSession.init`: register message handlers with `session.on`.
    func bind(_ session: DevToolsSession) {}
}

struct RenderingPanel: View {
    let session: DevToolsSession

    var body: some View {
        DevToolsPlaceholder(panel: .rendering)
    }
}
