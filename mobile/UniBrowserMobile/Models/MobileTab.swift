import Foundation
import Observation
import WebKit

/// One tab. The WKWebView is created lazily and dropped when the tab sleeps,
/// so a sleeping tab costs only its URL and title.
@MainActor
@Observable
final class MobileTab: Identifiable {
    let id: UUID
    var url: URL?
    var title: String
    /// The name the user gave the tab; nil shows the page title.
    var customTitle: String?
    /// The address the tab had when it was pinned; nil when not pinned.
    var pinnedURL: URL?
    var isLoading = false
    var estimatedProgress: Double = 0
    var canGoBack = false
    var canGoForward = false
    var lastActivated: Date
    /// Saved logins for this page's site, shown as a bar above the page.
    var loginOffers: [SyncedCredential] = []
    /// A login the user just submitted that is not saved yet.
    var pendingSave: SyncedCredential?

    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var controller: MobileTabController?

    var displayTitle: String {
        if let customTitle { return customTitle }
        if !title.isEmpty { return title }
        return url?.host() ?? "Новая вкладка"
    }

    init(id: UUID = UUID(), url: URL?, title: String = "", customTitle: String? = nil, pinnedURL: URL? = nil, lastActivated: Date = .now) {
        self.id = id
        self.pinnedURL = pinnedURL
        self.customTitle = customTitle
        self.url = url
        self.title = title
        self.lastActivated = lastActivated
    }

    /// Returns the live web view, creating it (and loading `url`) if the tab was asleep.
    func wake(environment: MobileWebEnvironment) -> WKWebView {
        if let webView { return webView }

        let controller = MobileTabController(tab: self, environment: environment)
        let webView = WKWebView(frame: .zero, configuration: environment.makeConfiguration(for: controller))
        webView.allowsBackForwardNavigationGestures = true
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
        ]

        self.controller = controller
        self.webView = webView
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
        isLoading = false
    }

    func fill(_ credential: SyncedCredential) {
        guard let webView else { return }
        webView.callAsyncJavaScript(
            "return window.__unibrowserFill && window.__unibrowserFill(username, password);",
            arguments: ["username": credential.username, "password": credential.password],
            in: nil,
            in: LoginFormScript.world,
            completionHandler: nil
        )
        loginOffers = []
    }

    /// The tab is pinned and has wandered off the page it was pinned on.
    var isAwayFromPin: Bool { pinnedURL != nil && pinnedURL != url }

    func load(_ url: URL) {
        self.url = url
        webView?.load(URLRequest(url: url))
    }
}
