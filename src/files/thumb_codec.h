/* Thumbnail decoding straight from libjpeg(-turbo) and libpng.
 *
 * GdkPixbuf 2.44 routes these formats through sandboxed glycin loader
 * processes and ignores scaled-decode hints, so a 12 MP JPEG costs ~150 ms.
 * Here JPEG decodes at 1/2, 1/4 or 1/8 size inside the DCT and PNG streams one
 * row at a time into an area-averaging downscaler, so neither ever holds the
 * full raster. Callers fall back to GdkPixbuf for anything reported as
 * unsupported.
 *
 * Output pixels are premultiplied 0xAARRGGBB (Cairo ARGB32). No GLib headers
 * here: see AGENTS.md, "Build and platform gotchas". */
#ifndef REDIWM_THUMB_CODEC_H
#define REDIWM_THUMB_CODEC_H

#include <stddef.h>
#include <stdint.h>

enum {
    TC_OK = 0,
    TC_UNSUPPORTED = 1, /* not this codec's kind of file; try another decoder */
    TC_TOO_LARGE = 2,   /* dimensions beyond the caller's pixel budget */
    TC_CORRUPT = 3,
    TC_NOMEM = 4,
};

typedef struct {
    uint32_t *pixels; /* malloc'd, w * h, release with tc_free */
    int w, h;         /* thumbnail size, fitted inside the requested box */
    int src_w, src_h; /* the file's own image size */
    int orientation;  /* EXIF orientation 1..8 (JPEG); 1 when absent */
    int64_t thumb_mtime; /* freedesktop Thumb::MTime text, or -1 */
    int64_t thumb_size;  /* freedesktop Thumb::Size text, or -1 */
} tc_image;

/* `box` is the longest edge of the result. `max_pixels` bounds the source. */
int tc_jpeg(const uint8_t *data, size_t len, int box, int64_t max_pixels, tc_image *out);
int tc_png(const uint8_t *data, size_t len, int box, int64_t max_pixels, tc_image *out);
void tc_free(tc_image *image);

/* Writes `pixels` (premultiplied ARGB32) as an RGBA PNG with the freedesktop
 * Thumb::URI, Thumb::MTime and Thumb::Size text chunks, mode 0600. Fails if
 * `path` exists. Returns 0 on success. */
int tc_png_write(const char *path, const uint32_t *pixels, int w, int h, const char *uri, int64_t mtime, int64_t size);

#endif
