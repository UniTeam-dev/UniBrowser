# Compact Sidebar and Address Strip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapsing the sidebar shrinks it to a 56 pt icon column, and a full-width address strip in the title-bar row shows the current URL in both modes.

**Architecture:** `MainWindow` becomes `VStack { AddressStrip; HStack { SidebarView (290/56); ContentArea } }`. `AddressStrip` takes over `SidebarView.toolbar` + `addressButton` + `ExtensionBar`. `TabRow` gets an `isCompact` flag (icon-only label, same selection/drag/context menu) so the compact column reuses it.

**Tech Stack:** SwiftUI, macOS 15.4+, Swift 6.

**Spec:** `docs/superpowers/specs/2026-10-18-compact-sidebar-design.md`

## Global Constraints

- Mac only; `mobile/` untouched. UI strings Russian.
- `isSidebarCompact` persisted in `UserDefaults` (key `sidebarCompact`).
- Wide 290 pt, compact 56 pt with 32 pt icons; strip height ~38 pt; width animates with `.snappy`.
- Menu title «Компактная панель вкладок» / «Полная панель вкладок», ⌃⌘S.
- Build: `NO_OPEN=1 scripts/build.sh` with zero errors. No unit-test target exists for views; verification is build + running the app.

## Review Focus

- Long URL: middle-truncated in one line, full URL in tooltip; strip never pushes the extension icons off-screen.
- http page: warning icon instead of lock; no-URL tab shows the «Поиск или адрес» placeholder.
- Split View: strip follows the focused pane (`store.selectedTab`).
- Many tabs in compact mode: tab icons scroll, space rail and archive stay visible.
- Rename from a compact icon's context menu still works (popover with the name field).

---

### Task 1: State and menu

**Files:** Modify `UniBrowser/App/AppModel.swift` (`isSidebarVisible`), `UniBrowser/App/BrowserCommands.swift` (`CommandGroup(after: .sidebar)` only).

- [ ] Replace `isSidebarVisible` with `var isSidebarCompact = UserDefaults.standard.bool(forKey: "sidebarCompact")` + `didSet` saving it.
- [ ] Menu item: title by state, toggles `isSidebarCompact` inside `withAnimation(.snappy)`, ⌃⌘S kept.

### Task 2: Address strip and layout

**Files:** Modify `UniBrowser/Views/MainWindow.swift` (body layout, `showSidebarBar` → `AddressStrip`), `UniBrowser/Views/ExtensionsView.swift` (`ExtensionBar`: drop trailing `Spacer` and padding).

- [ ] `struct AddressStrip: View` in MainWindow.swift: 64 pt traffic-light gap, toggle, ← → ↻/✕ (stop while `isLoading`), address button (moved from `SidebarView.addressButton`: lock/`exclamationmark.triangle` by scheme, full `absoluteString` with host normal and the rest dimmed, `.truncationMode(.middle)`, tooltip, context menu copy, opens `.address` palette), copy button, `ExtensionBar`. Height 38, `WindowDragGesture()` on the background.
- [ ] Layout: strip above `HStack { SidebarView().frame(width: compact ? 56 : 290); ContentArea().padding(bottom 8, trailing 8) }` — leading inset 0 in both modes.

### Task 3: Sidebar modes

**Files:** Modify `UniBrowser/Views/SidebarView.swift` (remove `toolbar`, `addressButton`, `ExtensionBar`; add compact body), `UniBrowser/Views/TabRows.swift` (`TabRow.isCompact`).

- [ ] `TabRow(tab:, isCompact: Bool = false)`: compact label is `Favicon` 16 pt in a 32×32 frame, same background/selection, `.help(title)`, no hover close; rename via popover when compact.
- [ ] Compact body: `ScrollView { pinned; Divider; each group's `orderedTabIDs` separated by thin dividers; loose tabs; «+» }`, then `SpaceRail`, then archive button. Rename from the rail switches to wide and starts renaming.

### Task 4: Verify and commit

- [ ] `NO_OPEN=1 scripts/build.sh` → `BUILD SUCCEEDED`.
- [ ] Run the app; check both modes, toggle by button/menu/⌃⌘S, light/dark, long URL, http, Split View, many tabs, minimum width.
- [ ] Commit.
