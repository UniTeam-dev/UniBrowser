# Separate logins per space (Mac + iPhone)

Requirement (ilja, 2026-10-19): one site, different accounts in different spaces —
e.g. work Google in «Работа», personal Google in «Личное». Sessions must not leak
between spaces unless the user wants them shared.

## Model

- `Space.separateLogins: Bool` (Codable, decoded as optional → missing means the
  migration default below), shown in each space's menu as a toggle «Отдельные
  входы» with a short footnote «Свои cookie и данные сайтов; пароли и история общие».
- Shared spaces (toggle off) use the common store: Mac `WKWebsiteDataStore.default()`,
  iPhone the mode's existing store (normal: `.default()`, via-Mac: its fixed id).
- Separate spaces use `WKWebsiteDataStore(forIdentifier:)` with a UUID derived
  from the space id (Mac) / space id + mode (iPhone; e.g. SHA-256 of
  "\(spaceID)|\(mode)" folded to 16 bytes) so the two iPhone modes never share.
- Migration (first launch with this field missing in the saved session): the
  first space keeps `false` (it holds the user's current logins); every other
  existing space gets `true`. New spaces start with `true`.
- Turning the toggle off keeps the separate store's data (turning it back on
  restores those logins). Deleting a space removes its separate store
  (`WKWebsiteDataStore.remove(forIdentifier:)`).
- Private window / private mode: unchanged (non-persistent store).

## Behaviour

- A tab's web view is created with its space's store. Moving a tab to another
  space, or flipping the toggle, sleeps and wakes the affected tabs so they reload
  with the right store (the page reloads; say so in the toggle's footnote).
- Peek and Split View use the store of the space they open in.
- Shared across spaces: UniBrowser passwords, history, bookmarks, site
  permissions, ad blocking, extensions (verify extensions still inject into tabs
  with a non-default store; if a WebKit limit prevents it, report it).
- «Очистить данные сайта» (site popover) and devtools Приложение/Cookies act on
  the current tab's store. Settings «Удалить cookies и кэш» clears the common
  store and every separate store.
- Sync: `separateLogins` travels inside `Space` in `SessionSnapshot` (via-Mac
  mirror), so the iPhone applies the same split to the mirrored spaces. Cookies
  themselves are not synced (they never were).

## Verification

Self-check for the id derivation and migration rule. End to end on an isolated
Mac copy and in the simulator: log into the same test site (a local page that sets
a cookie and shows it) in two spaces with different values, check each space keeps
its own, flip the toggle and check the shared value appears, delete a space and
check its store is gone.
