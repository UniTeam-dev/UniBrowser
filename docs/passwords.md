# Logins and the macOS Passwords app

Requirement: UniBrowser fills and saves logins. Ideally from the Passwords app
(iCloud Keychain), like Safari.

## What macOS allows a third-party browser (checked October 2026)

| Route | Works for UniBrowser? |
| --- | --- |
| WKWebView's built-in AutoFill | No. On macOS, WKWebView in a third-party app gets no password AutoFill; that UI is Safari-only. |
| Keychain Services (`SecItem*`) reading Safari/Passwords website passwords | No. Website passwords in iCloud Keychain are readable only by Apple's own apps. |
| `ASAuthorizationPasswordProvider` (AuthenticationServices) | Only for the app's own associated domains, not for arbitrary sites. |
| `com.apple.developer.web-browser` entitlement | iOS/iPadOS/Mac Catalyst only; no effect on a native macOS app. |
| Passkeys (`ASAuthorizationWebBrowserPublicKeyCredentialManager`) | Yes. Browsers may use passkeys stored in Passwords for any site. Planned. |
| `PasswordManagerBrowserExtensionHelper` (what the iCloud Passwords extension in Chrome/Edge/Firefox uses) | Not in an App Store build: it means launching an Apple system binary over an undocumented protocol, which App Sandbox and guideline 2.5.1 rule out, and macOS only lets allowlisted Developer ID browsers start it. |

A bridge to that helper was written and removed for the App Store build; it
is in git history (commit 99c674d, `Passwords/ApplePasswordsProvider.swift`)
if a separate Developer ID build is ever made.

## What UniBrowser does

Logins are saved in UniBrowser's own items in the login keychain
(`KeychainCredentialProvider`). They fill and save, show in the passwords
manager (⌘⇧P), and sync to the iPhone, but are not visible in the Passwords
app. Logins come over from Passwords via CSV (Passwords ▸ File ▸ Export All
Passwords, then "Импортировать из CSV…").

## Code

- `Passwords/KeychainCredentialProvider.swift`: the store.
- `Web/LoginFormScript.swift`: finds login forms and captures submits, in an
  isolated JS world so pages can't read or spoof it.
- `Views/PasswordBar.swift`: "Войти как …" and "Сохранить пароль?" bars.
