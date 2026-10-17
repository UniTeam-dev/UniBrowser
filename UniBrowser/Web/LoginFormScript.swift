import Foundation
import WebKit

/// JavaScript injected into every frame of every page. It tells the app when a
/// login form appears and when one is submitted, and exposes a fill function
/// the app calls with a credential the user picked.
enum LoginFormScript {
    static let handlerName = "unibrowserLogin"
    /// An isolated JS world: the page can see the DOM changes but cannot call
    /// our fill function, read our messages or post fake ones.
    @MainActor static let world = WKContentWorld.world(name: "UniBrowserPasswords")

    static let source = #"""
    (() => {
      if (window.__unibrowserLogin) return;
      window.__unibrowserLogin = true;
      const post = (msg) => window.webkit.messageHandlers.unibrowserLogin.postMessage(msg);

      const visible = (el) => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
      // Login forms built as web components keep their fields in (open) shadow roots.
      const shadowRoots = (root = document) => {
        const found = [];
        for (const el of root.querySelectorAll('*')) {
          if (el.shadowRoot) found.push(el.shadowRoot, ...shadowRoots(el.shadowRoot));
        }
        return found;
      };
      const passwordField = () => {
        for (const root of [document, ...shadowRoots()]) {
          const pw = [...root.querySelectorAll('input[type="password"]')].find(visible);
          if (pw) return pw;
        }
        return null;
      };

      const usernameField = (pw) => {
        const scope = pw.form || pw.getRootNode();
        const candidates = [...scope.querySelectorAll(
          'input[autocomplete="username"], input[type="email"], input[type="text"], input[type="tel"], input:not([type])'
        )].filter(visible);
        // The field just before the password is almost always the login.
        const before = candidates.filter(
          (el) => el.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING
        );
        return before.pop() || candidates[0] || null;
      };

      let announced = false;
      const scan = () => {
        const pw = passwordField();
        if (pw && !announced) {
          announced = true;
          post({ action: 'formFound' });
        }
        // submit doesn't cross a shadow boundary, so listen inside the field's root too.
        const root = pw && pw.getRootNode();
        if (root instanceof ShadowRoot && !root.__unibrowserLogin) {
          root.__unibrowserLogin = true;
          root.addEventListener('submit', onSubmit, true);
        }
      };
      let scanTimer = null;
      const scanSoon = () => { if (!scanTimer) scanTimer = setTimeout(() => { scanTimer = null; scan(); }, 300); };

      const capture = (pw) => {
        if (!pw || !pw.value) return;
        const user = usernameField(pw);
        post({ action: 'submitted', username: user ? user.value : '', password: pw.value });
      };

      const onSubmit = (e) => {
        capture(e.target.querySelector && e.target.querySelector('input[type="password"]'));
      };
      document.addEventListener('submit', onSubmit, true);

      // Many sites log in with a button (or a styled div) and fetch(), never firing submit.
      // composedPath()[0] is the real target even inside a shadow root.
      document.addEventListener('click', (e) => {
        const target = e.composedPath()[0];
        if (!(target instanceof Element) || target.matches('input:not([type="submit"]):not([type="button"]):not([type="image"])')) return;
        const clickable = target.closest('button, input, a, [role="button"]') || getComputedStyle(target).cursor === 'pointer';
        if (clickable) capture(passwordField());
      }, true);
      document.addEventListener('keydown', (e) => {
        const target = e.composedPath()[0];
        if (e.key === 'Enter' && target instanceof HTMLInputElement) capture(passwordField());
      }, true);
      // A script that signs in and then moves to another page.
      window.addEventListener('pagehide', () => capture(passwordField()));

      const setValue = (el, value) => {
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        setter.call(el, value);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      };

      window.__unibrowserFill = (username, password) => {
        const pw = passwordField();
        if (!pw) return false;
        const user = usernameField(pw);
        if (user && username) setValue(user, username);
        setValue(pw, password);
        return true;
      };

      scan();
      new MutationObserver(scanSoon).observe(document.documentElement, { childList: true, subtree: true });
    })();
    """#
}
