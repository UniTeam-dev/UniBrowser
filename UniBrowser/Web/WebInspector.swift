import WebKit

/// WebKit's own Web Inspector (Elements, Console, Sources with the debugger, Network,
/// Timelines, Storage), docked in the tab like Chrome's DevTools.
/// It is private WebKit API, which is fine: the Mac app is distributed from the website only.
@MainActor
enum WebInspector {
    /// Adds «Inspect Element» to the page's context menu.
    static func enable(_ configuration: WKWebViewConfiguration) {
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
    }

    static func toggle(_ webView: WKWebView) {
        let isVisible = inspector(of: webView)?.value(forKey: "isVisible") as? Bool ?? false
        send(isVisible ? "close" : "show", to: webView)
    }

    static func showConsole(_ webView: WKWebView) {
        send("showConsole", to: webView)
    }

    static func pickElement(_ webView: WKWebView) {
        send("show", to: webView)
        send("toggleElementSelection", to: webView)
    }

    private static func inspector(of webView: WKWebView) -> NSObject? {
        let selector = NSSelectorFromString("_inspector")
        guard webView.responds(to: selector) else { return nil }
        return webView.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    private static func send(_ name: String, to webView: WKWebView) {
        let selector = NSSelectorFromString(name)
        guard let inspector = inspector(of: webView), inspector.responds(to: selector) else { return }
        inspector.perform(selector)
    }
}
