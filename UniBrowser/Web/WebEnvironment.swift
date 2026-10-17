import Foundation
import WebKit

/// Things every tab's web view shares: cookies and site data, the login-form
/// script, and the password provider.
@MainActor
final class WebEnvironment {
    weak var store: BrowserStore?
    let dataStore = WKWebsiteDataStore.default()
    let passwords: CredentialProvider
    let extensions: ExtensionManager
    /// ⌥+click on a link; AppModel shows the URL in Peek.
    var onPeek: ((URL) -> Void)?

    init(passwords: CredentialProvider) {
        self.passwords = passwords
        extensions = ExtensionManager(dataStore: dataStore)
    }

    /// Shared cookies and user agent, no tab scripts: what Peek's temporary page uses.
    func makeBaseConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        #if DIRECT
        WebInspector.enable(configuration)
        #endif
        return configuration
    }

    func makeConfiguration(for controller: TabWebController) -> WKWebViewConfiguration {
        let configuration = makeBaseConfiguration()
        // Lets installed extensions inject content scripts into tabs.
        configuration.webExtensionController = extensions.controller

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
