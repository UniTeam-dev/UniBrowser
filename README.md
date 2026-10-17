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
- Web extensions (⌘⇧E): install an unpacked folder (or drop it on the app icon)
  or a Chrome Web Store link/ID; content scripts, toolbar buttons with popups and
  badges, a permission prompt at install, enable/remove.
  `swiftc -parse-as-library UniBrowser/Extensions/CRX.swift scripts/crx_check.swift -o /tmp/crx_check && /tmp/crx_check`
  checks the CRX unpacking.

## Next

Real favicons, downloads, passkeys.
