# iPhone App Store Submission Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** The iPhone app (`mobile/`) can be archived and exported for App Store Connect and has nothing App Review rejects on sight; tab sync and «Через Mac» keep working.

**Architecture:** Config-only where possible: Info.plist, PrivacyInfo.xcprivacy, project.yml, an export-options plist and a mode of `mobile/build-device.sh`. No change to `Shared/ViaMac` wire protocol.

**Tech Stack:** Swift 6, SwiftUI, WebKit, XcodeGen, iroh-ffi (IrohLib 1.1.0).

**Spec:** owner's decisions of 2026-10-18 (iPhone → App Store; Mac → website only; name UniBrowser; core feature = sync + «Через Mac»).

## Global Constraints
- Public API only on iPhone; no downloaded executable code.
- Do not change the bundle ID (`com.ilya.browser`) — recommendation goes in `docs/app-store.md`.
- Team ID `7SJ59D8JGU`. Nothing is uploaded.
- Do not touch `UniBrowser/Views`, `UniBrowser/App`.
- Commits without AI attribution, no push.

## Review Focus
- The ad-hoc install path (`mobile/build-device.sh` with no argument) must keep working exactly as before.
- Required-reason APIs linked from IrohLib (Rust std: `stat`/`fstat`, `mach_absolute_time`, `statfs`…) must be declared, judged from `nm -u` of the built binary, not guessed.
- iroh talks to LAN addresses (direct path): Local Network prompt needs `NSLocalNetworkUsageDescription`; mDNS only if iroh uses it (`NSBonjourServices`).
- No private selectors in the binary (`strings` for `_`-prefixed ObjC selectors from our code).
- User-visible name is UniBrowser everywhere (home screen, Settings, App Store product name).

---

### Task 1: Audit and fixes
**Files:** `mobile/UniBrowserMobile/Resources/Info.plist`, `PrivacyInfo.xcprivacy`, `mobile/project.yml`.
- [x] `mobile/build.sh` → BUILD SUCCEEDED; `nm -u` and `strings` the simulator binary; grep sources for KVC/selectors/dlopen.
- [x] Add whatever the audit shows missing (privacy reasons, product name). Rebuild. Commit.

### Task 2: App Store export path
**Files:** create `mobile/ExportOptions-AppStore.plist` (`method` = `app-store-connect`, `destination` = `export`, `teamID` = `7SJ59D8JGU`, `signingStyle` = `automatic`); modify `mobile/build-device.sh` (`appstore` argument: archive with automatic signing and `-allowProvisioningUpdates`, export to `build/appstore`).
- [x] `plutil -lint` the plist; `bash -n` the script; run `build-device.sh appstore` and record whether signing is available here. Commit.

### Task 3: Docs
**Files:** rewrite `docs/app-store.md` (Russian); delete `docs/superpowers/plans/2026-10-17-app-store-readiness.md`; fix `README.md`, `mobile/README.md`.
- [x] `grep -rn "2026-10-17-app-store\|UniBrowserDirect\|DIRECT" README.md mobile docs` → nothing stale. Commit.

### Task 4: Verification
- [x] `merge_check` passes; `mobile/build.sh` and `NO_OPEN=1 scripts/build.sh` → BUILD SUCCEEDED, 0 errors; run the simulator app; pair with the Mac app if possible.
