/* Full-size wallpaper decoding straight from libjpeg(-turbo), libpng and libwebp.
 *
 * GdkPixbuf 2.44 decodes through sandboxed glycin loader processes: every
 * wallpaper (and every Appearance strip thumbnail) would start one. Here the
 * three formats a wallpaper can be (png, jpg, webp) decode in-process, at full
 * quality (accurate DCT, fancy chroma upsampling), whatever their variant:
 * palette, grayscale, 16-bit and interlaced PNG, progressive and CMYK JPEG.
 *
 * Two steps, so the caller allocates the raster with its own allocator:
 * `wc_probe` reads the header, `wc_decode` fills a `w * h` buffer. The format
 * is sniffed from the content, never the file name. Output pixels are
 * premultiplied 0xAARRGGBB (Cairo ARGB32), which needs a little-endian host.
 * Animated WebP and anything else is reported unsupported. Thread-safe: no
 * state is shared between calls. No GLib headers here: see AGENTS.md. */
#ifndef REDIWM_WALLPAPER_CODEC_H
#define REDIWM_WALLPAPER_CODEC_H

#include <stddef.h>
#include <stdint.h>

enum {
    WC_OK = 0,
    WC_UNSUPPORTED = 1, /* not a PNG, JPEG or still WebP */
    WC_TOO_LARGE = 2,   /* dimensions the format allows but an int cannot hold */
    WC_CORRUPT = 3,
    WC_NOMEM = 4,
};

typedef struct {
    int w, h;
} wc_info;

/* The image's size, from its header alone. */
int wc_probe(const uint8_t *data, size_t len, wc_info *info);

/* Decodes into `pixels`, which holds `w * h` words and must match `wc_probe`'s
 * size. `*has_alpha` is set when any pixel is not opaque. */
int wc_decode(const uint8_t *data, size_t len, uint32_t *pixels, int w, int h, int *has_alpha);

#endif
