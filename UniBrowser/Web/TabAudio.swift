import WebKit

/// A tab's sound: whether it plays and muting it. WebKit's own `_isPlayingAudio` and
/// `_setPageMuted:` (what Safari uses) are private, which is fine for the website-only Mac app.
@MainActor
enum TabAudio {
    /// Calls `onChange` with `_isPlayingAudio` now and whenever it changes; keep the result alive.
    static func observe(_ webView: WKWebView, onChange: @escaping @MainActor (Bool) -> Void) -> NSObject? {
        guard webView.responds(to: NSSelectorFromString("_isPlayingAudio")) else { return nil }
        return Observer(webView, onChange: onChange)
    }

    /// Mutes the page (all its frames and media); public suspend-playback when the private call is missing.
    static func setMuted(_ muted: Bool, _ webView: WKWebView) {
        let selector = NSSelectorFromString("_setPageMuted:")
        if webView.responds(to: selector) {
            typealias SetMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
            let call = unsafeBitCast(webView.method(for: selector), to: SetMuted.self)
            call(webView, selector, muted ? 1 : 0) // _WKMediaAudioMuted
        } else {
            webView.setAllMediaPlaybackSuspended(muted)
        }
    }

    /// Created, called and released on the main thread (WebKit sends KVO there).
    private final class Observer: NSObject, @unchecked Sendable {
        private weak var webView: WKWebView?
        private let onChange: @MainActor (Bool) -> Void
        private static let key = "_isPlayingAudio"

        init(_ webView: WKWebView, onChange: @escaping @MainActor (Bool) -> Void) {
            self.webView = webView
            self.onChange = onChange
            super.init()
            webView.addObserver(self, forKeyPath: Self.key, options: [.initial, .new], context: nil)
        }

        override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
            let isPlaying = change?[.newKey] as? Bool ?? false
            MainActor.assumeIsolated { onChange(isPlaying) }
        }

        deinit {
            MainActor.assumeIsolated { webView?.removeObserver(self, forKeyPath: Self.key) }
        }
    }
}
