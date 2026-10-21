import Foundation
import Network
import UIKit
import WebKit

/// Things every tab of one mode shares: its cookies and site data, the saved
/// logins and, in the via-Mac mode, the proxy that sends every page through the Mac.
@MainActor
final class MobileWebEnvironment {
    weak var store: MobileStore?
    let mode: BrowsingMode
    /// The mode's common store: spaces without «Отдельные входы».
    let dataStore: WKWebsiteDataStore
    /// Stores of this mode's spaces with separate logins, by store id; one object per store.
    private var separateStores: [UUID: WKWebsiteDataStore] = [:]
    /// The via-Mac proxy, which every store of the mode must use.
    private var proxies: [ProxyConfiguration] = []
    let passwords: PhonePasswords
    /// Per-site camera/microphone decisions and the ad-blocking allow list.
    let siteSettings: SiteSettingsStore

    /// The «Приватный» mode: in-memory site data, no session file, never synced.
    /// History recording must check this and record nothing.
    var isPrivate: Bool { mode == .private }

    /// Fixed so the via-Mac cookies survive relaunches and stay apart from the normal mode.
    private static let viaMacStoreID = UUID(uuidString: "6B1F3C2E-8D4A-4F0B-9E57-2C1A9D7E5B30")!

    init(mode: BrowsingMode, passwords: PhonePasswords, siteSettings: SiteSettingsStore) {
        self.mode = mode
        self.passwords = passwords
        self.siteSettings = siteSettings
        switch mode {
        case .direct: dataStore = .default()
        case .viaMac: dataStore = WKWebsiteDataStore(forIdentifier: Self.viaMacStoreID)
        case .private: dataStore = .nonPersistent()
        }
        ContentBlocker.shared.prepare()
    }

    /// The cookies and site data a tab uses: its space's own store when the space keeps
    /// separate logins, else the mode's common one. Private mode is always in memory.
    func dataStore(forTab tabID: UUID) -> WKWebsiteDataStore {
        guard mode != .private, let space = store?.spaces.first(where: { $0.allTabIDs.contains(tabID) }),
              space.separateLogins == true else { return dataStore }
        return separateStore(Space.loginStoreID(space.id, mode: mode.rawValue))
    }

    private func separateStore(_ id: UUID) -> WKWebsiteDataStore {
        if let existing = separateStores[id] { return existing }
        let new = WKWebsiteDataStore(forIdentifier: id)
        // Via Mac: a space's own store goes through the Mac like the common one.
        if !proxies.isEmpty { new.proxyConfigurations = proxies }
        separateStores[id] = new
        return new
    }

    /// Deletes a deleted space's own cookies and site data. Its tabs must be asleep by now.
    func removeSeparateStore(of spaceID: UUID) {
        guard mode != .private else { return }
        let id = Space.loginStoreID(spaceID, mode: mode.rawValue)
        separateStores[id] = nil
        Task {
            // Retried: WebKit refuses while a just-closed web view still holds the store.
            for attempt in 1...5 {
                do { return try await WKWebsiteDataStore.remove(forIdentifier: id) } catch {
                    if attempt == 5 { print("UniBrowser: space store not removed: \(error)") }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    func makeConfiguration(for controller: MobileTabController, dataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.allowsInlineMediaPlayback = true

        let content = WKUserContentController()
        content.addUserScript(WKUserScript(
            source: LoginFormScript.source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: LoginFormScript.world
        ))
        content.add(WeakScriptHandler(controller), contentWorld: LoginFormScript.world, name: LoginFormScript.handlerName)
        configuration.userContentController = content
        return configuration
    }

    /// Search suggestions travel like the pages: in the via-Mac mode, through the Mac.
    private(set) var suggestionSession = URLSession.shared

    /// Set once at launch, before any page loads.
    func apply(proxies: [ProxyConfiguration]) {
        self.proxies = proxies
        dataStore.proxyConfigurations = proxies
        for store in separateStores.values { store.proxyConfigurations = proxies }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = proxies
        suggestionSession = URLSession(configuration: configuration)
    }

    /// Clears cookies, cache and storage of this mode only: the common store and every space's own.
    func eraseWebsiteData() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await dataStore.removeData(ofTypes: types, modifiedSince: .distantPast)
        guard mode != .private else { return }
        let existing = Set(await WKWebsiteDataStore.allDataStoreIdentifiers)
        for space in store?.spaces ?? [] {
            let id = Space.loginStoreID(space.id, mode: mode.rawValue)
            if existing.contains(id) { await separateStore(id).removeData(ofTypes: types, modifiedSince: .distantPast) }
        }
    }
}

/// WKUserContentController retains its handlers; this breaks the
/// controller → web view → configuration → controller cycle.
@MainActor
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Navigation, UI and login-form delegate for one tab's web view.
@MainActor
final class MobileTabController: NSObject {
    private weak var tab: MobileTab?
    private weak var environment: MobileWebEnvironment?
    /// Content-blocker lists on this web view's loads now (see ContentBlocker.apply).
    private var blockingLists = 0

    init(tab: MobileTab, environment: MobileWebEnvironment) {
        self.tab = tab
        self.environment = environment
    }
}

extension MobileTabController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        // Web content must never open an SSH tab.
        if action.request.url?.isSSHScheme == true { return (.cancel, preferences) }
        if action.shouldPerformDownload { return (.download, preferences) } // <a download>, blob: and data: links
        if action.targetFrame?.isMainFrame == true, let environment {
            await ContentBlocker.shared.prepare().value
            ContentBlocker.shared.apply(to: webView.configuration.userContentController, url: action.request.url,
                                        settings: environment.siteSettings, applied: &blockingLists)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        Downloads.policy(for: response)
    }

    /// HTTP auth (nginx auth_basic and the like): WebKit has no dialog of its own.
    func webView(
        _ webView: WKWebView,
        respondTo challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.isHTTPAuth, var presenter = webView.window?.rootViewController else {
            return (.performDefaultHandling, nil)
        }
        while let next = presenter.presentedViewController { presenter = next }
        let alert = UIAlertController(title: "Вход", message: space.loginPrompt(failed: challenge.previousFailureCount > 0),
                                      preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "Имя пользователя"
            $0.text = challenge.proposedCredential?.user
            $0.textContentType = .username
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
        }
        alert.addTextField {
            $0.placeholder = "Пароль"
            $0.isSecureTextEntry = true
            $0.textContentType = .password
        }
        return await withCheckedContinuation { done in
            // Cancel shows the server's 401 page, as other browsers do.
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in done.resume(returning: (.rejectProtectionSpace, nil)) })
            alert.addAction(UIAlertAction(title: "Войти", style: .default) { [weak alert] _ in
                let fields = alert?.textFields ?? []
                let credential = URLCredential(user: (fields.first?.text ?? "").trimmingCharacters(in: .whitespaces), password: fields.last?.text ?? "",
                                               persistence: .forSession)
                done.resume(returning: (.useCredential, credential))
            })
            presenter.present(alert, animated: true)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        Downloads.shared.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        Downloads.shared.track(download)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // A cancelled load (a new one replaced it, or a download took over) isn't a failure.
        if (error as NSError).code != NSURLErrorCancelled { tab?.loadFailed = true }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        tab?.loadFailed = false
        tab?.permissionRequest?.cancel()
        tab?.loginOffers = []
        tab?.applyZoom(PageZoom.level(for: webView.url?.host()))
        tab?.isReadable = false
        tab?.reader = nil
        // A login usually redirects; the save prompt waits for the user unless the site changed.
        if tab?.pendingSave?.host != webView.url?.host() { tab?.pendingSave = nil }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        environment?.store?.scheduleSave()
        if let url = webView.url { environment?.store?.history?.record(url: url, title: webView.title ?? "") }
        if let tab, tab.pageZoom != 1 { tab.applyZoom(tab.pageZoom) } // the style set at commit may predate <html>
        if tab?.isMuted == true { tab?.applyMute() }
        Task { [weak tab] in
            let isReadable = await ReaderMode.isReadable(webView)
            if tab?.webView === webView { tab?.isReadable = isReadable }
        }
    }
}

extension MobileTabController: WKUIDelegate {
    /// Camera and microphone: the stored decision, or the bar above the page. Public API (iOS 15+).
    /// Geolocation has no public delegate on iOS; WebKit asks for it with its own alert.
    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        guard let tab, let environment else { return .deny }
        let permissions: [SitePermission] = switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        default: [.camera, .microphone]
        }
        var shown: PermissionRequest?
        let allowed = await environment.siteSettings.resolve(permissions, host: origin.host) { request in
            tab.permissionRequest?.cancel()
            tab.permissionRequest = request
            shown = request
        }
        if let shown, tab.permissionRequest === shown { tab.permissionRequest = nil }
        return allowed ? .grant : .deny
    }

    /// target="_blank" and window.open land in a new tab.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = action.request.url, !url.isSSHScheme {
            environment?.store?.newTab(url: url)
        }
        return nil
    }
}

extension MobileTabController: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only trust the top frame, and only for the origin it actually loaded.
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let action = body["action"] as? String,
              let host = message.frameInfo.request.url?.host(),
              message.frameInfo.securityOrigin.host == host,
              let tab, let environment
        else { return }

        switch action {
        case "formFound":
            tab.loginOffers = environment.passwords.credentials(for: host)
        case "submitted":
            guard let username = body["username"] as? String,
                  let password = body["password"] as? String, !password.isEmpty
            else { return }
            let credential = SyncedCredential(host: host, username: username, password: password)
            if !environment.passwords.credentials(for: host).contains(credential) {
                tab.pendingSave = credential
            }
        default:
            break
        }
    }
}
