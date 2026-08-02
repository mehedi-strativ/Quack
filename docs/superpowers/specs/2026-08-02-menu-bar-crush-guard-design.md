# Menu Bar Crush Guard — Design Spec

- **Date:** 2026-08-02
- **Status:** Draft

## Problem

CPU-temp and time-awareness menu-bar items were toggled on in Settings but
never appeared. Root cause (traced via `superpowers:systematic-debugging`,
code confirmed clean): macOS notch-crush. On this machine (14" MBP, notch),
menu-bar items pushed left of/behind the notch become completely unmapped —
`isVisible` still reports `true`, but there is no on-screen window server
backing (confirmed previously in `docs/superpowers/specs/2026-07-01-notch-icon-reveal-design.md`
and the now-removed hidden-bar feature's postmortem). Quack owns four
`NSStatusItem`s competing for the same shrinking space: duck
(`quack.duck`), countdown (`quack.countdown`), CPU-temp
(`quack.temperature`), and the time-awareness timer.

The full Bartender-style hidden-bar feature that used to paper over this for
*all* menu-bar apps was removed entirely in `a37bc03` at the user's own
request — it required cross-app AX scanning, CGWindowList capture, glyph
caching, and click-forwarding, and wasn't worth the ongoing edge-case
maintenance. This spec is deliberately narrower: **Quack's own four items
only.**

## Why this is simpler than the removed feature

The removed hidden-bar code needed AX/CGWindowList/glyph-capture machinery
because it had to observe and interact with *other apps'* status items,
which Quack's process doesn't own. None of that applies here: Quack holds
direct `NSStatusItem` references to all four items in question, so
`item.button?.window?.frame` is authoritative AppKit state, readable
directly, regardless of window-server capture/mapping status. No AX, no
`CGWindowListCopyWindowInfo`, no screen recording, no click-forwarding.

## Goals (v1)

- Detect when any of Quack's own four status items is crushed by the notch.
- When crushed, hide lower-priority Quack items (in priority order below)
  to free horizontal space, until the crushed item is no longer crushed.
- Reveal previously-hidden items again once there's stably enough room.
- No user-visible configuration — fully automatic, matching the "no manual
  zone configuration" precedent from the notch-icon-reveal spec.

## Non-goals (v1)

- No handling of third-party apps' status items (that's the removed
  feature's scope; not revisited here).
- No support for non-notched displays — `NotchGeometry.notchSpan` returns
  nil there, so the guard is inert by construction.
- No manual override UI (no "always show" toggle, no drag-to-reorder). If
  this proves insufficient in practice, that's a future spec.

## Priority order

`duck > countdown > temperature > timer` (user-confirmed). Duck is settings
access, never yields. Countdown is time-sensitive meeting info, yields
second. Temperature and timer are both opt-in stats; timer yields first.

## Architecture

```
Sources/QuackKit/MenuBar/
  MenuBarCrushGuard.swift (pure logic, unit-tested)
    — Given each item's current frame.minX, its priority rank, and the
      current NotchGeometry.NotchSpan, decides the next single action:
      hide the lowest-priority VISIBLE item that is causing crush pressure,
      or reveal the highest-priority HIDDEN item if doing so would not
      recreate a crush (approximated conservatively — see Decision rule).
    — Pure value types in, pure decision out. No AppKit, no timers, no
      side effects — mirrors how `NotchGeometry` itself stays screen-free
      and testable.

Sources/Quack/MenuBar/
  MenuBarCrushMonitor.swift (AppKit driver)
    — Holds weak refs to the 4 status items (temp/timer refs are optional —
      absent when their Feature toggle is off).
    — On a 3s debounced timer (matching TemperatureStatusItem's existing
      poll cadence — no new timer granularity introduced), reads each
      item's `button.window.frame.minX` and the current screen's
      NotchGeometry, feeds MenuBarCrushGuard, applies the single action
      (toggle one item's `.isVisible`) if any.
    — Hysteresis: a hide action applies immediately (safety first); a
      reveal action requires 2 consecutive clear ticks (~6s) before
      applying, so a boundary case can't flap every tick. This mirrors the
      debounce fix that resolved the countdown-drift bug documented in the
      hidden-bar postmortem (root cause there was zero debounce on relayout
      triggers).
    — Lives on `AppEnvironment`, started unconditionally in `init()` (not
      gated through `Feature`/`ManagedService` — duck and countdown are not
      opt-in, so this can't be modeled as a togglable feature service).
```

### Decision rule (pure function, in `MenuBarCrushGuard`)

```
input: items sorted by priority (highest first), each with
       (isVisible: Bool, frameMinX: CGFloat), and notch: NotchSpan?

if notch == nil: no action (non-notched screen)

if any VISIBLE item, other than the single highest-priority visible one,
has frameMinX < notch.maxX (per NotchGeometry.isHiddenByNotch):
    → action: hide the LOWEST-priority visible item
      (frees width; re-checked next tick — may take several ticks to
      fully clear, each hiding one more item, worst case down to just duck)

else if the lowest-priority HIDDEN item exists and no visible item is
currently crushed:
    → candidate: reveal it
    → only apply after 2 consecutive ticks report this same candidate
      (hysteresis)

else: no action
```

This never simulates "would revealing X cause a crush" directly — that
would require guessing the revealed item's future frame before macOS lays
it out. Instead it reveals optimistically and lets the *next* tick's hide
branch correct it if reveal was wrong. Worst case: one extra
hide→reveal→hide cycle (~9s) rather than a permanent wrong state.

## Error handling / degradation

| Condition | Behavior |
|---|---|
| No notch on this screen | `NotchGeometry.notchSpan` returns nil; guard never acts. Not an error. |
| Temp/timer service not started (toggle off) | Monitor simply has no ref for that item; treated as absent, not hidden. |
| Duck itself somehow crushed | No lower-priority item exists to hide (duck is highest); guard has no action — accepted, matches "duck never yields" by construction rather than by special-casing. |
| Screen/display change mid-session | Re-read frames next tick; no persistent state depends on a specific screen. |

## Testing / verification

- `MenuBarCrushGuardTests` (QuackKit): table-driven, fixture frames +
  priorities + `NotchSpan` → expected action, hide and reveal-with-hysteresis
  cases. Same style as existing `NotchGeometry`/`ChevronPlacement`-era tests
  (now removed with hidden-bar, but the pattern is the precedent).
- No live AX/GUI verification planned — per this repo's own documented
  experience, scripted interaction risks stray TCC prompts and unreliable
  results on this machine. If real-hardware confirmation is needed, use the
  established temp-`Logger` + `log show` pattern (see
  `quack-hidden-bar-capture-findings` memory) rather than guessing from
  screenshots.

## Open risks

- `frame.minX` read immediately after an `.isVisible` mutation may be
  stale for a beat (documented AppKit relayout lag from the hidden-bar
  postmortem) — the 3s tick interval is intentionally coarse enough that a
  fresh read next tick should reflect reality; not adding an explicit
  settle-poll unless real-world testing shows the coarse interval isn't
  enough.
- Priority-based hiding means a user who wants to see the *lower*-priority
  item (say, timer) more than a higher one has no override in v1 — accepted
  per non-goals; a future spec could add manual pinning if this surfaces.
