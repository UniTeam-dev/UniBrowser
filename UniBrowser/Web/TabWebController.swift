import Foundation
import WebKit

/// Navigation, UI and script-message delegate for one tab's web view.
@MainActor
final class TabWebController: NSObject {
    private weak var tab: BrowserTab?
    private weak var environment: WebEnvironment?

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
        return response.canShowMIMEType ? .allow : .cancel // WebKit's default
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        tab?.loginOffers = []
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
    }
}

extension TabWebController: WKUIDelegate {
    /// target="_blank" and window.open land in a new tab.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = action.request.url {
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
