# UniBrowser

A macOS browser built around a vertical tab panel: spaces, folder groups,
⌘K search across tabs and commands, and Ctrl+Tab by recency.

Native Swift/SwiftUI app on WKWebView (the system WebKit, same engine as Safari).

## Build

Requires macOS 15+ and Xcode 16+.

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

## Next

Passwords app bridge, real favicons, tab map, Peek, Split View, evening cleanup,
archive, downloads, passkeys.
