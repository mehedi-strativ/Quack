# Hidden Bar Foundation Rebuild — Design

**Date:** 2026-07-23
**Status:** Implemented (2026-07-24). Manual QA on real hardware surfaced a
divider-drift bug not anticipated by this design (every `expand()`/`collapse()`
cycle permanently shifts the divider's position) — fixed post-merge; see
`git log --grep drift` for that follow-up commit. A separate, pre-existing
glyph-capture bug (hidden items always render their generic app icon instead
of the real menu-bar glyph) was found during the same QA pass and confirmed
unrelated to this phase — tracked as its own follow-up, not fixed here.
**Supersedes:** `2026-07-13-bartender-hidden-bar-design.md` (mechanism/spike
findings there still hold — read it first; this doc only covers what changes)
**Phase:** 1 of 6 in the Bartender-parity project (see Roadmap below)

## Why

`HiddenBarService.swift` (383 lines) has an accumulating-retry-counter bug in
`warmAndCollapse`: an `isRetry` flag and a `warmAttempts` counter that must be
manually reset on every fresh (non-retry) trigger, or the counter accumulates
across the 1.5s display-policy timer's ticks until it passes the 25-attempt
cap and every later call gives up immediately — the feature then needs a
relaunch to recover. `forwardClick` has a separate, milder bug: a fixed 0.15s
delay before synthesizing the click, which is a guess, not a wait — the
"clicking sometimes does nothing" latency bug. User wants the orchestration
dropped and rebuilt clean rather than patched again — see memory
`quack-hidden-bar-capture-findings` for the bug history this produced.

**Correction (2026-07-23, mid-planning):** an earlier draft of this doc was
written against a since-discarded uncommitted WIP that had already added a
`lastWarmAndCollapseAt` debounce and turned `forwardClick`'s fixed delay into
its own duplicated retry loop (`waitToForwardClick`, mirroring
`warmAndCollapse`'s). That WIP was judged stale/abandoned and reverted before
implementation started; this doc now describes the actual HEAD baseline
(commit `82e847d`) instead. `HiddenBarService.swift` also has a
`refreshTimer`/`refreshWhileShowing` (5s periodic recapture while the panel is
showing) not mentioned below — it's unrelated to the retry-counter bug and
stays untouched by this phase.

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

1. **One cancellable settle-and-retry primitive, replacing the counter.** A
   generic `AXSettleWaiter` (poll-every-0.2s/give-up-after-25-attempts,
   cancel-and-restart on every new call) replaces `warmAndCollapse`'s
   `warmAttempts`/`isRetry` counter — starting a new wait cancels whichever
   wait is in flight, which removes the "counter never resets, feature dies
   until relaunch" bug class structurally instead of patching around it.
   `forwardClick`'s fixed 0.15s delay is upgraded to use the same primitive
   (its second real use, not a duplicate) — fixing the "clicking sometimes
   does nothing" latency bug as a natural extension rather than a new
   mechanism.
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
4. **Bar panel, condition-reveal (battery/Wi-Fi)** — logic unchanged.
   `refreshTimer`/`refreshWhileShowing` (5s periodic recapture while showing)
   also unchanged — unrelated to the retry-counter bug, out of scope here.
5. **Settings surface** — unchanged: `hiddenBarEnabled`,
   `hiddenBarRevealOnBattery`, `hiddenBarRevealOnWifiOff` stay wired the same
   way in `SettingsView.swift` / `AppEnvironment.swift`.

## Testing

- Unit: `HiddenBarReveal.next` transition table (already pure/testable) —
  each scroll/swipe tick fires the existing `.hoverChevron` event followed by
  `.exitAll` (re-arms the grace timer so the panel stays open while ticks
  keep arriving, same as hover; no new `RevealEvent` case needed). Also unit:
  `AXSettleWaiter` (settles immediately when the probe already passes,
  exhausts after `maxAttempts` with the last probed value, a new `start`
  cancels a prior in-flight wait, cancellation after the probe fires
  suppresses `completion`).
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
