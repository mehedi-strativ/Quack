#include "CMultitouch.h"
#include <dlfcn.h>
#include <CoreFoundation/CoreFoundation.h>

// Layout of a single touch as exposed by MultitouchSupport. This is the
// long-standing community-reverse-engineered "Finger" struct (Erica Sadun et
// al.); the field offsets must match exactly or the readout is garbage. We only
// read `state` and `normalized.position`.
typedef struct { float x, y; } mtPoint;
typedef struct { mtPoint position, velocity; } mtReadout;
typedef struct {
    int frame;
    double timestamp;
    int identifier;
    int state;
    int foo3;
    int foo4;
    mtReadout normalized;
    float size;
    int zero1;
    float angle;
    float majorAxis;
    float minorAxis;
    mtReadout mm;
    int zero2[2];
    float zDensity;
} Finger;

typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(int, Finger *, int, double, int);
typedef CFMutableArrayRef (*MTDeviceCreateListFn)(void);
typedef void (*MTRegisterContactFrameCallbackFn)(MTDeviceRef, MTContactCallbackFunction);
typedef void (*MTUnregisterContactFrameCallbackFn)(MTDeviceRef, MTContactCallbackFunction);
typedef void (*MTDeviceStartFn)(MTDeviceRef, int);
typedef void (*MTDeviceStopFn)(MTDeviceRef);

static void *g_handle = NULL;
static CFMutableArrayRef g_devices = NULL;
static CMTFrameCallback g_cb = NULL;
static MTUnregisterContactFrameCallbackFn g_unreg = NULL;
static MTDeviceStopFn g_stop = NULL;
static bool g_running = false;

#define CMT_MAX_FINGERS 32

static int cmt_contact_callback(int device, Finger *data, int nFingers, double timestamp, int frame) {
    (void)device; (void)timestamp; (void)frame;
    CMTFrameCallback cb = g_cb;
    if (!cb) return 0;

    CMTFinger out[CMT_MAX_FINGERS];
    int n = nFingers;
    if (n < 0) n = 0;
    if (n > CMT_MAX_FINGERS) n = CMT_MAX_FINGERS;
    for (int i = 0; i < n; i++) {
        out[i].fingerID = data[i].identifier;
        out[i].state = data[i].state;
        out[i].x = data[i].normalized.position.x;
        out[i].y = data[i].normalized.position.y;
    }
    cb(out, n);
    return 0;
}

bool cmt_start(CMTFrameCallback callback) {
    if (g_running) return true;

    g_handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY);
    if (!g_handle) return false;

    MTDeviceCreateListFn createList =
        (MTDeviceCreateListFn)dlsym(g_handle, "MTDeviceCreateList");
    MTRegisterContactFrameCallbackFn reg =
        (MTRegisterContactFrameCallbackFn)dlsym(g_handle, "MTRegisterContactFrameCallback");
    MTDeviceStartFn start =
        (MTDeviceStartFn)dlsym(g_handle, "MTDeviceStart");
    g_unreg = (MTUnregisterContactFrameCallbackFn)dlsym(g_handle, "MTUnregisterContactFrameCallback");
    g_stop = (MTDeviceStopFn)dlsym(g_handle, "MTDeviceStop");

    if (!createList || !reg || !start) { cmt_stop(); return false; }

    g_cb = callback;
    g_devices = createList();
    if (!g_devices) { cmt_stop(); return false; }

    CFIndex count = CFArrayGetCount(g_devices);
    if (count == 0) { cmt_stop(); return false; }

    for (CFIndex i = 0; i < count; i++) {
        MTDeviceRef dev = (MTDeviceRef)CFArrayGetValueAtIndex(g_devices, i);
        reg(dev, cmt_contact_callback);
        start(dev, 0);
    }
    g_running = true;
    return true;
}

void cmt_stop(void) {
    if (g_devices) {
        CFIndex count = CFArrayGetCount(g_devices);
        for (CFIndex i = 0; i < count; i++) {
            MTDeviceRef dev = (MTDeviceRef)CFArrayGetValueAtIndex(g_devices, i);
            if (g_stop) g_stop(dev);
            if (g_unreg) g_unreg(dev, cmt_contact_callback);
        }
        CFRelease(g_devices);
        g_devices = NULL;
    }
    g_cb = NULL;
    g_running = false;
    // Deliberately keep g_handle loaded: dlclose-ing a private framework
    // mid-process can be unsafe, and leaving it mapped is harmless.
}
