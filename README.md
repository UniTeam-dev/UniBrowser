# UniBrowser

A macOS browser built around a vertical tab panel: spaces, folder groups,
⌘K search across tabs and commands, and Ctrl+Tab by recency.

Native Swift/SwiftUI app on WKWebView (the system WebKit, same engine as Safari).

## Build

Requires macOS 15.4+ (WebKit's web extension API) and Xcode 16.3+.

```sh
brew install xcodegen
xcodegen generate
open UniBrowser.xcodeproj
```

Then pick your team under Signing & Capabilities and run (⌘R).

The Mac app is distributed from the website only (Developer ID, no App Sandbox,
private WebKit API allowed). The iPhone app goes to the App Store, see
[docs/app-store.md](docs/app-store.md).

## What works in this first version

- Vertical sidebar matching the approved design: pinned tiles, space header,
  folder groups (collapse, rename, sleep, drag tabs in), "Сегодня" list.
- Spaces with their own tabs; switch with the dots at the bottom or Ctrl+1…9.
- ⌘K / ⌘L palette: open tabs, groups, commands, or type an address/search.
- ⌘T new tab, ⌘W close, ⌘[ / ⌘] back/forward, ⌘R reload, ⌘⇧D pin,
  ⌘⇧G new group, ⌃⌘S hide the sidebar.
- Ctrl+Tab switcher ordered by most recent use; release Ctrl to switch.
- Sleeping tabs drop their web view and wake on click.
- Session restored on relaunch.
- Login detection, fill bar and save prompt. Storage: see
  [docs/passwords.md](docs/passwords.md) for the Passwords app status.
- Archive: tabs removed by cleanup or "В архив" stay findable in ⌘K ("Из архива")
  and in the sidebar's archive list.
- Peek (⌥+click a link, ⌥↵ in ⌘K): the page opens over the window without a tab.
- Split View: two tabs side by side (tab menu, ⌘↵ in ⌘K, or from Peek).
- Tab map (⌘⇧M): all tabs of a space by group, drag between groups, close
  duplicates, group loose tabs by site.
- Evening cleanup: after 18:00, loose tabs unused for 12+ hours one by one,
  ← archive / → keep.
- Passwords manager (⌘⇧P): UniBrowser's own logins in the login keychain —
  view, reveal, copy, edit, delete, add by hand. Autofill and the save prompt
  already use this store. Bring your logins over with "Импортировать из CSV…"
  (Passwords app ▸ File ▸ Export All Passwords). Checks: `scripts/keychain_check.swift`
  (store round-trip), `scripts/csv_check.swift` (CSV parsing). `scripts/login_capture_check.swift` signs in on
  test pages (plain form, iframe, shadow DOM, div button, script redirect) in a real WKWebView
  and checks the login is captured: `swiftc -parse-as-library UniBrowser/Web/LoginFormScript.swift scripts/login_capture_check.swift -o /tmp/login_capture_check && /tmp/login_capture_check`.
- Web extensions (⌘⇧E): install an unpacked folder (or drop it on the app icon)
  or a Chrome Web Store link/ID; content scripts, toolbar buttons with popups and
  badges, a permission prompt at install, enable/remove.
  `swiftc -parse-as-library UniBrowser/Extensions/CRX.swift scripts/crx_check.swift -o /tmp/crx_check && /tmp/crx_check`
  checks the CRX unpacking.

- iPhone link (UniBrowser/ViaMac + Shared/ViaMac): menu Вкладки → iPhone… (⇧⌘I) pairs an iPhone by QR. Over one iroh tunnel (direct or via relay, works from any network) the phone gets a SOCKS proxy through this Mac and a live two-way mirror of spaces, groups, tabs and UniBrowser passwords; after time apart the Mac merges both sides (later change wins, new tabs from both kept). Wire format: `SessionSnapshot`. `swiftc -parse-as-library UniBrowser/Models/Space.swift UniBrowser/Models/SessionSnapshot.swift Shared/ViaMac/SessionMerge.swift scripts/merge_check.swift -o /tmp/merge_check && /tmp/merge_check` checks the merge. From other networks: a fixed UDP port to forward, an external address (IP or DDNS name) and an optional own relay server, set in Settings → iPhone (`docs/via-mac-direct.md`, `docs/via-mac-relay.md`); `swiftc -parse-as-library Shared/ViaMac/ViaMacAddress.swift scripts/via_mac_address_check.swift -o /tmp/via_mac_address_check && /tmp/via_mac_address_check` checks address parsing.

## Next

Real favicons, downloads, passkeys.
