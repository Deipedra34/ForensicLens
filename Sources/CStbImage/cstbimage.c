/*
 * cstbimage.c
 *
 * Implementation of the minimal BMP / PPM decoders declared in
 * include/cstbimage.h. See that header for the design rationale.
 */

#include "cstbimage.h"
#include <stdlib.h>
#include <string.h>

/* ---------------------------------------------------------------------- */
/* Small helpers                                                          */
/* ---------------------------------------------------------------------- */

static unsigned int read_u16le(const unsigned char *p) {
    return (unsigned int)p[0] | ((unsigned int)p[1] << 8);
}

static unsigned int read_u32le(const unsigned char *p) {
    return (unsigned int)p[0]
         | ((unsigned int)p[1] << 8)
         | ((unsigned int)p[2] << 16)
         | ((unsigned int)p[3] << 24);
}

static int read_i32le(const unsigned char *p) {
    return (int)read_u32le(p);
}

void cstbi_free(unsigned char *ptr) {
    free(ptr);
}

/* ---------------------------------------------------------------------- */
/* BMP decoding                                                           */
/* ---------------------------------------------------------------------- */

int cstbi_decode_bmp(const unsigned char *data, size_t len,
                      int *width, int *height, int *channels,
                      unsigned char **out_pixels) {
    if (data == NULL || width == NULL || height == NULL ||
        channels == NULL || out_pixels == NULL) {
        return CSTBI_ERR_UNSUPPORTED;
    }
    if (len < 54) {
        return CSTBI_ERR_TRUNCATED;
    }
    if (data[0] != 'B' || data[1] != 'M') {
        return CSTBI_ERR_BAD_MAGIC;
    }

    unsigned int pixel_data_offset = read_u32le(data + 10);
    unsigned int dib_header_size = read_u32le(data + 14);
    if (dib_header_size < 40) {
        /* OS/2 style or otherwise unsupported DIB header. */
        return CSTBI_ERR_UNSUPPORTED;
    }
    if (len < 14 + dib_header_size) {
        return CSTBI_ERR_TRUNCATED;
    }

    int raw_width = read_i32le(data + 18);
    int raw_height = read_i32le(data + 22);
    unsigned int planes = read_u16le(data + 26);
    unsigned int bit_count = read_u16le(data + 28);
    unsigned int compression = read_u32le(data + 30);

    if (planes != 1) {
        return CSTBI_ERR_UNSUPPORTED;
    }
    if (compression != 0 /* BI_RGB */) {
        return CSTBI_ERR_UNSUPPORTED;
    }
    if (bit_count != 24 && bit_count != 32) {
        return CSTBI_ERR_UNSUPPORTED;
    }
    if (raw_width <= 0 || raw_width > 20000) {
        return CSTBI_ERR_DIMENSIONS;
    }

    int top_down = 0;
    int h = raw_height;
    if (h < 0) {
        top_down = 1;
        h = -h;
    }
    if (h <= 0 || h > 20000) {
        return CSTBI_ERR_DIMENSIONS;
    }

    int w = raw_width;
    int src_channels = (int)(bit_count / 8);
    /* BMP rows are padded to a multiple of 4 bytes. */
    size_t row_size = ((size_t)w * (size_t)src_channels + 3u) & ~((size_t)3u);
    size_t required = (size_t)pixel_data_offset + row_size * (size_t)h;
    if (pixel_data_offset > len || required > len || required < row_size) {
        return CSTBI_ERR_TRUNCATED;
    }

    int out_channels = 3; /* We always emit RGB, dropping any alpha byte. */
    unsigned char *out = (unsigned char *)malloc((size_t)w * (size_t)h * (size_t)out_channels);
    if (out == NULL) {
        return CSTBI_ERR_ALLOC;
    }

    for (int row = 0; row < h; row++) {
        /* BMP stores rows bottom-to-top unless the height is negative. */
        int src_row = top_down ? row : (h - 1 - row);
        const unsigned char *row_ptr = data + pixel_data_offset + (size_t)src_row * row_size;
        unsigned char *dst_row = out + (size_t)row * (size_t)w * (size_t)out_channels;
        for (int col = 0; col < w; col++) {
            const unsigned char *px = row_ptr + (size_t)col * (size_t)src_channels;
            /* BMP pixel order is BGR(A); convert to RGB. */
            unsigned char b = px[0];
            unsigned char g = px[1];
            unsigned char r = px[2];
            unsigned char *dst = dst_row + (size_t)col * (size_t)out_channels;
            dst[0] = r;
            dst[1] = g;
            dst[2] = b;
        }
    }

    *width = w;
    *height = h;
    *channels = out_channels;
    *out_pixels = out;
    return CSTBI_OK;
}

/* ---------------------------------------------------------------------- */
/* PPM / PGM decoding                                                     */
/* ---------------------------------------------------------------------- */

/* Advances *pos past any whitespace and '#' comments (to end of line). */
static void ppm_skip_whitespace_and_comments(const unsigned char *data, size_t len, size_t *pos) {
    while (*pos < len) {
        unsigned char c = data[*pos];
        if (c == '#') {
            while (*pos < len && data[*pos] != '\n') {
                (*pos)++;
            }
        } else if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
            (*pos)++;
        } else {
            break;
        }
    }
}

/* Reads a non-negative decimal integer token. Returns 1 on success. */
static int ppm_read_uint(const unsigned char *data, size_t len, size_t *pos, unsigned int *out_value) {
    ppm_skip_whitespace_and_comments(data, len, pos);
    if (*pos >= len || data[*pos] < '0' || data[*pos] > '9') {
        return 0;
    }
    unsigned int value = 0;
    while (*pos < len && data[*pos] >= '0' && data[*pos] <= '9') {
        value = value * 10u + (unsigned int)(data[*pos] - '0');
        (*pos)++;
        if (value > 1000000u) {
            return 0; /* guard against pathological input */
        }
    }
    *out_value = value;
    return 1;
}

int cstbi_decode_ppm(const unsigned char *data, size_t len,
                      int *width, int *height, int *channels,
                      unsigned char **out_pixels) {
    if (data == NULL || width == NULL || height == NULL ||
        channels == NULL || out_pixels == NULL) {
        return CSTBI_ERR_UNSUPPORTED;
    }
    if (len < 2) {
        return CSTBI_ERR_TRUNCATED;
    }
    if (data[0] != 'P' || (data[1] != '6' && data[1] != '5')) {
        return CSTBI_ERR_BAD_MAGIC;
    }

    int src_channels = (data[1] == '6') ? 3 : 1;
    size_t pos = 2;

    unsigned int w = 0, h = 0, maxval = 0;
    if (!ppm_read_uint(data, len, &pos, &w)) return CSTBI_ERR_TRUNCATED;
    if (!ppm_read_uint(data, len, &pos, &h)) return CSTBI_ERR_TRUNCATED;
    if (!ppm_read_uint(data, len, &pos, &maxval)) return CSTBI_ERR_TRUNCATED;

    if (maxval == 0 || maxval > 255) {
        /* 16-bit-per-sample PPM is not supported. */
        return CSTBI_ERR_UNSUPPORTED;
    }
    if (w == 0 || h == 0 || w > 20000 || h > 20000) {
        return CSTBI_ERR_DIMENSIONS;
    }

    /* A single whitespace byte separates the header from binary data. */
    if (pos >= len) {
        return CSTBI_ERR_TRUNCATED;
    }
    pos += 1;

    size_t pixel_bytes = (size_t)w * (size_t)h * (size_t)src_channels;
    if (pos + pixel_bytes > len) {
        return CSTBI_ERR_TRUNCATED;
    }

    unsigned char *out = (unsigned char *)malloc(pixel_bytes);
    if (out == NULL) {
        return CSTBI_ERR_ALLOC;
    }
    memcpy(out, data + pos, pixel_bytes);

    *width = (int)w;
    *height = (int)h;
    *channels = src_channels;
    *out_pixels = out;
    return CSTBI_OK;
}

/* ---------------------------------------------------------------------- */
/* JPEG (stub)                                                            */
/* ---------------------------------------------------------------------- */

int cstbi_decode_jpeg_baseline(const unsigned char *data, size_t len,
                                int *width, int *height, int *channels,
                                unsigned char **out_pixels) {
    (void)data;
    (void)len;
    (void)width;
    (void)height;
    (void)channels;
    (void)out_pixels;
    return CSTBI_ERR_NOT_IMPLEMENTED;
}
