// Take Control: minimal AppleSMC and HID sensor access for Apple Silicon.
#ifndef TC_SMC_H
#define TC_SMC_H
#include <stdint.h>
#include <stdbool.h>

int  smc_open(void);
void smc_close(void);
// Reads a key as a float (handles flt, fpe2, ui8/16/32, sp78). Returns false on failure.
bool smc_read_float(const char *key, float *out);
// Writes raw bytes to a key (needs root).
bool smc_write(const char *key, const uint8_t *bytes, uint32_t size);
// Writes a key using its native type (flt or ui8). Needs root.
bool smc_write_float(const char *key, float value);
// Key type and size; false if the key does not exist.
bool smc_key_type(const char *key, char out[5], uint32_t *size);

// CPU temperatures through the IOHID event system. Fills up to max values, returns count.
int hid_cpu_temps(float *out, int max);

// Private CoreGraphics (WindowServer) calls: blur whatever is behind a window.
int32_t CGSMainConnectionID(void);
int32_t CGSSetWindowBackgroundBlurRadius(int32_t cid, int32_t wid, int32_t radius);
#endif
