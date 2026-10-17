import Foundation
import Network
import WebKit

/// Things every tab of one mode shares: its cookies and site data and, in the
/// via-Mac mode, the proxy that sends work domains through the Mac.
@MainActor
final class MobileWebEnvironment {
    weak var store: MobileStore?
    let mode: BrowsingMode
    let dataStore: WKWebsiteDataStore

    /// Fixed so the via-Mac cookies survive relaunches and stay apart from the normal mode.
    private static let viaMacStoreID = UUID(uuidString: "6B1F3C2E-8D4A-4F0B-9E57-2C1A9D7E5B30")!

    init(mode: BrowsingMode) {
        self.mode = mode
        switch mode {
        case .direct: dataStore = .default()
        case .viaMac: dataStore = WKWebsiteDataStore(forIdentifier: Self.viaMacStoreID)
        }
    }

    func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.allowsInlineMediaPlayback = true
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

/// Navigation and UI delegate for one tab's web view.
@MainActor
final class MobileTabController: NSObject {
    private weak var environment: MobileWebEnvironment?

    init(environment: MobileWebEnvironment) {
        self.environment = environment
    }
}

extension MobileTabController: WKNavigationDelegate {
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
