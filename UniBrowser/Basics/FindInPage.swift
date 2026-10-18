import SwiftUI
import WebKit

/// ⌘F on one tab: the text, whether the bar shows, and «n из m».
///
/// `WKWebView.find` only says whether there was a match, so the total comes from a count of
/// the query in the page's `innerText` (isolated world, top frame), and `index` is kept here:
/// a new query starts from the top (selection cleared) at 1, each ⌘G / ⇧⌘G steps with wraparound.
/// ponytail: matches inside iframes are found but not counted, and a click in the page between
/// steps makes `index` approximate; WebKit's private `_countStringMatches` would fix both.
@MainActor
@Observable
final class FindInPage {
    var isVisible = false
    var text = ""
    private(set) var count = 0
    private(set) var index = 0
    private(set) var found = false
    /// Bumped to put the cursor in the field again (⌘F with the bar already open).
    private(set) var focusRequest = 0
    @ObservationIgnored private var generation = 0

    var status: String {
        if text.isEmpty { return "" }
        if count > 0 { return "\(index) из \(count)" }
        return found ? "Найдено" : "Не найдено"
    }

    func show() {
        isVisible = true
        focusRequest += 1
    }

    func hide(_ webView: WKWebView?) {
        isVisible = false
        if let webView { webView.window?.makeFirstResponder(webView) }
    }

    /// The text changed: count, then select the first match from the top.
    func search(_ webView: WKWebView?) async {
        generation += 1
        let mine = generation
        guard let webView, !text.isEmpty else {
            count = 0; index = 0; found = false
            return
        }
        let query = text
        let total = (try? await webView.callAsyncJavaScript(Self.countScript, arguments: ["query": query], in: nil, contentWorld: .defaultClient)) as? Int ?? 0
        _ = try? await webView.callAsyncJavaScript("getSelection().removeAllRanges()", in: nil, contentWorld: .defaultClient)
        let result = try? await webView.find(query, configuration: Self.configuration(backwards: false))
        guard mine == generation else { return } // a newer keystroke took over
        found = result?.matchFound == true
        count = found ? total : 0
        index = found ? 1 : 0
    }

    /// ⌘G / ⇧⌘G, Return / ⇧Return, ↓ / ↑ in the field.
    func step(_ webView: WKWebView?, backwards: Bool) async {
        guard let webView, !text.isEmpty else { return show() }
        let result = try? await webView.find(text, configuration: Self.configuration(backwards: backwards))
        found = result?.matchFound == true
        guard found, count > 0 else { return }
        index = backwards ? (index + count - 2) % count + 1 : index % count + 1
    }

    private static func configuration(backwards: Bool) -> WKFindConfiguration {
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        return configuration
    }

    private static let countScript = """
    const q = query.toLocaleLowerCase();
    const t = (document.body ? document.body.innerText : '').toLocaleLowerCase();
    let n = 0, i = 0;
    while (n < 1000 && (i = t.indexOf(q, i)) !== -1) { n++; i += q.length; }
    return n;
    """
}

/// The ⌘F bar at the top of the page card.
struct FindBar: View {
    let tab: BrowserTab
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var find = tab.find
        if find.isVisible {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondaryText)
                TextField("Найти на странице", text: $find.text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit { step(backwards: false) }
                    .onKeyPress(keys: [.return, .upArrow, .downArrow]) { press in
                        guard press.key != .return || press.modifiers.contains(.shift) else { return .ignored }
                        step(backwards: press.key != .downArrow)
                        return .handled
                    }
                    .onExitCommand { find.hide(tab.webView) }
                    .frame(maxWidth: 320)
                Text(find.status)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(find.found || find.text.isEmpty ? Palette.secondaryText : .red)
                Button { step(backwards: true) } label: { Image(systemName: "chevron.up") }
                    .help("Предыдущее (⇧⌘G)")
                    .accessibilityLabel("Предыдущее совпадение")
                Button { step(backwards: false) } label: { Image(systemName: "chevron.down") }
                    .help("Следующее (⌘G)")
                    .accessibilityLabel("Следующее совпадение")
                Spacer()
                Button("Готово") { find.hide(tab.webView) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Palette.surface)
            .overlay(alignment: .bottom) { Divider() }
            .onAppear { isFocused = true }
            .onChange(of: find.focusRequest) { isFocused = true }
            .task(id: find.text) { await find.search(tab.webView) }
        }
    }

    private func step(backwards: Bool) {
        Task { await tab.find.step(tab.webView, backwards: backwards) }
    }
}

// MARK: - Page zoom

extension BrowserTab {
    /// Device mode owns the web view's zoom while it is on; DeviceFrame applies `pageZoom` when it goes off.
    func applyZoom(_ level: Double) {
        pageZoom = level
        if !deviceMode.isOn { webView?.pageZoom = level }
    }
}

extension BrowserStore {
    /// ⌘+ / ⌘− (`up`), ⌘0 (nil): the selected tab's site, every open tab of it, and remembered.
    func zoomSelectedTab(up: Bool?) {
        guard let tab = selectedTab, let host = tab.url?.host() else { return }
        let level = up.map { PageZoom.step(from: tab.pageZoom, up: $0) } ?? 1
        PageZoom.setLevel(level, for: host)
        for other in tabs.values where other.url?.host() == host { other.applyZoom(level) }
    }

    /// ⇧⌘T: the newest of the recently closed and archived tabs.
    var lastClosed: ArchivedTab? {
        recentlyClosedMenu.first
    }

    /// «История → Недавно закрытые»: closed (⌘W) and archived tabs, newest first, ten.
    var recentlyClosedMenu: [ArchivedTab] {
        Array((recentlyClosed + archive).sorted { $0.archivedAt > $1.archivedAt }.prefix(10))
    }
}
