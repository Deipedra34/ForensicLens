#ifndef CIMAGECODECS_H
#define CIMAGECODECS_H

/*
 * cimagecodecs - HEIF/HEIC and WebP support through system codec libraries
 * that are loaded at run time, not linked at build time.
 *
 * libheif and libwebp are opened with dlopen() the first time they're
 * needed. Nothing here needs their headers or development packages to
 * compile, so the package builds exactly as before on a machine without
 * them; the two formats just report themselves as unavailable until the
 * libraries are installed. Only the handful of functions used below are
 * declared (in heif_codec.c and webp_codec.c), all from the libraries'
 * long-stable C APIs.
 *
 * Every function returns one of the CIC_* status codes and, on failure,
 * writes a human-readable reason into `message` (always NUL-terminated,
 * truncated to `message_size`). Buffers handed back through `out_*`
 * pointers are allocated here and must be released with cic_free().
 *
 * Only ImageDecoding (Swift) calls into this module.
 */

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CIC_OK                    0
/* The codec library isn't installed, couldn't be loaded, or lacks a needed function. */
#define CIC_ERR_UNAVAILABLE       1
/* The library rejected the data: corrupt, truncated, or an unsupported variant. */
#define CIC_ERR_DECODE            2
#define CIC_ERR_ALLOC             3
/* The decoded image is empty or larger than CIC_MAX_PIXELS. */
#define CIC_ERR_DIMENSIONS        4
#define CIC_ERR_ENCODE            5
/* The library is present but has no encoder for the format (e.g. libheif without an HEVC encoder plugin). */
#define CIC_ERR_NO_ENCODER        6
#define CIC_ERR_INVALID_ARGUMENT  7

/* Largest image either decoder will hand back, in pixels (width * height). */
#define CIC_MAX_PIXELS (256LL * 1024LL * 1024LL)

/*
 * Load the library if it isn't loaded yet (once per process; thread-safe).
 * Returns CIC_OK with a description such as "libheif 1.17.6
 * (/usr/lib/x86_64-linux-gnu/libheif.so.1)" in `message`, or
 * CIC_ERR_UNAVAILABLE with the reason.
 */
int cic_heif_load(char *message, size_t message_size);
int cic_webp_load(char *message, size_t message_size);

/*
 * Decode a complete HEIF/HEIC or WebP file to tightly packed 8-bit RGB
 * (3 bytes per pixel, rows top to bottom). HEIF decoding applies the file's
 * rotation/mirroring, so the result is the image as it's meant to be
 * displayed; alpha, if any, is dropped.
 */
int cic_heif_decode_rgb(const unsigned char *data, size_t length,
                        int *width, int *height, unsigned char **out_pixels,
                        char *message, size_t message_size);
int cic_webp_decode_rgb(const unsigned char *data, size_t length,
                        int *width, int *height, unsigned char **out_pixels,
                        char *message, size_t message_size);

/*
 * Encode tightly packed 8-bit RGB. `quality` is 0-100, or negative for
 * lossless. HEIF output uses HEVC with 4:4:4 chroma where the encoder
 * supports it, and stores `exif` (raw TIFF-structured EXIF, may be NULL) as
 * the image's Exif metadata item. Used to build test fixtures.
 */
int cic_heif_encode_rgb(const unsigned char *rgb, int width, int height, int quality,
                        const unsigned char *exif, size_t exif_size,
                        unsigned char **out_data, size_t *out_size,
                        char *message, size_t message_size);
int cic_webp_encode_rgb(const unsigned char *rgb, int width, int height, int quality,
                        unsigned char **out_data, size_t *out_size,
                        char *message, size_t message_size);

/* Release a buffer returned by any function above. NULL is ignored. */
void cic_free(void *pointer);

#ifdef __cplusplus
}
#endif

#endif /* CIMAGECODECS_H */
