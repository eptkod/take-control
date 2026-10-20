#include "TakeControl.h"
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <string.h>

// ---- IOHID temperature sensors (private but stable API) ----
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);

#define kHIDPage_AppleVendor 0xff00
#define kHIDUsage_TemperatureSensor 5
#define kIOHIDEventTypeTemperature 15

int hid_cpu_temps(float *out, int max) {
    static IOHIDEventSystemClientRef client = NULL;
    static CFArrayRef services = NULL;
    if (!client) {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!client) return 0;
        int page = kHIDPage_AppleVendor, usage = kHIDUsage_TemperatureSensor;
        CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page);
        CFNumberRef u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
        const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
        const void *vals[] = { p, u };
        CFDictionaryRef m = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        IOHIDEventSystemClientSetMatching(client, m);
        CFRelease(m); CFRelease(p); CFRelease(u);
        // Keep only CPU die sensors.
        CFArrayRef all = IOHIDEventSystemClientCopyServices(client);
        CFMutableArrayRef cpu = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        if (all) {
            for (CFIndex i = 0; i < CFArrayGetCount(all); i++) {
                IOHIDServiceClientRef s = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(all, i);
                CFStringRef name = IOHIDServiceClientCopyProperty(s, CFSTR("Product"));
                if (!name) continue;
                char buf[64];
                if (CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8) &&
                    (strstr(buf, "tdie") || strstr(buf, "eACC") || strstr(buf, "pACC")))
                    CFArrayAppendValue(cpu, s);
                CFRelease(name);
            }
            CFRelease(all);
        }
        services = cpu;
    }
    int n = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(services) && n < max; i++) {
        IOHIDEventRef e = IOHIDServiceClientCopyEvent((IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i),
                                                      kIOHIDEventTypeTemperature, 0, 0);
        if (!e) continue;
        double t = IOHIDEventGetFloatValue(e, kIOHIDEventTypeTemperature << 16);
        CFRelease(e);
        if (t > 0 && t < 150) out[n++] = (float)t;
    }
    return n;
}
