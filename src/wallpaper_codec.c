#define _GNU_SOURCE
#include "wallpaper_codec.h"

#include <limits.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* After <stdio.h>: jpeglib.h uses FILE without including it. */
#include <jpeglib.h>
#include <png.h>
#include <webp/decode.h>

#if !defined(__BYTE_ORDER__) || __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "pixels are decoded as B, G, R, A bytes, which are 0xAARRGGBB words only on a little-endian host"
#endif

enum { K_NONE, K_PNG, K_JPEG, K_WEBP };

/* The format by its signature: a misnamed file still loads. */
static int sniff(const uint8_t *d, size_t n) {
    if (n >= 8 && png_sig_cmp(d, 0, 8) == 0) return K_PNG;
    if (n >= 3 && d[0] == 0xff && d[1] == 0xd8 && d[2] == 0xff) return K_JPEG;
    if (n >= 12 && memcmp(d, "RIFF", 4) == 0 && memcmp(d + 8, "WEBP", 4) == 0) return K_WEBP;
    return K_NONE;
}

/* Straight B, G, R, A words to premultiplied, rounded as png.zig does.
 * Returns whether any pixel is not opaque. */
static int premultiply(uint32_t *px, size_t n) {
    int translucent = 0;
    for (size_t i = 0; i < n; i++) {
        uint32_t p = px[i], a = p >> 24;
        if (a == 255) continue;
        translucent = 1;
        if (a == 0) {
            px[i] = 0;
            continue;
        }
        uint32_t r = (((p >> 16) & 0xff) * a + 127) / 255;
        uint32_t g = (((p >> 8) & 0xff) * a + 127) / 255;
        uint32_t b = ((p & 0xff) * a + 127) / 255;
        px[i] = a << 24 | r << 16 | g << 8 | b;
    }
    return translucent;
}

/* ---- JPEG --------------------------------------------------------------- */

typedef struct {
    struct jpeg_error_mgr pub;
    jmp_buf jump;
} jpeg_errors;

static void jpeg_fail(j_common_ptr cinfo) {
    longjmp(((jpeg_errors *)cinfo->err)->jump, 1);
}

static void jpeg_quiet(j_common_ptr cinfo, int level) {
    (void)cinfo;
    (void)level;
}

static void jpeg_silent(j_common_ptr cinfo) {
    (void)cinfo;
}

/* Four ink channels to opaque RGB. Adobe writes them inverted (255 is no
 * ink), so there the channels already are intensities. */
static void cmyk_row(const uint8_t *s, uint32_t *dst, int w, int inverted) {
    for (int x = 0; x < w; x++, s += 4) {
        uint32_t c = s[0], m = s[1], y = s[2], k = s[3];
        if (!inverted) {
            c = 255 - c;
            m = 255 - m;
            y = 255 - y;
            k = 255 - k;
        }
        uint32_t r = (c * k + 127) / 255, g = (m * k + 127) / 255, b = (y * k + 127) / 255;
        dst[x] = 0xff000000u | r << 16 | g << 8 | b;
    }
}

/* Reads the header into `size`, or, when `pixels` is set, decodes into it. */
static int jpeg_run(const uint8_t *data, size_t len, uint32_t *pixels, int w, int h, wc_info *size) {
    struct jpeg_decompress_struct cinfo;
    jpeg_errors errors;
    unsigned char *volatile row = NULL;
    cinfo.err = jpeg_std_error(&errors.pub);
    errors.pub.error_exit = jpeg_fail;
    errors.pub.emit_message = jpeg_quiet;
    errors.pub.output_message = jpeg_silent;
    if (setjmp(errors.jump)) {
        jpeg_destroy_decompress(&cinfo);
        free(row);
        return WC_CORRUPT;
    }
    jpeg_create_decompress(&cinfo);
    jpeg_mem_src(&cinfo, data, (unsigned long)len);
    jpeg_read_header(&cinfo, TRUE);
    if (cinfo.image_width == 0 || cinfo.image_height == 0 || cinfo.image_width > INT_MAX || cinfo.image_height > INT_MAX) {
        jpeg_destroy_decompress(&cinfo);
        return WC_CORRUPT;
    }
    if (!pixels) {
        size->w = (int)cinfo.image_width;
        size->h = (int)cinfo.image_height;
        jpeg_destroy_decompress(&cinfo);
        return WC_OK;
    }
    if ((int)cinfo.image_width != w || (int)cinfo.image_height != h) {
        jpeg_destroy_decompress(&cinfo);
        return WC_CORRUPT;
    }
    int cmyk = cinfo.jpeg_color_space == JCS_CMYK || cinfo.jpeg_color_space == JCS_YCCK;
    int inverted = cinfo.saw_Adobe_marker;
    /* Gray and YCbCr become opaque BGRA in the decoder itself. The default
     * (accurate) DCT and fancy chroma upsampling stay: this is a wallpaper. */
    cinfo.out_color_space = cmyk ? JCS_CMYK : JCS_EXT_BGRA;
    jpeg_start_decompress(&cinfo);
    if (cinfo.output_components != 4 || cinfo.output_width != (unsigned)w) {
        jpeg_destroy_decompress(&cinfo);
        return WC_CORRUPT;
    }
    if (cmyk) {
        row = malloc((size_t)w * 4);
        if (!row) {
            jpeg_destroy_decompress(&cinfo);
            return WC_NOMEM;
        }
    }
    while (cinfo.output_scanline < cinfo.output_height) {
        uint32_t *dst = pixels + (size_t)cinfo.output_scanline * (size_t)w;
        JSAMPROW rows[1] = {cmyk ? (JSAMPROW)row : (JSAMPROW)dst};
        if (jpeg_read_scanlines(&cinfo, rows, 1) != 1) break;
        if (cmyk) cmyk_row((const uint8_t *)row, dst, w, inverted);
    }
    int complete = cinfo.output_scanline == cinfo.output_height;
    jpeg_destroy_decompress(&cinfo);
    free(row);
    return complete ? WC_OK : WC_CORRUPT;
}

/* ---- PNG ---------------------------------------------------------------- */

typedef struct {
    const uint8_t *data;
    size_t len, pos;
} mem_source;

static void png_mem_read(png_structp png, png_bytep out, size_t n) {
    mem_source *src = png_get_io_ptr(png);
    if (src->len - src->pos < n) png_error(png, "truncated");
    memcpy(out, src->data + src->pos, n);
    src->pos += n;
}

/* libpng's own error handler prints to stderr when ours returns, so ours must
 * not return: it unwinds to the setjmp in png_run. */
static void png_fail(png_structp png, png_const_charp message) {
    (void)message;
    png_longjmp(png, 1);
}

static void png_quiet(png_structp png, png_const_charp message) {
    (void)png;
    (void)message;
}

static int png_run(const uint8_t *data, size_t len, uint32_t *pixels, int w, int h, wc_info *size, int *has_alpha) {
    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, png_fail, png_quiet);
    if (!png) return WC_NOMEM;
    png_infop info = png_create_info_struct(png);
    if (!info) {
        png_destroy_read_struct(&png, NULL, NULL);
        return WC_NOMEM;
    }
    png_bytep *volatile rows = NULL;
    volatile int status = WC_CORRUPT;
    if (setjmp(png_jmpbuf(png))) {
        png_destroy_read_struct(&png, &info, NULL);
        free(rows);
        return status;
    }
    mem_source src = {data, len, 8};
    png_set_read_fn(png, &src, png_mem_read);
    png_set_sig_bytes(png, 8);
    png_read_info(png, info);
    png_uint_32 pw = 0, ph = 0;
    int depth = 0, color = 0;
    png_get_IHDR(png, info, &pw, &ph, &depth, &color, NULL, NULL, NULL);
    if (pw == 0 || ph == 0 || pw > INT_MAX / 4 || ph > INT_MAX) {
        status = WC_TOO_LARGE;
        png_destroy_read_struct(&png, &info, NULL);
        return status;
    }
    if (!pixels) {
        size->w = (int)pw;
        size->h = (int)ph;
        png_destroy_read_struct(&png, &info, NULL);
        return WC_OK;
    }
    if ((int)pw != w || (int)ph != h) {
        png_destroy_read_struct(&png, &info, NULL);
        return WC_CORRUPT;
    }
    int translucent = (color & PNG_COLOR_MASK_ALPHA) || png_get_valid(png, info, PNG_INFO_tRNS);
    if (color == PNG_COLOR_TYPE_PALETTE) png_set_palette_to_rgb(png);
    if (color == PNG_COLOR_TYPE_GRAY && depth < 8) png_set_expand_gray_1_2_4_to_8(png);
    if (png_get_valid(png, info, PNG_INFO_tRNS)) png_set_tRNS_to_alpha(png);
    if (depth == 16) png_set_scale_16(png);
    if (color == PNG_COLOR_TYPE_GRAY || color == PNG_COLOR_TYPE_GRAY_ALPHA) png_set_gray_to_rgb(png);
    png_set_bgr(png);
    png_set_add_alpha(png, 0xff, PNG_FILLER_AFTER);
    /* Adam7 passes are merged by libpng into the rows we hand it. */
    png_set_interlace_handling(png);
    png_read_update_info(png, info);
    if (png_get_rowbytes(png, info) != (size_t)w * 4) {
        status = WC_UNSUPPORTED;
        png_destroy_read_struct(&png, &info, NULL);
        return status;
    }
    status = WC_NOMEM;
    rows = malloc((size_t)h * sizeof *rows);
    if (!rows) {
        png_destroy_read_struct(&png, &info, NULL);
        return status;
    }
    for (int y = 0; y < h; y++) rows[y] = (png_bytep)(pixels + (size_t)y * (size_t)w);
    status = WC_CORRUPT;
    png_read_image(png, rows);
    png_destroy_read_struct(&png, &info, NULL);
    free(rows);
    if (translucent && premultiply(pixels, (size_t)w * (size_t)h)) *has_alpha = 1;
    return WC_OK;
}

/* ---- WebP --------------------------------------------------------------- */

static int webp_run(const uint8_t *data, size_t len, uint32_t *pixels, int w, int h, wc_info *size, int *has_alpha) {
    WebPBitstreamFeatures features;
    VP8StatusCode status = WebPGetFeatures(data, len, &features);
    if (status == VP8_STATUS_UNSUPPORTED_FEATURE) return WC_UNSUPPORTED;
    if (status != VP8_STATUS_OK) return WC_CORRUPT;
    /* A still frame is all a wallpaper can be. */
    if (features.has_animation) return WC_UNSUPPORTED;
    if (features.width <= 0 || features.height <= 0 || features.width > INT_MAX / 4) return WC_TOO_LARGE;
    if (!pixels) {
        size->w = features.width;
        size->h = features.height;
        return WC_OK;
    }
    if (features.width != w || features.height != h) return WC_CORRUPT;
    WebPDecoderConfig config;
    if (!WebPInitDecoderConfig(&config)) return WC_NOMEM;
    /* Premultiplied B, G, R, A in the caller's memory. */
    config.output.colorspace = MODE_bgrA;
    config.output.is_external_memory = 1;
    config.output.u.RGBA.rgba = (uint8_t *)pixels;
    config.output.u.RGBA.stride = w * 4;
    config.output.u.RGBA.size = (size_t)w * 4 * (size_t)h;
    status = WebPDecode(data, len, &config);
    if (status != VP8_STATUS_OK) return WC_CORRUPT;
    if (features.has_alpha) {
        for (size_t i = 0, n = (size_t)w * (size_t)h; i < n; i++) {
            if (pixels[i] >> 24 != 0xff) {
                *has_alpha = 1;
                break;
            }
        }
    }
    return WC_OK;
}

/* ---- entry points ------------------------------------------------------- */

int wc_probe(const uint8_t *data, size_t len, wc_info *info) {
    memset(info, 0, sizeof *info);
    int unused = 0;
    switch (sniff(data, len)) {
    case K_PNG: return png_run(data, len, NULL, 0, 0, info, &unused);
    case K_JPEG: return jpeg_run(data, len, NULL, 0, 0, info);
    case K_WEBP: return webp_run(data, len, NULL, 0, 0, info, &unused);
    default: return WC_UNSUPPORTED;
    }
}

int wc_decode(const uint8_t *data, size_t len, uint32_t *pixels, int w, int h, int *has_alpha) {
    *has_alpha = 0;
    if (!pixels || w <= 0 || h <= 0) return WC_CORRUPT;
    wc_info unused;
    switch (sniff(data, len)) {
    case K_PNG: return png_run(data, len, pixels, w, h, &unused, has_alpha);
    case K_JPEG: return jpeg_run(data, len, pixels, w, h, &unused);
    case K_WEBP: return webp_run(data, len, pixels, w, h, &unused, has_alpha);
    default: return WC_UNSUPPORTED;
    }
}
