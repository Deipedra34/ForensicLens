/*
 * WebP through libwebp, loaded at run time (see cimagecodecs.h).
 *
 * Uses only libwebp's "simple" API: WebPGetInfo/WebPDecodeRGB to decode and
 * WebPEncodeRGB/WebPEncodeLosslessRGB to encode. These take plain pointers
 * and ints, have kept the same signatures since libwebp 0.x, and don't
 * depend on WEBP_DECODER_ABI_VERSION the way the advanced API's structs do.
 */

#include "cimagecodecs.h"
#include "cic_loader.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if CIC_DYNAMIC_LOADING

#include <pthread.h>

typedef int (*webp_get_info_fn)(const uint8_t *data, size_t size, int *width, int *height);
typedef uint8_t *(*webp_decode_rgb_fn)(const uint8_t *data, size_t size, int *width, int *height);
typedef void (*webp_free_fn)(void *pointer);
typedef int (*webp_version_fn)(void);
typedef size_t (*webp_encode_rgb_fn)(const uint8_t *rgb, int width, int height, int stride, float quality, uint8_t **output);
typedef size_t (*webp_encode_lossless_rgb_fn)(const uint8_t *rgb, int width, int height, int stride, uint8_t **output);

static struct {
    int status;
    char message[1400];
    cic_library library;
    webp_get_info_fn get_info;
    webp_decode_rgb_fn decode_rgb;
    /* WebPFree exists since libwebp 0.6; before that, buffers came from malloc. */
    webp_free_fn free_buffer;
    webp_encode_rgb_fn encode_rgb;
    webp_encode_lossless_rgb_fn encode_lossless_rgb;
} webp;

static const char *const webp_candidates[] = {
#if defined(__APPLE__)
    "libwebp.7.dylib",
    "/opt/homebrew/lib/libwebp.7.dylib", /* Homebrew, Apple silicon */
    "/usr/local/lib/libwebp.7.dylib",    /* Homebrew, Intel */
    "/opt/local/lib/libwebp.7.dylib",    /* MacPorts */
    "libwebp.dylib",
#else
    "libwebp.so.7",
    "/home/linuxbrew/.linuxbrew/lib/libwebp.so.7",
    "libwebp.so",
#endif
    NULL
};

static void webp_load_once(void) {
    char reason[1100];
    if (!cic_open_library(&webp.library, "libwebp", "FORENSICLENS_LIBWEBP_PATH", webp_candidates, reason, sizeof reason)) {
        webp.status = CIC_ERR_UNAVAILABLE;
        cic_copy_message(webp.message, sizeof webp.message, reason);
        return;
    }

    webp.get_info = (webp_get_info_fn)cic_symbol(&webp.library, "WebPGetInfo");
    webp.decode_rgb = (webp_decode_rgb_fn)cic_symbol(&webp.library, "WebPDecodeRGB");
    webp.free_buffer = (webp_free_fn)cic_symbol(&webp.library, "WebPFree");
    webp.encode_rgb = (webp_encode_rgb_fn)cic_symbol(&webp.library, "WebPEncodeRGB");
    webp.encode_lossless_rgb = (webp_encode_lossless_rgb_fn)cic_symbol(&webp.library, "WebPEncodeLosslessRGB");
    if (webp.get_info == NULL || webp.decode_rgb == NULL) {
        webp.status = CIC_ERR_UNAVAILABLE;
        cic_message(webp.message, sizeof webp.message, "%s was loaded but doesn't export WebPGetInfo/WebPDecodeRGB", webp.library.path);
        return;
    }

    cic_resolve_path(&webp.library, (void *)webp.decode_rgb);
    webp_version_fn version = (webp_version_fn)cic_symbol(&webp.library, "WebPGetDecoderVersion");
    if (version != NULL) {
        int v = version();
        cic_message(webp.message, sizeof webp.message, "libwebp %d.%d.%d (%s)", (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF, webp.library.path);
    } else {
        cic_message(webp.message, sizeof webp.message, "libwebp (%s)", webp.library.path);
    }
    webp.status = CIC_OK;
}

static void webp_release(uint8_t *buffer) {
    if (buffer == NULL) {
        return;
    }
    if (webp.free_buffer != NULL) {
        webp.free_buffer(buffer);
    } else {
        free(buffer);
    }
}

#endif /* CIC_DYNAMIC_LOADING */

int cic_webp_load(char *message, size_t message_size) {
#if CIC_DYNAMIC_LOADING
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, webp_load_once);
    cic_copy_message(message, message_size, webp.message);
    return webp.status;
#else
    cic_message(message, message_size, "libwebp can't be loaded on this platform (no run-time library loading)");
    return CIC_ERR_UNAVAILABLE;
#endif
}

int cic_webp_decode_rgb(const unsigned char *data, size_t length,
                        int *width, int *height, unsigned char **out_pixels,
                        char *message, size_t message_size) {
    if (data == NULL || width == NULL || height == NULL || out_pixels == NULL) {
        cic_message(message, message_size, "invalid argument");
        return CIC_ERR_INVALID_ARGUMENT;
    }
    *width = 0;
    *height = 0;
    *out_pixels = NULL;

    int status = cic_webp_load(message, message_size);
    if (status != CIC_OK) {
        return status;
    }

#if CIC_DYNAMIC_LOADING
    int w = 0;
    int h = 0;
    if (!webp.get_info(data, length, &w, &h)) {
        cic_message(message, message_size, "not a valid WebP bitstream (bad or truncated header)");
        return CIC_ERR_DECODE;
    }
    if (w <= 0 || h <= 0 || (long long)w * (long long)h > CIC_MAX_PIXELS) {
        cic_message(message, message_size, "unsupported image size %dx%d", w, h);
        return CIC_ERR_DIMENSIONS;
    }

    uint8_t *decoded = webp.decode_rgb(data, length, &w, &h);
    if (decoded == NULL) {
        cic_message(message, message_size, "libwebp could not decode the image data (corrupt or truncated)");
        return CIC_ERR_DECODE;
    }
    if (w <= 0 || h <= 0 || (long long)w * (long long)h > CIC_MAX_PIXELS) {
        webp_release(decoded);
        cic_message(message, message_size, "unsupported image size %dx%d", w, h);
        return CIC_ERR_DIMENSIONS;
    }

    size_t count = (size_t)w * (size_t)h * 3;
    unsigned char *pixels = (unsigned char *)malloc(count);
    if (pixels == NULL) {
        webp_release(decoded);
        cic_message(message, message_size, "out of memory");
        return CIC_ERR_ALLOC;
    }
    memcpy(pixels, decoded, count);
    webp_release(decoded);

    *width = w;
    *height = h;
    *out_pixels = pixels;
    return CIC_OK;
#else
    return CIC_ERR_UNAVAILABLE;
#endif
}

int cic_webp_encode_rgb(const unsigned char *rgb, int width, int height, int quality,
                        unsigned char **out_data, size_t *out_size,
                        char *message, size_t message_size) {
    if (rgb == NULL || out_data == NULL || out_size == NULL || width <= 0 || height <= 0
        || (long long)width * (long long)height > CIC_MAX_PIXELS) {
        cic_message(message, message_size, "invalid argument");
        return CIC_ERR_INVALID_ARGUMENT;
    }
    *out_data = NULL;
    *out_size = 0;

    int status = cic_webp_load(message, message_size);
    if (status != CIC_OK) {
        return status;
    }

#if CIC_DYNAMIC_LOADING
    uint8_t *encoded = NULL;
    size_t size = 0;
    if (quality < 0) {
        if (webp.encode_lossless_rgb == NULL) {
            cic_message(message, message_size, "%s has no lossless WebP encoder", webp.library.path);
            return CIC_ERR_NO_ENCODER;
        }
        size = webp.encode_lossless_rgb(rgb, width, height, width * 3, &encoded);
    } else {
        if (webp.encode_rgb == NULL) {
            cic_message(message, message_size, "%s has no WebP encoder", webp.library.path);
            return CIC_ERR_NO_ENCODER;
        }
        size = webp.encode_rgb(rgb, width, height, width * 3, (float)(quality > 100 ? 100 : quality), &encoded);
    }
    if (size == 0 || encoded == NULL) {
        webp_release(encoded);
        cic_message(message, message_size, "libwebp failed to encode a %dx%d image", width, height);
        return CIC_ERR_ENCODE;
    }

    unsigned char *copy = (unsigned char *)malloc(size);
    if (copy == NULL) {
        webp_release(encoded);
        cic_message(message, message_size, "out of memory");
        return CIC_ERR_ALLOC;
    }
    memcpy(copy, encoded, size);
    webp_release(encoded);

    *out_data = copy;
    *out_size = size;
    return CIC_OK;
#else
    (void)quality;
    return CIC_ERR_UNAVAILABLE;
#endif
}
