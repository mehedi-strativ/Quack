#ifndef CMULTITOUCH_H
#define CMULTITOUCH_H

#include <stdbool.h>

/// Raw trackpad multitouch access over Apple's private
/// `MultitouchSupport.framework` — the same approach Swish and BetterTouchTool
/// use to read finger contacts the public `NSEvent` / `CGEventTap` APIs never
/// expose (they only deliver already-recognized gestures, not raw touches).
///
/// The framework is loaded with `dlopen` at runtime, never linked. If it (or any
/// symbol) is missing on a future macOS, `cmt_start` simply returns false and the
/// caller disables the feature — nothing else in the app is affected.

/// One finger contact, reduced to just what the pinch detector needs.
typedef struct {
    int fingerID;   ///< stable identifier for this finger while it stays down
    int state;      ///< MTTouchState (4 == touching)
    float x;        ///< normalized position across the pad, 0…1
    float y;        ///< normalized position across the pad, 0…1
} CMTFinger;

/// Invoked on the multitouch thread once per frame with all current contacts.
typedef void (*CMTFrameCallback)(const CMTFinger *fingers, int count);

/// Starts listening on every multitouch device. Returns true only if the private
/// framework loaded and at least one device started. No-op (returns true) if
/// already started.
bool cmt_start(CMTFrameCallback callback);

/// Stops listening and releases the devices. Safe to call when not started.
void cmt_stop(void);

#endif /* CMULTITOUCH_H */
