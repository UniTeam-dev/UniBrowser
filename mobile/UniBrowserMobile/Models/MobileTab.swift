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
    /// The last load failed before the page showed (e.g. the Mac wasn't connected yet).
    var loadFailed = false
    var estimatedProgress: Double = 0
    var canGoBack = false
    var canGoForward = false
    var lastActivated: Date
    /// Saved logins for this page's site, shown as a bar above the page.
    var loginOffers: [SyncedCredential] = []
    /// A login the user just submitted that is not saved yet.
    var pendingSave: SyncedCredential?
    /// The site's zoom from «aA» in «…».
    var pageZoom = 1.0
    /// A camera/microphone request waiting in the bar above the page.
    var permissionRequest: PermissionRequest?
    /// Readability thinks the page is an article: «…» offers «Режим чтения».
    var isReadable = false
    /// The article shown in reader mode; nil shows the page.
    var reader: ReaderArticle?
    /// «Выключить звук» in «…»; re-applied after each page load.
    var isMuted = false

    /// Observed, so the page view re-attaches when the tab sleeps on screen (its space's store changed).
    private(set) var webView: WKWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var controller: MobileTabController?

    /// The connection of an `unibrowser-ssh` tab while it is awake.
    private(set) var sshSession: SSHSession?
    /// Its terminal, kept with the session so switching tabs keeps the screen.
    @ObservationIgnored private(set) var sshTerminal: SSHTerminalView?
    /// Its «Файлы» and transfers.
    private(set) var sshFiles: SFTPBrowser?
    /// How the session reaches the server, for the status line.
    private(set) var sshRoute: SSHRoute = .direct
    /// Logged in again by itself after the app came back: the status line says «Новая сессия».
    var isNewSSHSession = false

    var isSSH: Bool { url?.sshHostID != nil }

    var displayTitle: String {
        if let customTitle { return customTitle }
        if !title.isEmpty { return title }
        if isSSH { return "SSH" }
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
    /// An SSH tab's address is never loaded: its web view stays blank.
    func wake(environment: MobileWebEnvironment) -> WKWebView {
        if let webView { return webView }

        let controller = MobileTabController(tab: self, environment: environment)
        let configuration = environment.makeConfiguration(for: controller, dataStore: environment.dataStore(forTab: id))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = controller
        webView.uiDelegate = controller
        webView.isInspectable = true

        observations = [
            webView.observe(\.title, options: [.new]) { [weak self, weak environment] view, _ in
                MainActor.assumeIsolated {
                    self?.title = view.title ?? ""
                    if let url = view.url { environment?.store?.history?.updateTitle(url: url, title: view.title ?? "") }
                }
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
        if let url, !url.isSSHScheme { webView.load(URLRequest(url: url)) }
        return webView
    }

    /// Opens the SSH tab's session and terminal; the view then connects.
    func wakeSSH(host: SSHHost, secret: SSHSecret, knownHosts: KnownHostsStore, history: CommandHistory, route: SSHRoute) {
        guard sshSession == nil else { return }
        let session = SSHSession(host: host, secret: secret, knownHosts: knownHosts, route: route)
        let files = SFTPBrowser(session: session)
        let suggestions = SuggestionEngine(session: session, browser: files, history: history,
                                           commandsCacheURL: LibraryFiles.url("ssh-commands/\(host.id.uuidString.lowercased()).json"))
        sshTerminal = SSHTerminalView(session: session, suggestions: suggestions)
        sshFiles = files
        sshRoute = route
        sshSession = session
    }

    /// Frees the web view or closes the SSH session. The tab keeps its URL and title and reloads on the next wake.
    func sleep() {
        sshSession?.close()
        sshSession = nil
        sshTerminal?.removeFromSuperview()
        sshTerminal = nil
        sshFiles = nil
        isNewSSHSession = false
        permissionRequest?.cancel()
        permissionRequest = nil
        observations.removeAll()
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        controller = nil
        isLoading = false
        isReadable = false
        reader = nil
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        applyMute()
    }

    /// Public API only (App Store): mutes the page's <audio>/<video> from script, now and as they start.
    /// ponytail: main frame and in-document media only; Web Audio, detached `new Audio()` and
    /// iframes keep playing. WebKit's page-level mute is private on iOS.
    func applyMute() {
        guard let webView else { return }
        webView.evaluateJavaScript("""
            (function (muted) {
              window.__unibrowserMuted = muted;
              document.querySelectorAll('audio, video').forEach(function (m) { m.muted = muted; });
              if (!window.__unibrowserMuteHook) {
                window.__unibrowserMuteHook = true;
                document.addEventListener('play', function (e) { if (window.__unibrowserMuted && e.target) e.target.muted = true; }, true);
              }
            })(\(isMuted));
            """, in: nil, in: ReaderMode.world, completionHandler: nil)
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
        guard !url.isSSHScheme else { return } // SSH tabs are made by `MobileStore.openSSH`, restore and the mirror only
        // Between a server and a page the tab sleeps; the view for the new kind wakes it.
        if isSSH { sleep() }
        self.url = url
        webView?.load(URLRequest(url: url))
    }
}
