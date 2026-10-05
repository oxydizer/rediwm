#define _GNU_SOURCE
#include "thumb_codec.h"

#include <fcntl.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
/* After <stdio.h>: jpeglib.h uses FILE without including it. */
#include <jpeglib.h>
#include <png.h>

/* ---- area-averaging downscaler ----------------------------------------- */

/* Rows arrive one at a time as straight RGBA bytes. Each source pixel is
 * premultiplied and added to the destination pixel it falls in; a destination
 * row is flushed when the next source row belongs to a later one. Averaging
 * premultiplied values is exact for alpha, and every destination pixel covers
 * at least one source pixel because the destination never exceeds the source.
 * Sums are 32-bit: `avg_fits` rejects ratios where they could overflow. */
typedef struct {
    int sw, sh, dw, dh;
    int next_sy;
    int dy;           /* destination row being accumulated, -1 before the first */
    uint32_t rows;
    uint32_t *acc;    /* dw * 4 channel sums */
    uint32_t *xs;     /* dw + 1: first source column of each destination column */
    uint32_t *out;    /* dw * dh */
} avg_t;

static void fit(int sw, int sh, int box, int *dw, int *dh) {
    if (sw <= box && sh <= box) {
        *dw = sw;
        *dh = sh;
    } else if (sw >= sh) {
        *dw = box;
        *dh = (int)(((int64_t)sh * box + sw / 2) / sw);
    } else {
        *dh = box;
        *dw = (int)(((int64_t)sw * box + sh / 2) / sh);
    }
    if (*dw < 1) *dw = 1;
    if (*dh < 1) *dh = 1;
}

/* Whether 8-bit channel sums over one destination pixel stay below 2^32. */
static int avg_fits(int sw, int sh, int dw, int dh) {
    uint64_t cols = ((uint64_t)sw + dw - 1) / dw;
    uint64_t rows = ((uint64_t)sh + dh - 1) / dh;
    return cols * rows * 255 < 0xffffffffu;
}

static void avg_free(avg_t *av) {
    if (!av) return;
    free(av->acc);
    free(av->xs);
    free(av->out);
    free(av);
}

static avg_t *avg_new(int sw, int sh, int dw, int dh) {
    avg_t *av = calloc(1, sizeof *av);
    if (!av) return NULL;
    av->sw = sw;
    av->sh = sh;
    av->dw = dw;
    av->dh = dh;
    av->dy = -1;
    av->acc = calloc((size_t)dw * 4, sizeof *av->acc);
    av->xs = malloc(((size_t)dw + 1) * sizeof *av->xs);
    av->out = calloc((size_t)dw * dh, sizeof *av->out);
    if (!av->acc || !av->xs || !av->out) {
        avg_free(av);
        return NULL;
    }
    /* Column x belongs to floor(x * dw / sw), so destination column k starts
     * at the first x with x * dw >= k * sw. */
    for (int k = 0; k <= dw; k++) av->xs[k] = (uint32_t)(((uint64_t)k * sw + dw - 1) / dw);
    return av;
}

static void avg_flush(avg_t *av) {
    for (int x = 0; x < av->dw; x++) {
        uint32_t n = (av->xs[x + 1] - av->xs[x]) * av->rows;
        if (n == 0) n = 1;
        const uint32_t *s = av->acc + (size_t)x * 4;
        uint32_t r = (s[0] + n / 2) / n;
        uint32_t g = (s[1] + n / 2) / n;
        uint32_t b = (s[2] + n / 2) / n;
        uint32_t a = (s[3] + n / 2) / n;
        av->out[(size_t)av->dy * av->dw + x] = a << 24 | r << 16 | g << 8 | b;
    }
}

static void avg_row(avg_t *av, const uint8_t *rgba) {
    if (av->next_sy >= av->sh) return;
    int dy = (int)((int64_t)av->next_sy * av->dh / av->sh);
    if (dy != av->dy) {
        if (av->dy >= 0) avg_flush(av);
        av->dy = dy;
        av->rows = 0;
        memset(av->acc, 0, (size_t)av->dw * 4 * sizeof *av->acc);
    }
    for (int x = 0; x < av->dw; x++) {
        const uint8_t *p = rgba + (size_t)av->xs[x] * 4;
        const uint8_t *end = rgba + (size_t)av->xs[x + 1] * 4;
        uint32_t r = 0, g = 0, b = 0, a = 0;
        for (; p < end; p += 4) {
            uint32_t pa = p[3];
            if (pa == 255) {
                r += p[0];
                g += p[1];
                b += p[2];
                a += 255;
            } else {
                r += (p[0] * pa + 127) / 255;
                g += (p[1] * pa + 127) / 255;
                b += (p[2] * pa + 127) / 255;
                a += pa;
            }
        }
        uint32_t *s = av->acc + (size_t)x * 4;
        s[0] += r;
        s[1] += g;
        s[2] += b;
        s[3] += a;
    }
    av->rows++;
    av->next_sy++;
}

/* Hands the finished pixels to `out`. Rows the decoder never delivered
 * (truncated files) stay transparent. */
static void avg_finish(avg_t *av, tc_image *out) {
    if (av->dy >= 0) avg_flush(av);
    out->pixels = av->out;
    out->w = av->dw;
    out->h = av->dh;
    av->out = NULL;
}

static void image_init(tc_image *out) {
    memset(out, 0, sizeof *out);
    out->orientation = 1;
    out->thumb_mtime = -1;
    out->thumb_size = -1;
}

void tc_free(tc_image *image) {
    free(image->pixels);
    image->pixels = NULL;
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

static unsigned rd16(const uint8_t *p, int big) {
    return big ? (unsigned)(p[0] << 8 | p[1]) : (unsigned)(p[1] << 8 | p[0]);
}

static unsigned rd32(const uint8_t *p, int big) {
    return big ? (unsigned)p[0] << 24 | (unsigned)p[1] << 16 | (unsigned)p[2] << 8 | p[3]
               : (unsigned)p[3] << 24 | (unsigned)p[2] << 16 | (unsigned)p[1] << 8 | p[0];
}

/* The Orientation tag of an Exif APP1 segment, 1 when absent or malformed. */
static int exif_orientation(const uint8_t *d, size_t n) {
    if (n < 14 || memcmp(d, "Exif\0\0", 6) != 0) return 1;
    const uint8_t *t = d + 6;
    size_t tn = n - 6;
    int big;
    if (t[0] == 'M' && t[1] == 'M') big = 1;
    else if (t[0] == 'I' && t[1] == 'I') big = 0;
    else return 1;
    if (rd16(t + 2, big) != 42) return 1;
    size_t ifd = rd32(t + 4, big);
    if (ifd > tn || tn - ifd < 2) return 1;
    unsigned count = rd16(t + ifd, big);
    for (unsigned i = 0; i < count; i++) {
        size_t entry = ifd + 2 + (size_t)i * 12;
        if (entry > tn || tn - entry < 12) return 1;
        if (rd16(t + entry, big) != 0x0112) continue;
        unsigned value = rd16(t + entry + 8, big);
        return value >= 1 && value <= 8 ? (int)value : 1;
    }
    return 1;
}

int tc_jpeg(const uint8_t *data, size_t len, int box, int64_t max_pixels, tc_image *out) {
    image_init(out);
    if (len < 4 || data[0] != 0xff || data[1] != 0xd8) return TC_UNSUPPORTED;
    struct jpeg_decompress_struct cinfo;
    jpeg_errors errors;
    unsigned char *volatile row = NULL;
    avg_t *volatile av = NULL;
    volatile int status = TC_CORRUPT;
    cinfo.err = jpeg_std_error(&errors.pub);
    errors.pub.error_exit = jpeg_fail;
    errors.pub.emit_message = jpeg_quiet;
    errors.pub.output_message = jpeg_silent;
    if (setjmp(errors.jump)) {
        jpeg_destroy_decompress(&cinfo);
        free(row);
        avg_free(av);
        free(out->pixels);
        out->pixels = NULL;
        return status;
    }
    jpeg_create_decompress(&cinfo);
    jpeg_mem_src(&cinfo, data, (unsigned long)len);
    jpeg_save_markers(&cinfo, JPEG_APP0 + 1, 0xffff);
    jpeg_read_header(&cinfo, TRUE);
    int sw = (int)cinfo.image_width, sh = (int)cinfo.image_height;
    out->src_w = sw;
    out->src_h = sh;
    if (sw <= 0 || sh <= 0 || (int64_t)sw * sh > max_pixels) {
        status = TC_TOO_LARGE;
        jpeg_destroy_decompress(&cinfo);
        return status;
    }
    if (cinfo.jpeg_color_space == JCS_CMYK || cinfo.jpeg_color_space == JCS_YCCK) {
        status = TC_UNSUPPORTED;
        jpeg_destroy_decompress(&cinfo);
        return status;
    }
    for (jpeg_saved_marker_ptr m = cinfo.marker_list; m; m = m->next) {
        if (m->marker == JPEG_APP0 + 1) {
            out->orientation = exif_orientation(m->data, m->data_length);
            break;
        }
    }
    int dw, dh;
    fit(sw, sh, box, &dw, &dh);
    if (!avg_fits(sw, sh, dw, dh)) {
        status = TC_UNSUPPORTED;
        jpeg_destroy_decompress(&cinfo);
        return status;
    }
    /* The largest reduction that still leaves at least the thumbnail's size. */
    int denom = 1;
    for (int d = 8; d >= 2; d /= 2) {
        if ((sw + d - 1) / d >= dw && (sh + d - 1) / d >= dh) {
            denom = d;
            break;
        }
    }
    cinfo.scale_num = 1;
    cinfo.scale_denom = (unsigned)denom;
    cinfo.out_color_space = JCS_EXT_RGBA;
    cinfo.dct_method = JDCT_IFAST;
    cinfo.do_fancy_upsampling = FALSE;
    jpeg_start_decompress(&cinfo);
    int ow = (int)cinfo.output_width, oh = (int)cinfo.output_height;
    status = TC_NOMEM;
    row = malloc((size_t)ow * 4);
    av = avg_new(ow, oh, dw, dh);
    if (!row || !av) {
        jpeg_destroy_decompress(&cinfo);
        free(row);
        avg_free(av);
        return status;
    }
    status = TC_CORRUPT;
    while (cinfo.output_scanline < cinfo.output_height) {
        JSAMPROW rows[1] = {row};
        if (jpeg_read_scanlines(&cinfo, rows, 1) != 1) break;
        avg_row(av, row);
    }
    avg_finish(av, out);
    avg_free(av);
    free(row);
    jpeg_destroy_decompress(&cinfo);
    return TC_OK;
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

static void png_quiet(png_structp png, png_const_charp message) {
    (void)png;
    (void)message;
}

int tc_png(const uint8_t *data, size_t len, int box, int64_t max_pixels, tc_image *out) {
    image_init(out);
    if (len < 8 || png_sig_cmp(data, 0, 8) != 0) return TC_UNSUPPORTED;
    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, png_quiet, png_quiet);
    if (!png) return TC_NOMEM;
    png_infop info = png_create_info_struct(png);
    if (!info) {
        png_destroy_read_struct(&png, NULL, NULL);
        return TC_NOMEM;
    }
    unsigned char *volatile row = NULL;
    avg_t *volatile av = NULL;
    volatile int status = TC_CORRUPT;
    if (setjmp(png_jmpbuf(png))) {
        png_destroy_read_struct(&png, &info, NULL);
        free(row);
        avg_free(av);
        free(out->pixels);
        out->pixels = NULL;
        return status;
    }
    /* A thumbnail of a slightly damaged file beats none, and the checksums
     * are a measurable share of the time. */
    png_set_crc_action(png, PNG_CRC_QUIET_USE, PNG_CRC_QUIET_USE);
#ifdef PNG_IGNORE_ADLER32
    png_set_option(png, PNG_IGNORE_ADLER32, PNG_OPTION_ON);
#endif
    mem_source src = {data, len, 8};
    png_set_read_fn(png, &src, png_mem_read);
    png_set_sig_bytes(png, 8);
    png_read_info(png, info);
    png_uint_32 w = 0, h = 0;
    int depth = 0, color = 0, interlace = 0;
    png_get_IHDR(png, info, &w, &h, &depth, &color, &interlace, NULL, NULL);
    out->src_w = (int)w;
    out->src_h = (int)h;
    if (w == 0 || h == 0 || w > 0x7fffffff || h > 0x7fffffff || (int64_t)w * (int64_t)h > max_pixels) {
        status = TC_TOO_LARGE;
        png_destroy_read_struct(&png, &info, NULL);
        return status;
    }
    /* Adam7 needs every row before any is final. */
    if (interlace != PNG_INTERLACE_NONE) {
        status = TC_UNSUPPORTED;
        png_destroy_read_struct(&png, &info, NULL);
        return status;
    }
    png_textp text = NULL;
    int texts = 0;
    if (png_get_text(png, info, &text, &texts) > 0) {
        for (int i = 0; i < texts; i++) {
            if (!text[i].text) continue;
            if (strcmp(text[i].key, "Thumb::MTime") == 0) out->thumb_mtime = strtoll(text[i].text, NULL, 10);
            else if (strcmp(text[i].key, "Thumb::Size") == 0) out->thumb_size = strtoll(text[i].text, NULL, 10);
        }
    }
    if (color == PNG_COLOR_TYPE_PALETTE) png_set_palette_to_rgb(png);
    if (color == PNG_COLOR_TYPE_GRAY && depth < 8) png_set_expand_gray_1_2_4_to_8(png);
    if (png_get_valid(png, info, PNG_INFO_tRNS)) png_set_tRNS_to_alpha(png);
    if (depth == 16) png_set_scale_16(png);
    if (color == PNG_COLOR_TYPE_GRAY || color == PNG_COLOR_TYPE_GRAY_ALPHA) png_set_gray_to_rgb(png);
    png_set_add_alpha(png, 0xff, PNG_FILLER_AFTER);
    png_read_update_info(png, info);
    if (png_get_rowbytes(png, info) != (size_t)w * 4) {
        status = TC_UNSUPPORTED;
        png_destroy_read_struct(&png, &info, NULL);
        return status;
    }
    int dw, dh;
    fit((int)w, (int)h, box, &dw, &dh);
    if (!avg_fits((int)w, (int)h, dw, dh)) {
        status = TC_UNSUPPORTED;
        png_destroy_read_struct(&png, &info, NULL);
        return status;
    }
    status = TC_NOMEM;
    row = malloc((size_t)w * 4);
    av = avg_new((int)w, (int)h, dw, dh);
    if (!row || !av) {
        png_destroy_read_struct(&png, &info, NULL);
        free(row);
        avg_free(av);
        return status;
    }
    status = TC_CORRUPT;
    for (png_uint_32 y = 0; y < h; y++) {
        png_read_row(png, row, NULL);
        avg_row(av, row);
    }
    avg_finish(av, out);
    avg_free(av);
    free(row);
    png_destroy_read_struct(&png, &info, NULL);
    return TC_OK;
}

int tc_png_write(const char *path, const uint32_t *pixels, int w, int h, const char *uri, int64_t mtime, int64_t size) {
    if (w <= 0 || h <= 0) return -1;
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    FILE *file = fdopen(fd, "wb");
    if (!file) {
        close(fd);
        unlink(path);
        return -1;
    }
    png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, png_quiet, png_quiet);
    png_infop info = png ? png_create_info_struct(png) : NULL;
    unsigned char *volatile row = NULL;
    if (!png || !info) {
        if (png) png_destroy_write_struct(&png, NULL);
        fclose(file);
        unlink(path);
        return -1;
    }
    if (setjmp(png_jmpbuf(png))) {
        png_destroy_write_struct(&png, &info);
        free(row);
        fclose(file);
        unlink(path);
        return -1;
    }
    png_init_io(png, file);
    png_set_compression_level(png, 3);
    png_set_IHDR(png, info, (png_uint_32)w, (png_uint_32)h, 8, PNG_COLOR_TYPE_RGB_ALPHA, PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
    char mtime_text[32], size_text[32];
    snprintf(mtime_text, sizeof mtime_text, "%lld", (long long)mtime);
    snprintf(size_text, sizeof size_text, "%lld", (long long)size);
    png_text text[4];
    memset(text, 0, sizeof text);
    const char *keys[4] = {"Thumb::URI", "Thumb::MTime", "Thumb::Size", "Software"};
    char *values[4] = {(char *)uri, mtime_text, size_text, "RediWM Files"};
    for (int i = 0; i < 4; i++) {
        text[i].compression = PNG_TEXT_COMPRESSION_NONE;
        text[i].key = (char *)keys[i];
        text[i].text = values[i];
        text[i].text_length = strlen(values[i]);
    }
    png_set_text(png, info, text, 4);
    png_write_info(png, info);
    row = malloc((size_t)w * 4);
    if (!row) png_error(png, "memory");
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            uint32_t p = pixels[(size_t)y * w + x];
            uint32_t a = p >> 24, r = (p >> 16) & 0xff, g = (p >> 8) & 0xff, b = p & 0xff;
            if (a != 0 && a != 255) {
                r = r * 255 / a;
                g = g * 255 / a;
                b = b * 255 / a;
                if (r > 255) r = 255;
                if (g > 255) g = 255;
                if (b > 255) b = 255;
            }
            unsigned char *o = row + (size_t)x * 4;
            o[0] = (unsigned char)r;
            o[1] = (unsigned char)g;
            o[2] = (unsigned char)b;
            o[3] = (unsigned char)a;
        }
        png_write_row(png, row);
    }
    png_write_end(png, info);
    png_destroy_write_struct(&png, &info);
    free(row);
    if (fclose(file) != 0) {
        unlink(path);
        return -1;
    }
    return 0;
}
