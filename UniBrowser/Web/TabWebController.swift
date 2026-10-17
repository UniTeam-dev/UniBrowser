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
        // Cmd+click opens the link in a new background tab, like other browsers.
        if action.modifierFlags.contains(.command), action.navigationType == .linkActivated,
           let url = action.request.url {
            environment?.store?.newTab(url: url, select: false)
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        tab?.loginOffers = []
        tab?.pendingSave = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        environment?.store?.scheduleSave()
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
