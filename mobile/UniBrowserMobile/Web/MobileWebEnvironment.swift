import Foundation
import Network
import WebKit

/// Things every tab of one mode shares: its cookies and site data, the saved
/// logins and, in the via-Mac mode, the proxy that sends the listed domains through the Mac.
@MainActor
final class MobileWebEnvironment {
    weak var store: MobileStore?
    let mode: BrowsingMode
    let dataStore: WKWebsiteDataStore
    let passwords: PhonePasswords

    /// Fixed so the via-Mac cookies survive relaunches and stay apart from the normal mode.
    private static let viaMacStoreID = UUID(uuidString: "6B1F3C2E-8D4A-4F0B-9E57-2C1A9D7E5B30")!

    init(mode: BrowsingMode, passwords: PhonePasswords) {
        self.mode = mode
        self.passwords = passwords
        switch mode {
        case .direct: dataStore = .default()
        case .viaMac: dataStore = WKWebsiteDataStore(forIdentifier: Self.viaMacStoreID)
        }
    }

    func makeConfiguration(for controller: MobileTabController) -> WKWebViewConfiguration {
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

    /// Applies to loads that start after the call; open pages keep their old route until reloaded.
    func apply(proxies: [ProxyConfiguration]) {
        dataStore.proxyConfigurations = proxies
    }

    /// Clears cookies, cache and storage of this mode only.
    func eraseWebsiteData() async {
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
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

    init(tab: MobileTab, environment: MobileWebEnvironment) {
        self.tab = tab
        self.environment = environment
    }
}

extension MobileTabController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        tab?.loginOffers = []
        // A login usually redirects; the save prompt waits for the user unless the site changed.
        if tab?.pendingSave?.host != webView.url?.host() { tab?.pendingSave = nil }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        environment?.store?.scheduleSave()
    }
}

extension MobileTabController: WKUIDelegate {
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
