import Foundation
import Observation
import WebKit

/// One tab. The WKWebView is created lazily and dropped when the tab sleeps,
/// so a sleeping tab costs only its URL and title.
@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id: UUID
    var url: URL?
    var title: String
    var isLoading = false
    var estimatedProgress: Double = 0
    var canGoBack = false
    var canGoForward = false
    var lastActivated: Date
    var isPlayingAudio = false
    /// Saved logins for this page's site, shown as a bar above the page.
    var loginOffers: [Credential] = []
    /// A login the user just submitted that is not saved yet.
    var pendingSave: Credential?
    /// The page has a visible password field.
    var hasLoginForm = false

    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var controller: TabWebController?

    /// Mirrors `webView == nil` so views redraw when a tab sleeps or wakes.
    private(set) var isAsleep = true

    var displayTitle: String {
        if !title.isEmpty { return title }
        return url?.host() ?? "Новая вкладка"
    }

    init(id: UUID = UUID(), url: URL?, title: String = "", lastActivated: Date = .now) {
        self.id = id
        self.url = url
        self.title = title
        self.lastActivated = lastActivated
    }

    /// Returns the live web view, creating it (and loading `url`) if the tab was asleep.
    func wake(environment: WebEnvironment) -> WKWebView {
        if let webView { return webView }

        let controller = TabWebController(tab: self, environment: environment)
        let webView = WKWebView(frame: .zero, configuration: environment.makeConfiguration(for: controller))
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.navigationDelegate = controller
        webView.uiDelegate = controller
        webView.isInspectable = true

        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.title = view.title ?? "" }
            },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { if let url = view.url { self?.url = url } }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.estimatedProgress = view.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
            // ponytail: WebKit has no KVO for playback, so isPlayingAudio stays false;
            // poll requestMediaPlaybackState() if the speaker icon is needed.
        ]

        self.controller = controller
        self.webView = webView
        isAsleep = false
        if let url { webView.load(URLRequest(url: url)) }
        return webView
    }

    /// Frees the web view. The tab keeps its URL and title and reloads on the next wake.
    func sleep() {
        observations.removeAll()
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        controller = nil
        isAsleep = true
        isLoading = false
        isPlayingAudio = false
    }

    func fill(_ credential: Credential) {
        guard let webView, webView.url?.host() == credential.host else { return }
        webView.callAsyncJavaScript(
            "return window.__unibrowserFill && window.__unibrowserFill(username, password);",
            arguments: ["username": credential.username, "password": credential.password],
            in: nil,
            in: LoginFormScript.world,
            completionHandler: nil
        )
        loginOffers = []
    }

    func load(_ url: URL) {
        self.url = url
        webView?.load(URLRequest(url: url))
    }
}
