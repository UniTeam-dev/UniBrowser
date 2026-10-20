import AppKit
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
    /// The name the user gave the tab; nil shows the page title.
    var customTitle: String?
    /// The address the tab had when it was pinned; nil when not pinned.
    var pinnedURL: URL?
    var isLoading = false
    var estimatedProgress: Double = 0
    var canGoBack = false
    var canGoForward = false
    var lastActivated: Date
    var isPlayingAudio = false
    /// Muted from the tab row; kept while the tab sleeps and applied when it wakes.
    var isMuted = false
    /// Readability thinks the page is an article: the address strip shows the reader button.
    var isReadable = false
    /// The article shown in reader mode; nil shows the page.
    var reader: ReaderArticle?
    /// Saved logins for this page's site, shown as a bar above the page.
    var loginOffers: [Credential] = []
    /// A login the user just submitted that is not saved yet.
    var pendingSave: Credential?
    /// A camera/microphone/geolocation/notifications request waiting in the bar above the page.
    var permissionRequest: PermissionRequest?
    /// Loads the content blocker stopped on this page.
    var blockedCount = 0
    /// The page has a visible password field.
    var hasLoginForm = false
    /// The frame that showed the login form (the page itself or an iframe), where `fill` types.
    @ObservationIgnored var loginFrame: WKFrameInfo?
    /// Last page snapshot, for the tab map and evening cleanup.
    var thumbnail: NSImage?
    /// Developer tools of the live page; nil while asleep, so sleeping closes the panel.
    private(set) var devTools: DevToolsSession?
    /// «Режим устройства» stays on with the panel closed.
    let deviceMode = DeviceMode()
    /// ⌘F bar state.
    let find = FindInPage()
    /// The site's zoom (⌘+ / ⌘−), shown in the address strip when not 1.
    var pageZoom = 1.0

    @ObservationIgnored private(set) var webView: WKWebView?
    /// The web view's own superview. WebKit docks its inspector beside the web view in
    /// this view, so the inspector stays with its tab when the window switches tabs.
    @ObservationIgnored private(set) var hostView: NSView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var controller: TabWebController?
    @ObservationIgnored private var audioObserver: NSObject?

    /// The connection of an `unibrowser-ssh` tab while it is awake.
    private(set) var sshSession: SSHSession?
    /// Its terminal, kept with the session so switching tabs keeps the screen.
    @ObservationIgnored private(set) var sshTerminal: SSHTerminalView?
    /// Its «Файлы» panel and transfers, kept while the panel is hidden.
    private(set) var sshFiles: SFTPBrowser?
    /// ⌘⇧F.
    var isFilesVisible = false

    /// Mirrors `webView == nil` (or `sshSession == nil`) so views redraw when a tab sleeps or wakes.
    private(set) var isAsleep = true

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

    /// Returns the live web view, creating it (and loading `url`) if the tab was asleep,
    /// with the cookies and site data of the space the tab is in. Never for an SSH tab.
    func wake(environment: WebEnvironment) -> WKWebView? {
        if let webView { return webView }
        guard !isSSH else { return nil }

        let controller = TabWebController(tab: self, environment: environment)
        let devTools = DevToolsSession()
        let configuration = environment.makeConfiguration(for: controller, devTools: devTools, dataStore: environment.dataStore(forTab: id))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        devTools.webView = webView
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.navigationDelegate = controller
        webView.uiDelegate = controller
        webView.isInspectable = true

        observations = [
            webView.observe(\.title, options: [.new]) { [weak self, weak environment] view, _ in
                MainActor.assumeIsolated {
                    self?.title = view.title ?? ""
                    if let url = view.url { environment?.history?.updateTitle(url: url, title: view.title ?? "") }
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
        audioObserver = TabAudio.observe(webView) { [weak self] in self?.isPlayingAudio = $0 }
        if isMuted { TabAudio.setMuted(true, webView) }

        let hostView = NSView()
        webView.frame = hostView.bounds
        webView.autoresizingMask = [.width, .height]
        hostView.addSubview(webView)

        self.controller = controller
        self.devTools = devTools
        self.webView = webView
        self.hostView = hostView
        isAsleep = false
        if let url { webView.load(URLRequest(url: url)) }
        return webView
    }

    /// Opens the SSH tab's session and terminal; the view then connects. The Mac always goes direct.
    func wakeSSH(host: SSHHost, secret: SSHSecret, knownHosts: KnownHostsStore, history: CommandHistory) {
        guard sshSession == nil else { return }
        let session = SSHSession(host: host, secret: secret, knownHosts: knownHosts, route: .direct)
        let files = SFTPBrowser(session: session)
        let suggestions = SuggestionEngine(session: session, browser: files, history: history,
                                           commandsCacheURL: LibraryFiles.url("ssh-commands/\(host.id.uuidString.lowercased()).json"))
        sshTerminal = SSHTerminalView(session: session, hostID: host.id, suggestions: suggestions)
        sshFiles = files
        sshSession = session
        isAsleep = false
    }

    /// ⌘R: reloads the page; an SSH tab that isn't connected logs in again.
    func reload() {
        if let sshTerminal { sshTerminal.connect() } else if !isSSH { webView?.reload() } // an SSH tab without a terminal has no host: nothing to do
    }

    /// Frees the web view or closes the SSH session. The tab keeps its URL and title and reloads on the next wake.
    func sleep() {
        sshSession?.close()
        sshSession = nil
        sshTerminal?.removeFromSuperview()
        sshTerminal = nil
        sshFiles = nil
        permissionRequest?.cancel()
        permissionRequest = nil
        observations.removeAll()
        audioObserver = nil
        devTools?.close()
        devTools = nil
        webView?.stopLoading()
        hostView?.removeFromSuperview()
        hostView = nil
        webView = nil
        controller = nil
        isAsleep = true
        isLoading = false
        isPlayingAudio = false
        isReadable = false
        reader = nil
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        if let webView { TabAudio.setMuted(muted, webView) }
    }

    func fill(_ credential: Credential) {
        guard let webView else { return }
        // Only into the frame whose site the login belongs to.
        let frame = loginFrame?.securityOrigin.host == credential.host ? loginFrame : nil
        guard frame != nil || webView.url?.host() == credential.host else { return }
        webView.callAsyncJavaScript(
            "return window.__unibrowserFill && window.__unibrowserFill(username, password);",
            arguments: ["username": credential.username, "password": credential.password],
            in: frame,
            in: LoginFormScript.world,
            completionHandler: nil
        )
        loginOffers = []
    }

    /// Snapshots the page while it is on screen; a web view outside the window draws nothing.
    func captureThumbnail() {
        guard let webView, webView.window != nil, !webView.bounds.isEmpty else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 480
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            MainActor.assumeIsolated {
                if let image { self?.thumbnail = image }
            }
        }
    }

    /// The tab is pinned and has wandered off the page it was pinned on.
    var isAwayFromPin: Bool { pinnedURL != nil && pinnedURL != url }

    func load(_ url: URL) {
        guard !url.isSSHScheme else { return } // SSH tabs are made by `BrowserStore.openSSH` only
        // Between a page and an SSH host the tab sleeps; the view for the new kind wakes it.
        if isSSH { sleep() }
        self.url = url
        webView?.load(URLRequest(url: url))
    }
}
