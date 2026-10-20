#include "TakeControl.h"
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <string.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, mem; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key; SMCVers vers; SMCPLimit pLimit; SMCKeyInfo info;
    uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32];
} SMCParam;

enum { kSMCUserClient = 2, kCmdRead = 5, kCmdWrite = 6, kCmdInfo = 9 };

static io_connect_t conn = 0;

static uint32_t fourcc(const char *s) {
    return ((uint32_t)s[0] << 24) | ((uint32_t)s[1] << 16) | ((uint32_t)s[2] << 8) | (uint32_t)s[3];
}
static void unfourcc(uint32_t v, char out[5]) {
    out[0] = v >> 24; out[1] = v >> 16; out[2] = v >> 8; out[3] = v; out[4] = 0;
}

int smc_open(void) {
    if (conn) return 0;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    return kr == KERN_SUCCESS ? 0 : -1;
}

void smc_close(void) { if (conn) { IOServiceClose(conn); conn = 0; } }

static bool call(SMCParam *in, SMCParam *out) {
    size_t sz = sizeof(SMCParam);
    memset(out, 0, sz);
    kern_return_t kr = IOConnectCallStructMethod(conn, kSMCUserClient, in, sz, out, &sz);
    return kr == KERN_SUCCESS && out->result == 0;
}

static bool info(uint32_t key, SMCKeyInfo *ki) {
    SMCParam in = {0}, out;
    in.key = key; in.data8 = kCmdInfo;
    if (!call(&in, &out)) return false;
    *ki = out.info;
    return true;
}

bool smc_key_type(const char *key, char out[5], uint32_t *size) {
    SMCKeyInfo ki;
    if (!conn || !info(fourcc(key), &ki)) return false;
    unfourcc(ki.dataType, out);
    if (size) *size = ki.dataSize;
    return true;
}

static bool read_raw(const char *key, SMCKeyInfo *ki, uint8_t bytes[32]) {
    if (!conn) return false;
    uint32_t k = fourcc(key);
    if (!info(k, ki)) return false;
    SMCParam in = {0}, out;
    in.key = k; in.info.dataSize = ki->dataSize; in.data8 = kCmdRead;
    if (!call(&in, &out)) return false;
    memcpy(bytes, out.bytes, 32);
    return true;
}

bool smc_read_float(const char *key, float *v) {
    SMCKeyInfo ki; uint8_t b[32];
    if (!read_raw(key, &ki, b)) return false;
    char t[5]; unfourcc(ki.dataType, t);
    if (!strcmp(t, "flt ") && ki.dataSize == 4) { memcpy(v, b, 4); return true; }
    if (!strcmp(t, "fpe2") && ki.dataSize == 2) { *v = ((b[0] << 8) | b[1]) / 4.0f; return true; }
    if (!strcmp(t, "sp78") && ki.dataSize == 2) { *v = (int16_t)((b[0] << 8) | b[1]) / 256.0f; return true; }
    if (!strcmp(t, "ui8 ")) { *v = b[0]; return true; }
    if (!strcmp(t, "ui16")) { *v = (b[0] << 8) | b[1]; return true; }
    if (!strcmp(t, "ui32")) { *v = ((uint32_t)b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]; return true; }
    return false;
}

bool smc_write(const char *key, const uint8_t *bytes, uint32_t size) {
    if (!conn || size > 32) return false;
    SMCParam in = {0}, out;
    in.key = fourcc(key); in.data8 = kCmdWrite; in.info.dataSize = size;
    memcpy(in.bytes, bytes, size);
    return call(&in, &out);
}

bool smc_write_float(const char *key, float value) {
    SMCKeyInfo ki;
    if (!conn || !info(fourcc(key), &ki)) return false;
    char t[5]; unfourcc(ki.dataType, t);
    uint8_t b[4] = {0};
    if (!strcmp(t, "flt ") && ki.dataSize == 4) { memcpy(b, &value, 4); return smc_write(key, b, 4); }
    if (!strcmp(t, "ui8 ") && ki.dataSize == 1) { b[0] = (uint8_t)value; return smc_write(key, b, 1); }
    if (!strcmp(t, "fpe2") && ki.dataSize == 2) {
        uint16_t f = (uint16_t)(value * 4); b[0] = f >> 8; b[1] = f; return smc_write(key, b, 2);
    }
    return false;
}
