import Foundation
import WebKit

/// JavaScript injected into every top-level page. It tells the app when a
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
      const passwordField = () =>
        [...document.querySelectorAll('input[type="password"]')].find(visible);

      const usernameField = (pw) => {
        const scope = pw.form || document;
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
      };

      const capture = (pw) => {
        if (!pw || !pw.value) return;
        const user = usernameField(pw);
        post({ action: 'submitted', username: user ? user.value : '', password: pw.value });
      };

      document.addEventListener('submit', (e) => {
        capture(e.target.querySelector && e.target.querySelector('input[type="password"]'));
      }, true);

      // Many sites log in with a button and fetch(), never firing submit.
      document.addEventListener('click', (e) => {
        const button = e.target.closest && e.target.closest('button, input[type="submit"], [role="button"]');
        if (button) capture(passwordField());
      }, true);
      document.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && e.target && e.target.type === 'password') capture(e.target);
      }, true);

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
      new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true });
    })();
    """#
}
