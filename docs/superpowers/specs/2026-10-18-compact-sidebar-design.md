# Compact sidebar and the address strip (macOS)

Requirement (ilja, 2026-10-18): collapsing the sidebar must not hide it; it
shrinks to icons. The full URL of the current page stays visible in both modes.
Today collapsing removes the sidebar, the "show sidebar" button sits awkwardly
next to the traffic lights, and the address (shown only in the sidebar) is gone.

## Address strip

A row across the whole window above the page card, in the title-bar area that
is empty today (height of the traffic lights row, ~38 pt):

`● ● ●  [sidebar toggle]  ← → ↻  🔒 full URL ……… [copy] [extension icons]`

- The URL is the whole `absoluteString`, host in normal colour and the rest
  dimmed, truncated in the middle; full URL in the tooltip. Lock icon for
  https, warning icon for http.
- Click on the URL opens the address palette (`model.openPalette(.address)`,
  same as ⌘K/⌘L today). Context menu and the copy button copy the URL.
- ↻ reloads (stop while loading). ← → as today.
- Extension icons (`ExtensionBar`) move here, right-aligned.
- The strip is the same in both sidebar modes, so nothing jumps when toggling.
  In Split View it shows the focused pane's tab.
- The strip is a window drag area outside its controls.

The sidebar loses its toolbar row, `addressButton` and `ExtensionBar`.

## Sidebar modes

`AppModel.isSidebarVisible` becomes `isSidebarCompact` (persisted in
`UserDefaults`). The toggle button in the strip, the menu item and ⌃⌘S switch
between:

- **Wide** (290 pt): as today, minus the removed rows.
- **Compact** (56 pt), one column of 32 pt icons, each with the tab title as
  tooltip and the same context menu as the wide row:
  - pinned tabs (favicons);
  - divider;
  - the active space's tabs: each folder's tabs in order, folders separated by
    a thin divider, then today's tabs; selected tab highlighted; close on hover
    is not shown (context menu has it);
  - «+» new tab;
  - at the bottom: space icons (the `SpaceRail`, switching and context menu as
    today), then archive.
  - Scrolls when it doesn't fit.

Switching animates the width with `.snappy`. The page card's leading inset is
the same in both modes.

## Touched

`AppModel` (state), `MainWindow` (strip + layout, removes `showSidebarBar`),
`SidebarView` (compact layout, removed rows), `BrowserCommands` (menu title
«Компактная панель вкладок» / «Полная панель вкладок»), `TabRows`/favicons
reused for icons. Mac only; the iPhone app is unchanged.

## Verification

Build, run, check: toggle by button/menu/⌃⌘S, both modes with pinned tabs,
folders, many tabs (scroll), Split View, dark theme, long URLs, http page,
window narrowed to the minimum width.
