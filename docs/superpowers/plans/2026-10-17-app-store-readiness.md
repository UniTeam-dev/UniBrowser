# App Store Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Mac and iPhone apps pass App Review without losing working features.

**Architecture:** Turn on App Sandbox on the Mac, drop the one feature that cannot run sandboxed and never worked (Apple Passwords helper bridge), make extension installs survive the sandbox, add privacy manifests and export-compliance keys to both apps.

**Tech Stack:** Swift 6, SwiftUI, WebKit, XcodeGen, iroh-ffi.

**Spec:** ilja's request (thread): "fix everything that could block App Store; every change must be App Review-safe". Guidelines 2.4.5 (sandbox), 2.5.1 (public API), 2.5.2 (downloaded code), 5.1.1 + ITMS-91053 (privacy manifest).

## Global Constraints
- Public API only; no spawning processes; App Sandbox on the Mac.
- No feature that works today may disappear.
- Small commits, no AI attribution, no push.

## Review Focus
- Data from the unsandboxed build (session.json, extensions) must still be there after the first sandboxed launch: container-migration.plist.
- Reinstalling the same extension (store or folder) must not delete the files it just installed.
- An unpacked extension must still load after relaunch (sandbox drops access to the original folder): copy it into the container.
- iroh must still accept the phone under the sandbox: network.server entitlement.
- File upload / CSV import / space image via NSOpenPanel: user-selected read-only entitlement.

---

### Task 1: Remove the Apple Passwords helper bridge
**Files:** delete `UniBrowser/Passwords/ApplePasswordsProvider.swift`, `PasswordsSRP.swift`, `Views/PairingSheet.swift`; modify `CredentialProvider.swift` (PasswordsService → keychain only), `PasswordBar.swift`, `BrowserCommands.swift`, `MainWindow.swift`, `UniBrowserApp.swift`; drop BigInt from `project.yml`; update `docs/passwords.md`.
- [ ] Remove, build (`scripts/build.sh`) → BUILD SUCCEEDED; `grep -rn Process\( UniBrowser` → nothing. Commit.

### Task 2: App Sandbox on the Mac
**Files:** `UniBrowser/Resources/UniBrowser.entitlements` (app-sandbox, network.client, network.server, files.user-selected.read-only), `UniBrowser/Resources/container-migration.plist` (moves `${ApplicationSupport}/UniBrowser`).
- [ ] Build; `codesign -d --entitlements - UniBrowser.app` shows app-sandbox. Launch; session restored, ViaMac starts. Commit.

### Task 3: Extensions survive the sandbox
**Files:** `UniBrowser/Extensions/ExtensionManager.swift`.
- `installFolder(_:)` copies the folder to `directory/<UUID>` and installs from there; store ZIPs saved as `<id>-<UUID>.zip`; `remove(_:)` deletes files only inside `directory`; reinstall dedupe: same storeID, or unpacked with same name.
- [ ] Build; install an unpacked folder, relaunch, still loaded. Commit.

### Task 4: Privacy manifests + export compliance
**Files:** create `UniBrowser/Resources/PrivacyInfo.xcprivacy`, `mobile/UniBrowserMobile/Resources/PrivacyInfo.xcprivacy` (UserDefaults CA92.1, FileTimestamp C617.1 for iroh's fstat, no tracking, no collected data); add `ITSAppUsesNonExemptEncryption=false` to both Info.plist.
- [ ] Both builds; manifest present in the .app bundles. Commit.

### Task 5: Build scripts + report
- [ ] `scripts/build.sh`, `mobile/build-device.sh` succeed. Write `docs/app-store.md`: what changed, remaining risks (Chrome Web Store installs 2.5.2, ViaMac proxy 5.4, review notes) with options for ilja.
