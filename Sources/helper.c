// tc-helper: the only privileged part of Take Control.
//
// Runs setuid root, spawned by the app with a pipe on stdin. Each line is either
// a fan level in per mille (0 = each fan's min RPM, 1000 = max) or "auto".
// When stdin closes for any reason (the app quit, crashed or was killed) or a
// termination signal arrives, it restores automatic fan control and exits.
#include "TakeControl.h"
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int fans = 0;
static int level = -1;            // -1 = automatic
static volatile sig_atomic_t quit = 0;

static void key(char out[5], int fan, char a, char b) { out[0] = 'F'; out[1] = '0' + fan; out[2] = a; out[3] = b; out[4] = 0; }

static bool has_ftst(void) {
    static int cached = -1;
    if (cached < 0) { char t[5]; cached = smc_key_type("Ftst", t, NULL); }
    return cached;
}

static void set_auto(void) {
    char k[5];
    for (int f = 0; f < fans; f++) { key(k, f, 'M', 'd'); smc_write_float(k, 0); }
    if (has_ftst()) smc_write_float("Ftst", 0);
}

static void apply(void) {
    if (level < 0) { set_auto(); return; }
    if (has_ftst()) smc_write_float("Ftst", 1);
    char k[5];
    for (int f = 0; f < fans; f++) {
        float mn = 0, mx = 0, md = 0;
        key(k, f, 'M', 'n'); smc_read_float(k, &mn);
        key(k, f, 'M', 'x'); smc_read_float(k, &mx);
        if (mx <= mn) continue;
        // thermalmonitord may briefly reject the mode change after Ftst is set.
        key(k, f, 'M', 'd');
        for (int i = 0; i < 30 && !(smc_read_float(k, &md) && md == 1); i++) {
            smc_write_float(k, 1);
            usleep(100000);
        }
        key(k, f, 'T', 'g');
        smc_write_float(k, mn + (mx - mn) * level / 1000.0f);
    }
}

// Re-applies the manual mode if the system took it back (for example after sleep).
static void reassert(void) {
    if (level < 0) return;
    char k[5]; float md = 0;
    key(k, 0, 'M', 'd');
    if (smc_read_float(k, &md) && md != 1) apply();
}

static void on_signal(int sig) { (void)sig; quit = 1; }

int main(void) {
    if (geteuid() != 0 || setuid(0) != 0) { fputs("tc-helper: must run as root\n", stderr); return 1; }
    if (smc_open() != 0) { fputs("tc-helper: cannot open AppleSMC\n", stderr); return 1; }

    float n = 0;
    smc_read_float("FNum", &n);
    fans = n > 0 && n < 10 ? (int)n : 0;

    struct sigaction sa = { .sa_handler = on_signal };
    sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);  sigaction(SIGQUIT, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    char buf[64]; size_t len = 0;
    while (!quit) {
        struct pollfd p = { .fd = STDIN_FILENO, .events = POLLIN };
        int r = poll(&p, 1, 5000);
        if (r == 0) { reassert(); continue; }
        if (r < 0) continue;                       // EINTR: loop re-checks quit
        ssize_t got = read(STDIN_FILENO, buf + len, sizeof buf - 1 - len);
        if (got <= 0) break;                       // app is gone
        len += (size_t)got; buf[len] = 0;
        char *nl;
        while ((nl = strchr(buf, '\n'))) {
            *nl = 0;
            if (!strcmp(buf, "auto")) level = -1;
            else {
                char *end; long v = strtol(buf, &end, 10);
                if (end != buf && *end == 0) level = v < 0 ? 0 : v > 1000 ? 1000 : (int)v;
            }
            apply();
            len -= (size_t)(nl + 1 - buf);
            memmove(buf, nl + 1, len + 1);
        }
        if (len == sizeof buf - 1) len = 0;        // garbage line, drop it
    }
    set_auto();
    smc_close();
    return 0;
}
