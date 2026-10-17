import SwiftUI

/// Panel «Элементы» (spec «Элементы»): its model and view. Stub.
@MainActor
@Observable
final class ElementsModel {
    /// Called once by `DevToolsSession.init`: register message handlers with `session.on`.
    func bind(_ session: DevToolsSession) {}

    /// ⇧⌘C: pick an element on the page. Stub: the menu opens Элементы and calls this.
    func pick() {}
}

struct ElementsPanel: View {
    let session: DevToolsSession

    var body: some View {
        DevToolsPlaceholder(panel: .elements)
    }
}
