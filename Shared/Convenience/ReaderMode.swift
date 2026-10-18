import SwiftUI
import WebKit

/// The page's article as Mozilla's Readability.js (Apache 2.0, bundled next to this file) extracts it.
struct ReaderArticle: Equatable, Sendable, Decodable {
    var title: String?
    var byline: String?
    var siteName: String?
    /// Readability's cleaned HTML: no scripts, styles or forms.
    var content: String
    var url: URL?
}

enum ReaderTheme: String, CaseIterable, Identifiable {
    case light, sepia, dark
    var id: Self { self }

    var title: String {
        switch self {
        case .light: "Светлая"
        case .sepia: "Сепия"
        case .dark: "Тёмная"
        }
    }

    /// Background, text and link colours.
    var colors: (background: String, text: String, link: String) {
        switch self {
        case .light: ("#FFFFFF", "#1D1D1F", "#0A66D8")
        case .sepia: ("#F8F1E3", "#4F3A26", "#9A5A1E")
        case .dark: ("#1C1C1E", "#E5E5EA", "#64A8FF")
        }
    }
}

/// Reader mode. Readability runs in its own content world, so the page's scripts
/// neither see it nor can tamper with it; the article is shown in a separate web view
/// with JavaScript off.
@MainActor
enum ReaderMode {
    static let world = WKContentWorld.world(name: "UniBrowserReader")

    private static func bundled(_ name: String) -> String {
        Bundle.main.url(forResource: name, withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    private static let readerable = bundled("Readability-readerable")
    private static let readability = bundled("Readability")

    /// Readability's quick check, for the reader button. Cheap: run it after each page load.
    static func isReadable(_ webView: WKWebView) async -> Bool {
        guard ["http", "https"].contains(webView.url?.scheme ?? ""), !readerable.isEmpty else { return false }
        return await evaluate(readerable + "\n;String(isProbablyReaderable(document))", in: webView) == "true"
    }

    /// The article, or nil when Readability finds none.
    static func article(from webView: WKWebView) async -> ReaderArticle? {
        guard !readability.isEmpty,
              let json = await evaluate(readability + "\n;JSON.stringify(new Readability(document.cloneNode(true)).parse())", in: webView),
              var article = try? JSONDecoder().decode(ReaderArticle.self, from: Data(json.utf8))
        else { return nil }
        article.url = webView.url
        return article
    }

    private static func evaluate(_ source: String, in webView: WKWebView) async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(source, in: nil, in: world) { result in
                continuation.resume(returning: try? result.get() as? String)
            }
        }
    }

    /// The clean page. The CSP keeps any script out even if Readability let one through.
    static func html(_ article: ReaderArticle, fontSize: Int, theme: ReaderTheme) -> String {
        let colors = theme.colors
        let meta = [article.byline, article.siteName].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src * data:; media-src *; style-src 'unsafe-inline'">
        <style>
        :root { color-scheme: \(theme == .dark ? "dark" : "light"); }
        body { background: \(colors.background); color: \(colors.text); font: \(fontSize)px/1.6 "New York", Georgia, serif;
               max-width: 38em; margin: 0 auto; padding: 32px 22px 64px; -webkit-text-size-adjust: none; }
        h1 { font: 700 1.6em/1.25 -apple-system, sans-serif; margin: 0 0 .3em; }
        .meta { font: .8em -apple-system, sans-serif; opacity: .65; margin-bottom: 2em; }
        a { color: \(colors.link); }
        img, video, figure, iframe { max-width: 100%; height: auto; }
        pre, code { font-size: .85em; white-space: pre-wrap; }
        blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid currentColor; opacity: .85; }
        table { border-collapse: collapse; } td, th { border: 1px solid rgba(127,127,127,.4); padding: 4px 8px; }
        </style></head><body>
        <h1>\(escape(article.title ?? ""))</h1>
        \(meta.isEmpty ? "" : "<div class=\"meta\">\(escape(meta))</div>")
        \(article.content)
        </body></html>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// The reader page over the tab: a bar with close, font size and theme, and the article.
struct ReaderPage: View {
    let article: ReaderArticle
    let onClose: () -> Void
    /// A link in the article opens in the tab, leaving reader mode.
    let onOpen: (URL) -> Void
    @AppStorage(SettingsKeys.readerFontSize) private var fontSize = 19
    @AppStorage(SettingsKeys.readerTheme) private var theme = ReaderTheme.light

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button(action: onClose) { Label("Выйти из режима чтения", systemImage: "xmark") }
                    .labelStyle(.iconOnly)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button { fontSize = max(13, fontSize - 2) } label: { Text("A").font(.system(size: 13)) }
                    .accessibilityLabel("Мельче")
                Button { fontSize = min(34, fontSize + 2) } label: { Text("A").font(.system(size: 19)) }
                    .accessibilityLabel("Крупнее")
                Picker("Тема", selection: $theme) {
                    ForEach(ReaderTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ReaderWebView(html: ReaderMode.html(article, fontSize: fontSize, theme: theme), baseURL: article.url, onOpen: onOpen)
        }
        .background(Color(hex: theme.colors.background))
        .environment(\.colorScheme, theme == .dark ? .dark : .light)
    }
}

@MainActor
private struct ReaderWebView {
    let html: String
    let baseURL: URL?
    let onOpen: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        return webView
    }

    private func update(_ webView: WKWebView, _ coordinator: Coordinator) {
        coordinator.onOpen = onOpen
        guard coordinator.html != html else { return }
        coordinator.html = html
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var html = ""
        var onOpen: ((URL) -> Void)?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
            // Same-page anchors stay in the article.
            if url.fragment != nil, url.absoluteString.hasPrefix((webView.url?.absoluteString ?? "") + "#") { return .allow }
            onOpen?(url)
            return .cancel
        }
    }
}

#if os(macOS)
extension ReaderWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ webView: WKWebView, context: Context) { update(webView, context.coordinator) }
}
#else
extension ReaderWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ webView: WKWebView, context: Context) { update(webView, context.coordinator) }
}
#endif
