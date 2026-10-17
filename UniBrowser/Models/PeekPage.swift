import Foundation
import Observation
import WebKit

/// A temporary page shown in Peek. It shares cookies with the tabs but is not a tab:
/// closing Peek throws it away.
@MainActor
@Observable
final class PeekPage {
    let webView: WKWebView
    let sourceTabID: UUID?
    private(set) var url: URL?
    private(set) var title = ""
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(url: URL, sourceTabID: UUID?, configuration: WKWebViewConfiguration) {
        self.url = url
        self.sourceTabID = sourceTabID
        webView = WKWebView(frame: .zero, configuration: configuration)
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { if let url = view.url { self?.url = url } }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.title = view.title ?? "" }
            },
        ]
        webView.load(URLRequest(url: url))
    }
}
