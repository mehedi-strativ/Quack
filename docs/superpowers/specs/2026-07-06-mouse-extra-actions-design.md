# Mouse Extra-Button Actions — Desktop Navigation + Recorder Limits — Design Spec

- **Date:** 2026-07-06
- **Status:** Approved
- **Branch:** `mouse-action-buttons`

## Problem

Two gaps in the Extra Buttons section of the Mouse settings tab:

1. No way to bind a mouse button to Desktop Next / Previous (Spaces navigation).
2. The keyboard-shortcut recorder silently fails to capture OS-reserved combos
   (⌃+Arrow, ⌘Space, ⌘Tab, …) — WindowServer consumes those as symbolic
   hotkeys before any app, even via a local `NSEvent` monitor, ever sees the
   keyDown. The recorder just never registers a value; no error, no feedback.

## Goals

- Add `desktopNext` / `desktopPrevious` as first-class `MouseButtonAction`
  cases, positioned after `showDesktop`.
- Implement by synthesizing ⌃→ / ⌃← — same mechanism and pattern already used
  for `missionControl` (⌃↑) and `appExpose` (⌃↓).
- Add an inline caption under the shortcut recorder (shown only when
  `.customShortcut` is selected) explaining that OS-reserved combos can't be
  recorded, pointing at the action list as the alternative.

## Non-goals

- No global `CGEventTap` to capture reserved combos. That's the freeze-risk
  architecture CLAUDE.md warns about, and not worth it here — the Spaces/
  Mission Control shortcuts users actually want are fully covered by named
  actions instead.
- No change to the existing modifier-capture logic — it already correctly
  reads ⌘⌥⌃⇧ for any combo that isn't OS-reserved.
- No per-user customization of which keycodes map to Spaces navigation;
  hardcoded to the macOS default binding, same as `missionControl` /
  `appExpose` / `showDesktop` already do.

## Architecture / Changes

| File | Change |
|---|---|
| `Sources/QuackKit/Models/MouseButtonAction.swift` | add `desktopNext`, `desktopPrevious` cases + titles |
| `Sources/Quack/Mouse/MouseActionPerformer.swift` | add two arms posting ⌃→ / ⌃← |
| `Sources/Quack/Settings/SettingsView.swift` | add caption under `ShortcutRecorderField` when action is `.customShortcut` |

### `MouseButtonAction` additions

```swift
case desktopNext
case desktopPrevious
...
case .desktopNext: return "Desktop Next"
case .desktopPrevious: return "Desktop Previous"
```

Declaration order (drives dropdown order via `CaseIterable`):
`default_, missionControl, appExpose, showDesktop, desktopNext, desktopPrevious, playPause, nextTrack, previousTrack, volumeUp, volumeDown, mute, customShortcut, disabled`

### `MouseActionPerformer` additions

```swift
case .desktopNext:
    postKeystroke(keyCode: 124, flags: .maskControl)      // ⌃→
case .desktopPrevious:
    postKeystroke(keyCode: 123, flags: .maskControl)      // ⌃←
```

### Recorder hint copy

Shown under the "Shortcut" row only while the row's action is
`.customShortcut`:

> System shortcuts like ⌃+Arrow or ⌘Space can't be recorded here — use the
> action list above if there's a match.

Styled like the file's existing secondary captions (`.font(.system(size: 12)).foregroundStyle(.secondary)`, e.g. the "Buttons 4 and 5 are…" line).

## Testing

`MouseModelTests.swift`'s `allCases`-parametrized tests (`rawValueRoundTrip`,
`titlesNonEmpty`) automatically cover the two new cases — no test changes
required. `MouseActionPerformer` has no existing tests (thin `CGEvent.post`
wrapper); the two new arms mirror the already-untested `missionControl` /
`appExpose` arms, so left untested for consistency.

## Risk

Neither change touches the CGEvent input-tap lifecycle (`InputTaps.swift`,
`EventTapThread`). `MouseActionPerformer` only *posts* synthetic events — it
doesn't listen — and the recorder stays a local `NSEvent` monitor exactly as
before.
