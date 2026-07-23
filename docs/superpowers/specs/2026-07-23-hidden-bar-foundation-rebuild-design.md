# Hidden Bar Foundation Rebuild — Design

**Date:** 2026-07-23
**Status:** Approved design, pending implementation plan
**Supersedes:** `2026-07-13-bartender-hidden-bar-design.md` (mechanism/spike
findings there still hold — read it first; this doc only covers what changes)
**Phase:** 1 of 6 in the Bartender-parity project (see Roadmap below)

## Why

The 2026-07-13 design shipped and works, but `HiddenBarService.swift` (405
lines) accumulated bug-fix-on-bug-fix: an accumulating retry counter that had
to be patched with an `isRetry` flag, a manual timestamp-based debounce, two
near-identical copy-pasted 0.2s/25-attempt AX-settle polling loops
(`warmAndCollapse` and `waitToForwardClick`), and a belt-and-suspenders 1.5s
poll timer stacked on top of a notification observer. User wants the
orchestration dropped and rebuilt clean rather than patched again — see
memory `quack-hidden-bar-capture-findings` for the bug history this produced.

Research into Bartender 6's public marketing page (macbartender.com/pro)
turned up a feature list, not a technique — no public API exists for
one app to move another's `NSStatusItem`, so Bartender/Ice and Quack's
existing implementation all use the same divider-trick + AX-scan +
synth-click-forward mechanism. Nothing here changes the mechanism; it
re-engineers the orchestration around it and adds one new interaction
(scroll/swipe reveal) called out on that page.

## What's kept as-is (proven, not where the bugs were)

`NotchGeometry`/`NotchProbe`, `MenuBarGeometry`/`MenuBarBand`,
`MenuBarAXScanner`, `SynthClick`, `MenuBarItemImageCache`, `StatusWindowList`,
`HiddenBarConditionMonitor`, `ControlItemManager`, `HiddenBarPanel`,
`HiddenBarView`, `HiddenBarLayout`, and QuackKit's `HiddenBarReveal` /
`RevealState` / `RevealEvent` pure state-transition table. None of these
files are touched.

## What's rebuilt: `HiddenBarService.swift`

1. **Task-based settle-and-act, replacing Timer/counter soup.** One
   cancellable-`Task` helper (`waitForSettledFrame`) replaces both
   `warmAndCollapse`'s and `waitToForwardClick`'s duplicated poll-every-0.2s/
   give-up-after-25-attempts loops. Every new trigger cancels the in-flight
   `Task` and starts fresh — this removes the "counter never resets, feature
   dies until relaunch" bug class structurally instead of patching around it
   with `isRetry`/timestamp-debounce flags.
2. **New: scroll/swipe reveal.** An `NSEvent.addGlobalMonitorForEvents(matching:
   [.scrollWheel])` monitor (listen-only — not a `CGEventTap`, so it cannot
   gate input and the CLAUDE.md freeze rule does not apply) fires the same
   reveal event as chevron-hover when the cursor Y sits in the menu-bar band.
   No new setting — folds into the existing hover-reveal path.
3. **Notch accommodation / multi-display policy** — behaviorally unchanged
   (hide whenever any connected display has a notch; poll timer stays as a
   belt-and-suspenders alongside `didChangeScreenParametersNotification`,
   since that notification is confirmed unreliable) — just separated out
   from the retry mess so it reads as its own method again.
4. **Bar panel, click-forward, condition-reveal (battery/Wi-Fi)** — logic
   unchanged, just no longer tangled with the retry loop it depended on.
5. **Settings surface** — unchanged: `hiddenBarEnabled`,
   `hiddenBarRevealOnBattery`, `hiddenBarRevealOnWifiOff` stay wired the same
   way in `SettingsView.swift` / `AppEnvironment.swift`.

## Testing

- Unit: `HiddenBarReveal.next` transition table (already pure/testable) —
  scroll/swipe maps to the existing `.hoverChevron` event (same grace/pin
  semantics as hover; no new `RevealEvent` case needed).
- Manual (AX/CGEvent behavior isn't unit-testable): hide items via ⌘-drag;
  hover/click/scroll/swipe reveal; click opens the real app menu; notch
  connect/disconnect toggles hide-vs-show-all; battery/Wi-Fi conditions
  surface the right icon; no input freeze toggling Accessibility mid-session
  (regression guard for the CLAUDE.md freeze class).

## Roadmap (this project's remaining phases, each its own spec later)

2. Smart triggers + presets — rule engine (battery/Wi-Fi/time/location/app)
   driving auto-show and named configs (work/home/screen-share).
3. Quick Search — keyboard palette to find + activate any menu bar item.
4. Icon grouping — combine several real items behind one proxy dropdown.
5. Visual skinning — tint/gradient/border/rounded bar, per-Space styles.
6. Custom widgets — no-code user-defined menu bar buttons that run an action.

Phases 2-4 read the hidden-item list this phase produces; none of them are
designed yet.

## Out of scope (this phase)

Everything in the Roadmap above. Also unchanged from the 2026-07-13 doc's
"Out of scope": multi-display secondary-bar rendering, a third "Always
Hidden" zone, automatic (non-⌘-drag) item movement, per-item "show when
updated" rules.
