# 0012 — Ledger Atlas stays native Swift (no Electron, no Rust/Tauri)

Status: accepted 2026-11-07 (merged as #175).

Decision page with the matrix, blocker map, migration cost and council review:
https://claude.ai/artifact/2AmUZUvYMUVmk8Kxc7Eh38 (copy: project files `plans/stack-decision-2026-11-06.md`).

## Context

With v1.0 due 2026-12-07, Prax asked whether the app should stay native, move to
Electron, or pivot to Rust/Tauri, to be "more compatible, more feature-full", and to
avoid the problems hit while implementing certain things. The app is 100% Swift
(Swift 6.2 package, macOS 15; SwiftUI + AppKit shell). There is no Electron build;
the Next.js folder is a 660-line demo.

Constraints: zero spend (no Apple Developer Program, ad-hoc signed DMG, free macOS
runners on a public repo), cloud-first development (no Mac in the loop), and a
phase-2 wish for iOS, maybe other platforms later.

Measured on main 0908ef1 (2026-11-04): about 44,000 lines of Swift and C
(LedgerCore 7.1k, LedgerStore 11.0k, MMImport 11.8k, LedgerAtlasMacUI 13.0k,
CSQLite 0.9k), 781 tests in 30,500 lines, import certificate L3 (#134), 82 PRs
merged between 2026-11-02 and 2026-11-04.

## Evidence

Nine real blockers were recorded between 2026-11-02 and 2026-11-04. None was caused
by Swift:

| Cause | Blockers | Would Electron or Tauri avoid it? |
| --- | --- | --- |
| macOS policy at zero spend | Keychain -34018 and password prompts after updates (#154, #156); App Sandbox blocks SQLite journals next to a picked file (#97); the widget needs an App Group, dead in an ad-hoc DMG | Keychain: partly; Electron's safeStorage uses a device-only item, so it avoids -34018, but without a Team ID that item still prompts for a password after every update (the cdhash partition, #154). Sandbox: yes, by not sandboxing, which Swift could also do. Widget: no widget at all. |
| AppKit/SwiftUI test tooling | run loop exits after a sheet closes (#147, #151); AX reads crash; `swift test --no-parallel` on the 3-core runner | Yes, with browser test tooling, at the cost of hand-built accessibility |
| Our own data and file design | 900 MB ledger, 70 s first open (#123, #125); pinned VFS zPath crash (#150); POSIX lock drop (#140) | No, same schema and the same SQLite semantics |
| GitHub billing | 6-hour Actions lock on 2026-11-02 | No, the DMG still needs a Mac runner |

Three independent council delegates (Claude models at high effort, each given the
evidence pack without this recommendation) scored "best choice for this project":

| Option | Delegate A | Delegate B | Delegate C |
| --- | --- | --- | --- |
| Native Swift | 9 | 9 | 9 |
| Electron | 2 | 2 | 2 |
| Rust + Tauri, full rewrite | 2 | 1 | 1 |
| Tauri shell + Swift kernel sidecar | 4 | 3 | 3 |

Migration estimates ranged from 10 agent-days (Tauri shell over a sidecar) to 100
agent-days (Rust rewrite with re-certification). Even the smallest consumes the
remaining calendar, drops the widget, Shortcuts, OCR and native accessibility, and
restarts the UI test suite; a sidecar cannot run on iOS, so it does not buy the
phase-2 goal either.

## Decision

1. Ledger Atlas stays native Swift/SwiftUI through v1.0 and phase 2 (iOS). No
   Electron build is started. No Rust or Tauri rewrite is started.
2. The cross-platform contract is the canonical SQLite ledger file plus the sync
   contract in `CONTEXT.md` ("future clients sync canonical operations/entities").
   Any later client, on any stack, reads the same file. The Mac app does not change
   for that.
3. `LedgerCore`, `LedgerStore` and `MMImport` stay free of AppKit and SwiftUI, and
   the Linux harness stays green, so the kernel remains portable.
4. The UI complaints (theme selection not applying; "looks mid") are handled as
   polish and bug work in the Pro-look thread (#161 and #163 merged), not as a
   stack change.

## Consequences

- The zero-spend Apple costs stay: ad-hoc signing, the "Open Anyway" first launch on
  macOS 15 (documented in `docs/INSTALL.md`), secrets in private files instead of
  Keychain (#154), no widget data sharing. They would stay on any stack.
- iOS cannot be installed at zero spend on any stack (free provisioning lasts 7 days
  and needs Xcode on a Mac). Phase 2 is a budget decision (Apple Developer Program)
  before it is a stack decision. The paid account also removes the Keychain, App
  Group and notarization problems above.
- Kernel portability to iOS is likely but untested: `Package.swift` lists macOS only,
  no CI job builds an iOS destination, and the CSQLite pinned VFS uses a `/dev/fd`
  trick that has never run under the iOS sandbox. A two-day spike after v1.0 (one
  `xcodebuild` job with an iOS destination) settles it.
- Re-open this decision only if one of these becomes true: Android or Windows is
  wanted before iOS; the ad-hoc path breaks on a macOS update; or the iOS build
  spike (run after v1.0 and before phase-2 planning, by 2026-12-19) shows the kernel
  cannot be linked into an iOS app.
