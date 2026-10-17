import SwiftUI

/// Panel «Производительность» (spec «Производительность»): its model and view. Stub.
@MainActor
@Observable
final class PerformanceModel {
    /// Called once by `DevToolsSession.init`: register message handlers with `session.on`.
    func bind(_ session: DevToolsSession) {}
}

struct PerformancePanel: View {
    let session: DevToolsSession

    var body: some View {
        DevToolsPlaceholder(panel: .performance)
    }
}
