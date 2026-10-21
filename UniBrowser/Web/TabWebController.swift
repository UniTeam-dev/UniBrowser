import Foundation
import WebKit

/// Navigation, UI and script-message delegate for one tab's web view.
@MainActor
final class TabWebController: NSObject {
    private weak var tab: BrowserTab?
    private weak var environment: WebEnvironment?
    /// Content-blocker lists on this web view's loads now (see ContentBlocker.apply).
    private var blockingLists = 0

    init(tab: BrowserTab, environment: WebEnvironment) {
        self.tab = tab
        self.environment = environment
    }
}

extension TabWebController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        // Web content must never open an SSH tab.
        if action.request.url?.isSSHScheme == true { return (.cancel, preferences) }
        // Option+click peeks at the link without making a tab.
        if action.modifierFlags.contains(.option), action.navigationType == .linkActivated,
           let url = action.request.url, let onPeek = environment?.onPeek {
            onPeek(url)
            return (.cancel, preferences)
        }
        // Cmd+click opens the link in a new background tab, like other browsers.
        if action.modifierFlags.contains(.command), action.navigationType == .linkActivated,
           let url = action.request.url {
            environment?.store?.newTab(url: url, select: false)
            return (.cancel, preferences)
        }
        // <a download>, blob: and data: links included.
        if action.shouldPerformDownload { return (.download, preferences) }
        if action.targetFrame?.isMainFrame == true, let environment {
            await ContentBlocker.shared.prepare().value
            ContentBlocker.shared.apply(to: webView.configuration.userContentController, url: action.request.url,
                                        settings: environment.siteSettings, applied: &blockingLists)
        }
        // «Рендеринг» → «Отключить JavaScript»; injected scripts (devtools.js) still run.
        if tab?.devTools?.rendering.isJavaScriptDisabled == true { preferences.allowsContentJavaScript = false }
        // DevTools «Отключить кэш»: a reload becomes reloadFromOrigin.
        if action.navigationType == .reload, action.targetFrame?.isMainFrame == true,
           tab?.devTools?.network.redirectsReload(webView) == true {
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        tab?.devTools?.network.navigationResponse(response) // DevTools «Сеть»: documents
        return Downloads.policy(for: response)
    }

    /// HTTP auth (nginx auth_basic and the like): WebKit has no dialog of its own.
    func webView(
        _ webView: WKWebView,
        respondTo challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.isHTTPAuth else { return (.performDefaultHandling, nil) }
        let alert = NSAlert()
        alert.messageText = "Вход"
        alert.informativeText = space.loginPrompt(failed: challenge.previousFailureCount > 0)
        let user = NSTextField(string: challenge.proposedCredential?.user ?? "")
        user.placeholderString = "Имя пользователя"
        let password = NSSecureTextField(string: "")
        password.placeholderString = "Пароль"
        // Fixed frames: a stack view shrinks empty fields to a few points.
        user.frame = NSRect(x: 0, y: 30, width: 260, height: 22)
        password.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 52))
        fields.addSubview(user)
        fields.addSubview(password)
        alert.accessoryView = fields
        alert.addButton(withTitle: "Войти")
        alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = user.stringValue.isEmpty ? user : password
        let response = if let window = webView.window {
            await alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
        // Cancel shows the server's 401 page, as other browsers do.
        guard response == .alertFirstButtonReturn else { return (.rejectProtectionSpace, nil) }
        return (.useCredential, URLCredential(user: user.stringValue.trimmingCharacters(in: .whitespaces), password: password.stringValue, persistence: .forSession))
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        Downloads.shared.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        Downloads.shared.track(download)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        tab?.blockedCount = 0
        tab?.permissionRequest?.cancel()
        tab?.loginOffers = []
        tab?.applyZoom(PageZoom.level(for: webView.url?.host()))
        tab?.isReadable = false
        tab?.reader = nil
        // The save prompt outlives the navigation: a login usually redirects, often to another
        // host (id.site.ru → site.ru, an SSO provider → the app). It stays until answered.
        tab?.hasLoginForm = false
        tab?.loginFrame = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        environment?.store?.scheduleSave()
        if let url = webView.url { environment?.history?.record(url: url, title: webView.title ?? "") }
        if let tab { environment?.extensions.tabChanged(tab) }
        Task { [weak tab] in
            try? await Task.sleep(for: .seconds(1)) // let the page paint first
            tab?.captureThumbnail()
        }
        Task { [weak tab] in
            let isReadable = await ReaderMode.isReadable(webView)
            if tab?.webView === webView { tab?.isReadable = isReadable }
        }
    }
}

// MARK: - Private WebKit (website build): blocked-request count, geolocation, notifications

extension TabWebController {
    /// WKNavigationDelegatePrivate: a content-blocker rule acted on a load of this page.
    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func contentRuleListPerformedAction(_ webView: WKWebView, identifier: String, action: NSObject, url: URL) {
        if action.value(forKey: "blockedLoad") as? Bool == true { tab?.blockedCount += 1 }
    }

    /// WKUIDelegatePrivate: navigator.geolocation. WebKit denies it without this.
    @objc(_webView:requestGeolocationPermissionForFrame:decisionHandler:)
    func requestGeolocationPermission(_ webView: WKWebView, frame: WKFrameInfo, decisionHandler: @escaping (Bool) -> Void) {
        let host = frame.securityOrigin.host
        Task { decisionHandler(await ask([.geolocation], host: host)) }
    }

    /// WKUIDelegatePrivate: Notification.requestPermission(). Only the decision is kept: showing
    /// web notifications needs WebKit's private notification provider, which isn't wired.
    @objc(_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:)
    func requestNotificationPermission(_ webView: WKWebView, origin: WKSecurityOrigin, decisionHandler: @escaping (Bool) -> Void) {
        let host = origin.host
        Task { decisionHandler(await ask([.notifications], host: host)) }
    }

    /// The stored decision, or the tab's prompt bar.
    func ask(_ permissions: [SitePermission], host: String) async -> Bool {
        guard let tab, let environment else { return false }
        var shown: PermissionRequest?
        let allowed = await environment.siteSettings.resolve(permissions, host: host) { request in
            tab.permissionRequest?.cancel()
            tab.permissionRequest = request
            shown = request
        }
        if let shown, tab.permissionRequest === shown { tab.permissionRequest = nil }
        return allowed
    }
}

extension TabWebController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        let permissions: [SitePermission] = switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        default: [.camera, .microphone]
        }
        return await ask(permissions, host: origin.host) ? .grant : .deny
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

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return panel.runModal() == .OK ? panel.urls : nil
    }
}

extension TabWebController: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Any frame may report its own login, but only for the origin it actually loaded.
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String,
              let host = message.frameInfo.request.url?.host(),
              message.frameInfo.securityOrigin.host == host,
              let tab, let environment
        else { return }

        switch action {
        case "formFound":
            tab.hasLoginForm = true
            tab.loginFrame = message.frameInfo
            Task {
                let offers = (try? await environment.passwords.credentials(for: host)) ?? []
                tab.loginOffers = offers
            }
        case "submitted":
            guard let username = body["username"] as? String,
                  let password = body["password"] as? String, !password.isEmpty
            else { return }
            let credential = Credential(host: host, username: username, password: password)
            Task {
                let existing = (try? await environment.passwords.credentials(for: host)) ?? []
                if !existing.contains(credential) {
                    tab.pendingSave = credential
                }
            }
        default:
            break
        }
    }
}
