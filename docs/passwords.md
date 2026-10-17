# Logins and the macOS Passwords app

Requirement: UniBrowser fills logins from, and saves new ones to, the Passwords
app (iCloud Keychain), like Safari does.

## What macOS allows a third-party browser (checked October 2026)

| Route | Works for UniBrowser? |
| --- | --- |
| WKWebView's built-in AutoFill | No. On macOS, WKWebView in a third-party app gets no password AutoFill; that UI is Safari-only. |
| Keychain Services (`SecItem*`) reading Safari/Passwords website passwords | No. Website passwords in iCloud Keychain are readable only by Apple's own apps. |
| `ASAuthorizationPasswordProvider` (AuthenticationServices) | Only for the app's own associated domains, not for arbitrary sites. |
| `com.apple.developer.web-browser` entitlement | iOS/iPadOS/Mac Catalyst only; no effect on a native macOS app. |
| Passkeys (`ASAuthorizationWebBrowserPublicKeyCredentialManager`) | Yes. Browsers may use passkeys stored in Passwords for any site. Planned. |
| `PasswordManagerBrowserExtensionHelper` (what the iCloud Passwords extension in Chrome/Edge/Firefox uses) | Yes, read **and** save, but only once Apple adds UniBrowser to its browser allowlist. |

The Mac app has no App Sandbox (it is distributed from the website only), so
it can launch the Apple system helper the bridge below talks to.

## The plan

1. **Native bridge to the Passwords helper (written).** The helper ships with macOS at
   `/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app`.
   A browser launches it as a child process and talks native-messaging framing
   (32-bit little-endian length + JSON) over stdin/stdout. The session starts
   with an SRP pairing: Passwords shows a 6-digit code, the user types it into
   the browser once, and after that the browser can list, fill and save logins.
   The open-source projects `apw` / `apwlib` document this exchange.
2. **Allowlist.** Since macOS 15.4 the helper checks the signing identifier and
   Team ID of the browser that launched it against a list Apple builds from
   [apple/password-manager-resources](https://github.com/apple/password-manager-resources)
   (`quirks/web-browser-extension-distribution-information.json`). Browsers get
   in by opening a PR there with their bundle ID and Team ID; it then ships with
   a later macOS update. That needs:
   - a paid Apple Developer account (Team ID, Developer ID signing);
   - a final bundle ID (`app.unibrowser.UniBrowser`);
   - a public download page for the browser, which the PR links to.
3. **Until then:** logins are saved in UniBrowser's own items in the login
   keychain (`KeychainCredentialProvider`). They work for filling and saving but
   are not visible in the Passwords app. When the bridge connects,
   `PasswordsService` switches to it.

## Risks

- The helper's protocol is undocumented; Apple can change it in any macOS update
  (it has changed before, most recently with the 15.4 caller check).
- Apple decides whether and when the allowlist PR lands.

## Code

- `Passwords/PasswordsSRP.swift`: SRP-6a pairing (RFC 5054 3072-bit group, SHA-256)
  and AES-128-GCM message encryption, written from the protocol as documented by
  the open-source apw/apwlib projects (no code copied).
- `Passwords/ApplePasswordsProvider.swift`: launches the helper, pairs with the
  PIN, and sends get (`cmd 5`) and save (`cmd 6`) requests. Pairing lasts for the
  app session; the helper never re-authenticates a known client.
- `Views/PairingSheet.swift`: the 6-digit code sheet (menu Вкладки → Подключить «Пароли»…).
- `Passwords/KeychainCredentialProvider.swift`: the stopgap store.
- `Web/LoginFormScript.swift`: finds login forms and captures submits, in an
  isolated JS world so pages can't read or spoof it.
- `Views/PasswordBar.swift`: "Войти как …", "Сохранить пароль?" and "Подключить «Пароли»" bars.

Until UniBrowser is on Apple's list, macOS kills the helper at launch and the
provider reports `notAllowlisted`; logins then go to the keychain stopgap.
Steps to get listed: docs/apple-developer.md.
