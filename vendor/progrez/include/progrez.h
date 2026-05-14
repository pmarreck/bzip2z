#ifndef PROGREZ_H
#define PROGREZ_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct progrez_ctx progrez_ctx;

progrez_ctx *progrez_create(const char *label);
void progrez_destroy(progrez_ctx *ctx);
void progrez_set_identity(progrez_ctx *ctx, const char *caller_name, const char *context_name);
void progrez_set_indeterminate(progrez_ctx *ctx);
void progrez_set_determinate(progrez_ctx *ctx, uint64_t files_total, uint64_t bytes_total);
void progrez_set_guess(progrez_ctx *ctx, uint64_t guess_files, uint64_t guess_bytes);
void progrez_update(progrez_ctx *ctx, uint64_t files_processed, uint64_t bytes_processed);
void progrez_finish(progrez_ctx *ctx);

/* Render progress bar into caller's buffer (for scroll-region / custom positioning).
 * Returns number of bytes written (not null-terminated).
 * First call enters manual mode — the render thread will not be spawned.
 * Caller drives rendering at their own cadence. */
size_t progrez_render_line(progrez_ctx *ctx, char *buf, size_t buf_size, uint16_t width);

void progrez_set_interval_ms(progrez_ctx *ctx, uint32_t ms);

/* Set a 3-stop gradient (start -> mid -> end). RGB values 0-255. */
void progrez_set_gradient(progrez_ctx *ctx,
                          uint8_t start_r, uint8_t start_g, uint8_t start_b,
                          uint8_t mid_r,   uint8_t mid_g,   uint8_t mid_b,
                          uint8_t end_r,   uint8_t end_g,   uint8_t end_b);

/* Set a 2-stop gradient (start -> end, linear interpolation). */
void progrez_set_gradient_2(progrez_ctx *ctx,
                            uint8_t start_r, uint8_t start_g, uint8_t start_b,
                            uint8_t end_r,   uint8_t end_g,   uint8_t end_b);

/* Enable or disable throughput sparkline display. */
void progrez_set_sparkline(progrez_ctx *ctx, _Bool enabled);

/* Update the display label mid-operation. */
void progrez_set_label(progrez_ctx *ctx, const char *label);

/* Notification configuration */
void progrez_set_notify(progrez_ctx *ctx, _Bool enabled);
void progrez_set_notify_after(progrez_ctx *ctx, uint32_t seconds);

typedef void (*progrez_notify_fn)(const char *message, void *userdata);
void progrez_set_notify_callback(progrez_ctx *ctx, progrez_notify_fn fn, void *userdata);

#ifdef __cplusplus
}
#endif

#endif /* PROGREZ_H */
