# SSH tabs: terminal, SFTP files, autocomplete, sync with the iPhone

Idea (2026-10-20): UniBrowser is a universal browser, so a tab can also be a
server. SSH connections live in the vault next to the passwords; opening one
gives a terminal after login and an SFTP file browser, on the Mac and on the
iPhone, synced through the existing «Через Mac» link.

Decisions agreed with ilja: the phone connects directly, and hosts marked «через
Mac» go through the Mac's tunnel; password and key login, keys imported or
generated, private keys synced to the phone; Fig/Warp-style suggestion popup;
on the Mac the terminal with a slide-out «Файлы» panel, on the iPhone a
«Терминал | Файлы» switch.

## Dependencies

- **Citadel** 0.12.1 (`orlandos-nl/Citadel`, on SwiftNIO SSH): client, PTY with
  `changeSize`, SFTP, OpenSSH ed25519/RSA private keys incl. encrypted ones,
  ed25519 export. `SSHClient.connect(on: Channel, …)` lets us connect over a
  channel we bootstrapped ourselves (SOCKS).
- **SwiftTerm** 1.20 (`migueldeicaza/SwiftTerm`): VT emulator with
  `TerminalView` for AppKit and UIKit.
- **NIOSOCKS** from `apple/swift-nio-extras` (pulled by Citadel's NIO stack):
  `SOCKSClientHandler` for the via-Mac path.

All pure Swift, public API only, so the iPhone app stays App Store clean (SSH
clients like Termius are in the store; no downloaded code). Pin exact versions
in both `project.yml` files. Check the Release binary's privacy-API usage
(`nm -u`) after adding them and update `PrivacyInfo.xcprivacy` if needed.

## 1. Host store (`Shared/SSH/`)

```swift
struct SSHHost: Codable, Sendable, Identifiable, Hashable {
    var id: UUID
    var name: String          // shown in the tab and ⌘K; empty → user@address
    var address: String       // DNS name, IPv4 or IPv6
    var port: Int             // default 22
    var username: String
    var auth: Auth            // .password | .key
    var viaMac: Bool          // iPhone only: go through the Mac's tunnel
    var modifiedAt: Date
    var deleted: Bool         // tombstone, 30 days, like bookmarks
}
```

- Metadata in `ssh-hosts.json` (app support dir on Mac, documents/app support
  on iPhone, same place as the other stores).
- Secrets in the keychain, one generic-password item per host id, service
  `app.unibrowser.ssh` (separate from the logins service): `SSHSecret { password?,
  privateKey? (OpenSSH PEM text), passphrase? }`. Deleting a host deletes its item.
- Merge: per id the later `modifiedAt` wins, equal times compare content (copy
  `BookmarkMerge.wins` rules). Write it as a small pure `SSHHostMerge` so a check
  script can compile it alone. Secrets travel with the host and follow the same
  winner.
- **Known hosts** `known-hosts.json`: `[KnownHost { hostPort: "addr:port",
  keyType, fingerprintSHA256, publicKey, addedAt }]`. First connect: sheet with the
  SHA-256 fingerprint, «Доверять» / «Отмена». Changed key: connect stops, a red
  warning names the old and new fingerprints; «Заменить ключ» only behind a second
  confirmation. Merge: union by `hostPort`, later `addedAt` wins.
- **Keys**: import from a file / paste (OpenSSH format; ed25519 and RSA; asks for
  the passphrase if encrypted and checks it on import); «Сгенерировать ed25519»
  (CryptoKit `Curve25519.Signing.PrivateKey`, saved as OpenSSH PEM); «Скопировать
  публичный ключ» gives the `ssh-ed25519 AAAA… unibrowser@<device>` line.
  PuTTY `.ppk` and old PEM `BEGIN RSA PRIVATE KEY` are rejected with a message
  naming the `ssh-keygen -p -f key` conversion; no ECDSA in this version.

**Mac UI**: the passwords window (⌘⇧P) gets a «SSH» section: list, add/edit form
(name, address, port, user, password or key, «Через Mac (для iPhone)»), import /
generate / copy public key, delete with confirmation, «Открыть во вкладке».
**iPhone UI**: «Настройки» → «SSH-серверы» with the same form and actions.

## 2. SSH tab

- A tab is a normal tab whose URL is `unibrowser-ssh://<host-uuid>`. So
  `SessionSnapshot` keeps its format and SSH tabs get spaces, groups, pinning,
  archive, ⌘K and the session mirror for free. Title = host name.
  Web code paths must not try to load this scheme: `BrowserTab.wake` and the
  iPhone tab view branch on it. A host deleted on either side leaves its tabs
  showing «Сервер удалён из хранилища».
- Open: ⌘K lists hosts as «SSH: <name>» (↵ new tab, also in the «+» menu as
  «Новая SSH-вкладка…» → host picker), and «Открыть во вкладке» in the store.
- `SSHSession` (`Shared/SSH/SSHSession.swift`, `@MainActor @Observable`): state
  `.connecting / .hostKeyPrompt / .connected / .failed(String) / .closed`;
  owns `SSHClient`, the PTY channel (`withPTY`, `xterm-256color`, size from the
  view, `changeSize` on resize), the lazily opened `SFTPClient` on the same
  connection, keepalive every 30 s, and the cwd (see 4). It feeds bytes both ways
  between SwiftTerm and the PTY.
- Lifecycle: the session lives while the tab is awake; tab sleep / close / app
  quit closes it. A dropped connection shows «Соединение потеряно» with
  «Переподключиться» (⌘R) over the last screen. Login errors (wrong password,
  key refused, timeout, DNS) are shown as text on the tab, with «Изменить сервер».
  Citadel 0.12.1 has no keyboard-interactive auth: a server that offers only
  that method gets «Сервер принимает пароль только в режиме keyboard-interactive,
  используйте ключ» (adding it via `.custom(NIOSSHClientUserAuthenticationDelegate)`
  is the upgrade path).
- iPhone: iOS closes sockets in the background (no background modes, see
  `docs/app-store.md`). On return the tab reconnects by itself and says
  «Новая сессия» in the status line; the old shell is gone. Documented as a
  platform limit.

**Mac layout**: SwiftTerm `TerminalView` fills the tab (font: SF Mono 13, the
system light/dark colors, ⌘+/⌘− change the font size per host like page zoom).
⌘⇧F or a toolbar button slides in «Файлы» on the right (resizable, remembered).
Copy/paste with ⌘C/⌘V, selection copies on ⌘C only.
**iPhone layout**: segmented «Терминал | Файлы» at the top; above the keyboard a
row: Esc, Tab, Ctrl (sticky), ↑ ↓ ← →, `|`, `/`, `-`, and the suggestion strip
(see 5).

## 3. SFTP file browser (`Shared/SSH/SFTPBrowser*.swift` + per-platform views)

- Path bar (tap a segment to go up), list: name, size, modified, permissions;
  folders first, then by name; hidden files behind a toggle. Follows the
  terminal's cwd when it is known and the user hasn't navigated away; a «↧ папка
  терминала» button jumps back.
- Actions: open folder; download (Mac: into `~/Downloads` through the existing
  `Downloads` naming and quarantine; iPhone: Documents, visible in «Файлы»);
  upload (Mac: drag from Finder onto the list or «Загрузить…»; iPhone: document
  picker); new folder; rename; delete (files and empty or non-empty folders,
  recursive, confirmation with the count); «Права…» chmod with rwx checkboxes
  and an octal field.
- Text editor: files ≤ 5 MB that decode as UTF-8 open in a plain monospace
  editor; ⌘S writes to `<name>.unibrowser-tmp` then renames over the original
  (keeps the original's permissions). Others offer download only.
- Transfers: a queue (one at a time per session) with progress, speed and
  cancel; a name clash asks «Заменить / Оставить оба / Пропустить». Errors keep
  the item in the queue with «Повторить».

## 4. Current directory

The terminal's cwd comes from OSC 7 (`file://host/path`) when the remote shell
sends it (zsh with many frameworks, fish, Ubuntu's bash with vte). SwiftTerm
reports it via its delegate. Without OSC 7 the cwd stays the login home dir
(one `pwd` over an exec channel at connect). No injection into the user's shell
config. A host setting «Сообщать папку терминала» may later add a one-line
`PROMPT_COMMAND`; not in this version.

## 5. Autocomplete

- **Line model** (`Shared/SSH/CommandLineModel.swift`, pure, checked by script):
  rebuilt from the user's own keystrokes since the last Enter / Ctrl-C / Ctrl-D.
  Printable input and Backspace update it; anything we can't follow (arrows,
  Ctrl-A/E/U/W/R, Tab, Esc sequences, paste with a newline) marks it unknown and
  hides suggestions until the next Enter. Hidden as well while the terminal is
  on the alternate screen (vim, less, top) or the remote side echoes something
  that isn't our input (a password prompt after `sudo` echoes nothing, so no
  suggestions while echo is off: we compare our typed chars with the echoed ones).
- **Sources**, ranked prefix matches, max 8:
  1. this host's command history (local per device, last 2000 lines, stored in
     `ssh-history/<host-id>.json`, never synced, lines with a leading space are
     not saved);
  2. for the first word: commands of the server from one `compgen -c | sort -u`
     over an exec channel at connect (fallback: `ls` over each `$PATH` dir), cached
     per host for 24 h;
  3. for later words that look like paths: SFTP listing of the resolved
     directory (cwd-relative, `~`, absolute), cached 10 s per directory;
     folders get a trailing `/`.
- **UI**: Mac: a small list anchored at the cursor cell (SwiftTerm gives the
  caret position), ↑/↓ inside it only while it shows, Tab or → accepts, Esc
  hides. Accepting sends the missing suffix as keystrokes. Arrow keys go to the
  shell when the list is hidden. iPhone: the strip above the keyboard, tap accepts.
- A setting «Подсказки в терминале» (on by default) in Mac Settings and iPhone
  «Настройки».

## 6. Network

- Mac: always direct (Citadel's own bootstrap, connect timeout 15 s).
- iPhone, host without «через Mac»: direct.
- iPhone, host with «через Mac»: NIO `ClientBootstrap` to `127.0.0.1:47801` (the
  loopback SOCKS port `MacRelay` already serves while the app is on screen) with
  `SOCKSClientHandler(targetAddress: .domain(address, port))`, then
  `SSHClient.connect(on:)`. Nothing changes on the Mac side. Not linked → the tab
  says «Нет связи с Mac» and retries when the link comes up (same hook as
  via-Mac web tabs, commit 0bdfaeb).
- The tab's status line shows «Напрямую» or «Через Mac».

## 7. Sync

- `SyncMessage` gains:
  - `sshHosts([SyncedSSHHost])` — whole list with tombstones and secrets, either
    way, after any change and from the Mac once after `hello`; receiver merges
    and sends its list back if the result differs (same pattern as `bookmarks`).
  - `knownHosts([KnownHost])` — same pattern.
- `hello` gets `sshHosts` and `knownHosts` fields so the first exchange is one
  round trip.
- ALPN becomes `unibrowser/via-mac/3`; `/2` joins the legacy list so an older app
  is told to update instead of failing to decode.
- Secrets travel over the iroh link (QUIC/TLS between the paired, key-pinned
  endpoints), the same channel that already carries the passwords.
- SSH tabs sync as normal tabs (section 2). Terminal contents, history and SFTP
  state are per device.

## 8. Checks

- `scripts/ssh_host_merge_check.swift`: merge winners, tombstones, equal-time
  tie-break, known-hosts union.
- `scripts/ssh_key_check.swift`: parse ed25519 plain / encrypted, RSA, reject
  ppk and old PEM with the right message, generate → export → parse round trip,
  public key line format.
- `scripts/command_line_check.swift`: line model on typed text, backspace,
  unknown keys, Enter reset, echo mismatch.
- End to end against a local `sshd` (macOS Remote Login, or
  `linuxserver/openssh-server` in Docker for a Linux shell with bash and
  `compgen`): password login, key login, host-key prompt and mismatch, `ls` in
  the terminal, resize, OSC 7 cwd, upload / download / rename / chmod / delete,
  edit and save a file, suggestions for commands and paths. On the iPhone
  simulator: the same host direct, and «через Mac» through a paired Mac. Sync:
  add / edit / delete a host on one side, see it on the other.

## Order of work

1. Store, keychain secrets, keys, known hosts, Mac «SSH» section; Mac SSH tab
   with terminal.
2. SFTP panel and transfers on Mac.
3. Autocomplete on Mac.
4. iPhone: store UI, tab, terminal, files, suggestion strip, «через Mac»; sync v3.

## Not in this version

ssh-agent and agent forwarding, ProxyJump, port forwarding, ECDSA keys,
keyboard-interactive / 2FA prompts, shell integration injection, synced
command history, folder sync / diff, several terminals per tab.
