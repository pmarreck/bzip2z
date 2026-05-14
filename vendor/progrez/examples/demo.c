/* progrez demo — exercises the C FFI. */

#define _DEFAULT_SOURCE  /* usleep() on glibc with -std=c11 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#define SLEEP_MS(ms) Sleep(ms)
#else
#include <unistd.h>
#define SLEEP_MS(ms) usleep((ms) * 1000)
#endif

#include "progrez.h"

int main(void) {
    /* Phase 1: Indeterminate (scanning) */
    progrez_ctx *ctx = progrez_create("Scanning");
    if (!ctx) {
        fprintf(stderr, "Failed to create progress context\n");
        return 1;
    }
    progrez_set_identity(ctx, "progrez-demo", "demo directory scan");
    progrez_set_indeterminate(ctx);
    progrez_set_sparkline(ctx, 1);
    progrez_set_notify(ctx, 1);  /* enable notifications for demo */

    for (uint64_t i = 0; i < 70; i++) {
        progrez_update(ctx, i + 1, (i + 1) * 150000);
        SLEEP_MS(75);
    }

    /* Update label before switching to determinate mode */
    progrez_set_label(ctx, "Processing");

    /* Phase 2: Determinate (processing) */
    uint64_t total_files = 200;
    uint64_t total_bytes = total_files * 150000;  /* ~30 MB */
    progrez_set_determinate(ctx, total_files, total_bytes);

    for (uint64_t i = 0; i < total_files; i++) {
        progrez_update(ctx, i + 1, (i + 1) * 150000);
        /* Vary the sleep to produce interesting sparkline */
        SLEEP_MS(30 + (i % 7) * 8);
    }

    progrez_finish(ctx);
    progrez_destroy(ctx);

    return 0;
}
