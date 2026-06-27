#include "CSMC.h"
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <math.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>

// CPU temperature, computed exactly like the `hot` app (macmade/Hot):
//   1. Gather every temperature sensor — IOHID (pACC/eACC/PMU…) + SMC "T*" keys.
//   2. If any IOHID sensor is a CPU cluster ("pACC"/"eACC", on M1/M2), use those.
//   3. Otherwise (newer Apple Silicon names sensors "PMU tdie…", Intel, etc.)
//      use ALL sensors except calibration ones: names ending in "tcal" and any
//      sensor whose value equals the tcal value.
//   4. Report the hottest of the chosen set (hot's default display mode).

#define CSMC_MAX_SENSORS 512

typedef struct { char name[64]; double value; int isCPU; } Sensor;

// ---------------------------------------------------------------------------
// IOHID temperature sensors (private IOHIDEventSystemClient API, via dlsym).
// ---------------------------------------------------------------------------

typedef CFTypeRef  (*fnCreate)(CFAllocatorRef);
typedef void       (*fnSetMatching)(CFTypeRef, CFDictionaryRef);
typedef CFArrayRef (*fnCopyServices)(CFTypeRef);
typedef CFTypeRef  (*fnCopyProperty)(CFTypeRef, CFStringRef);
typedef CFTypeRef  (*fnCopyEvent)(CFTypeRef, int64_t, int32_t, int64_t);
typedef double     (*fnGetFloat)(CFTypeRef, int32_t);

#define kIOHIDTemperatureEventType 15
#define kIOHIDTemperatureField     (kIOHIDTemperatureEventType << 16)

static CFTypeRef g_hidClient = NULL;
static fnCopyServices g_copyServices = NULL;
static fnCopyProperty g_copyProperty = NULL;
static fnCopyEvent    g_copyEvent = NULL;
static fnGetFloat     g_getFloat = NULL;
static int g_hidResolved = 0;   // 0 = untried, 1 = ready, -1 = unavailable

static int resolveHID(void) {
    if (g_hidResolved) return g_hidResolved > 0;
    g_hidResolved = -1;

    fnCreate create        = (fnCreate)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    fnSetMatching setMatch = (fnSetMatching)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientSetMatching");
    g_copyServices = (fnCopyServices)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCopyServices");
    g_copyProperty = (fnCopyProperty)dlsym(RTLD_DEFAULT, "IOHIDServiceClientCopyProperty");
    g_copyEvent    = (fnCopyEvent)dlsym(RTLD_DEFAULT, "IOHIDServiceClientCopyEvent");
    g_getFloat     = (fnGetFloat)dlsym(RTLD_DEFAULT, "IOHIDEventGetFloatValue");
    if (!create || !setMatch || !g_copyServices || !g_copyProperty || !g_copyEvent || !g_getFloat) return 0;

    g_hidClient = create(kCFAllocatorDefault);
    if (!g_hidClient) return 0;

    int page = 0xff00, usage = 5;   // AppleVendor temperature sensors
    CFNumberRef pageN  = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef usageN = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *vals[] = { pageN, usageN };
    CFDictionaryRef match = CFDictionaryCreate(NULL, keys, vals, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    setMatch(g_hidClient, match);
    CFRelease(match); CFRelease(pageN); CFRelease(usageN);

    g_hidResolved = 1;
    return 1;
}

static void gatherIOHID(Sensor *out, int *count, int cap) {
    if (!resolveHID()) return;
    CFArrayRef services = g_copyServices(g_hidClient);
    if (!services) return;

    CFIndex n = CFArrayGetCount(services);
    for (CFIndex i = 0; i < n && *count < cap; i++) {
        CFTypeRef svc = CFArrayGetValueAtIndex(services, i);
        CFTypeRef nameRef = g_copyProperty(svc, CFSTR("Product"));
        if (!nameRef) continue;
        char name[64] = {0};
        if (CFGetTypeID(nameRef) == CFStringGetTypeID())
            CFStringGetCString((CFStringRef)nameRef, name, sizeof(name), kCFStringEncodingUTF8);
        CFRelease(nameRef);

        CFTypeRef ev = g_copyEvent(svc, kIOHIDTemperatureEventType, 0, 0);
        if (!ev) continue;
        double t = g_getFloat(ev, kIOHIDTemperatureField);
        CFRelease(ev);
        if (t <= 1.0 || t >= 120.0) continue;

        Sensor *s = &out[(*count)++];
        strncpy(s->name, name, sizeof(s->name) - 1);
        s->name[sizeof(s->name) - 1] = 0;
        s->value = t;
        s->isCPU = (strncmp(name, "pACC", 4) == 0 || strncmp(name, "eACC", 4) == 0);
    }
    CFRelease(services);
}

// ---------------------------------------------------------------------------
// SMC keys (IOKit). Used to round out the sensor set (and the only source on
// Intel Macs).
// ---------------------------------------------------------------------------

typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimitData;
typedef struct { uint32_t dataSize; uint32_t dataType; char dataAttributes; } SMCKeyInfoData;
typedef struct {
    uint32_t key; SMCVersion vers; SMCPLimitData pLimitData; SMCKeyInfoData keyInfo;
    char result; char status; char data8; uint32_t data32; uint8_t bytes[32];
} SMCParamStruct;

enum { kSMCHandleYPCEvent = 2, kSMCReadKey = 5, kSMCGetKeyInfo = 9, kSMCGetKeyFromIndex = 8 };

static io_connect_t g_conn = 0;
static int g_opened = 0;

static uint32_t pack(const char *s) {
    return ((uint32_t)s[0] << 24) | ((uint32_t)s[1] << 16) | ((uint32_t)s[2] << 8) | (uint32_t)s[3];
}

static int openSMC(void) {
    if (g_opened) return g_conn != 0;
    g_opened = 1;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return 0;
    kern_return_t r = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    if (r != kIOReturnSuccess) { g_conn = 0; return 0; }
    return 1;
}

static kern_return_t call(SMCParamStruct *in, SMCParamStruct *out) {
    size_t inSize = sizeof(SMCParamStruct), outSize = sizeof(SMCParamStruct);
    return IOConnectCallStructMethod(g_conn, kSMCHandleYPCEvent, in, inSize, out, &outSize);
}

static int readTemp(uint32_t key, double *temp) {
    SMCParamStruct in, out;
    memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out));
    in.key = key; in.data8 = kSMCGetKeyInfo;
    if (call(&in, &out) != kIOReturnSuccess || out.result != 0) return 0;
    uint32_t type = out.keyInfo.dataType, size = out.keyInfo.dataSize;

    memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out));
    in.key = key; in.keyInfo.dataSize = size; in.data8 = kSMCReadKey;
    if (call(&in, &out) != kIOReturnSuccess || out.result != 0) return 0;

    if (type == pack("flt ") && size == 4) { float f; memcpy(&f, out.bytes, 4); *temp = f; return 1; }
    if (type == pack("sp78") && size >= 2) { int8_t hi = (int8_t)out.bytes[0]; *temp = hi + out.bytes[1] / 256.0; return 1; }
    return 0;
}

static void gatherSMC(Sensor *out, int *count, int cap) {
    if (!openSMC()) return;

    SMCParamStruct in, out2;
    memset(&in, 0, sizeof(in)); memset(&out2, 0, sizeof(out2));
    in.key = pack("#KEY"); in.data8 = kSMCGetKeyInfo;
    if (call(&in, &out2) != kIOReturnSuccess) return;
    memset(&in, 0, sizeof(in)); memset(&out2, 0, sizeof(out2));
    in.key = pack("#KEY"); in.keyInfo.dataSize = 4; in.data8 = kSMCReadKey;
    if (call(&in, &out2) != kIOReturnSuccess) return;
    uint32_t total = ((uint32_t)out2.bytes[0] << 24) | ((uint32_t)out2.bytes[1] << 16) |
                     ((uint32_t)out2.bytes[2] << 8)  | (uint32_t)out2.bytes[3];

    for (uint32_t i = 0; i < total && *count < cap; i++) {
        memset(&in, 0, sizeof(in)); memset(&out2, 0, sizeof(out2));
        in.data8 = kSMCGetKeyFromIndex; in.data32 = i;
        if (call(&in, &out2) != kIOReturnSuccess) continue;
        uint32_t key = out2.key;
        if (((key >> 24) & 0xFF) != 'T') continue;   // temperature keys only
        double t;
        if (!readTemp(key, &t) || t <= 1.0 || t >= 120.0) continue;

        Sensor *s = &out[(*count)++];
        s->name[0] = (key >> 24) & 0xFF; s->name[1] = (key >> 16) & 0xFF;
        s->name[2] = (key >> 8) & 0xFF;  s->name[3] = key & 0xFF; s->name[4] = 0;
        s->value = t;
        s->isCPU = 0;
    }
}

static int endsWithTcal(const char *name) {
    size_t l = strlen(name);
    return l >= 4 && strcasecmp(name + l - 4, "tcal") == 0;
}

double csmc_cpu_temperature(void) {
    Sensor sensors[CSMC_MAX_SENSORS];
    int count = 0;
    gatherIOHID(sensors, &count, CSMC_MAX_SENSORS);
    gatherSMC(sensors, &count, CSMC_MAX_SENSORS);
    if (count == 0) return -1;

    // If there are dedicated CPU-cluster sensors (M1/M2), use only those.
    int haveCPU = 0;
    for (int i = 0; i < count; i++) if (sensors[i].isCPU) { haveCPU = 1; break; }

    // Calibration value to exclude (a sensor named "*tcal"), used by the
    // all-sensors fallback the way `hot` does.
    double tcal = -1;
    for (int i = 0; i < count; i++) if (endsWithTcal(sensors[i].name)) { tcal = sensors[i].value; break; }

    double maxT = -1;
    for (int i = 0; i < count; i++) {
        if (haveCPU) {
            if (!sensors[i].isCPU) continue;
        } else {
            if (endsWithTcal(sensors[i].name)) continue;
            if (tcal > 0 && (int)ceil(tcal * 100) == (int)ceil(sensors[i].value * 100)) continue;
        }
        if (sensors[i].value > maxT) maxT = sensors[i].value;
    }
    return maxT;
}

void csmc_close(void) {
    if (g_conn) { IOServiceClose(g_conn); g_conn = 0; }
    g_opened = 0;
}
