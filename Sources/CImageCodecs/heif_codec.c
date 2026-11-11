/*
 * HEIF/HEIC through libheif, loaded at run time (see cimagecodecs.h).
 *
 * libheif's own types are only ever handled through pointers here, so they
 * are declared as void*. The one struct passed by value, heif_error, and
 * the few enum constants used are reproduced below; all of them have been
 * part of libheif's stable C API since 1.x. libheif in turn needs an HEVC
 * decoder (libde265, built in or as a plugin) to decode HEIC.
 */

#include "cimagecodecs.h"
#include "cic_loader.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if CIC_DYNAMIC_LOADING

#include <pthread.h>

/* struct heif_error: { enum heif_error_code; enum heif_suberror_code; const char *message; } */
typedef struct {
    int code;
    int subcode;
    const char *message;
} cic_heif_error;

/* struct heif_writer, version 1. */
typedef struct {
    int writer_api_version;
    cic_heif_error (*write)(void *context, const void *data, size_t size, void *userdata);
} cic_heif_writer;

enum {
    CIC_HEIF_ERROR_OK = 0,
    CIC_HEIF_ERROR_UNSUPPORTED_FEATURE = 4,
    CIC_HEIF_ERROR_MEMORY = 6,
    CIC_HEIF_ERROR_DECODER_PLUGIN = 7,
    CIC_HEIF_COLORSPACE_RGB = 1,
    CIC_HEIF_CHROMA_INTERLEAVED_RGB = 10,
    CIC_HEIF_CHANNEL_INTERLEAVED = 10,
    CIC_HEIF_COMPRESSION_HEVC = 1
};

typedef const char *(*heif_get_version_fn)(void);
typedef cic_heif_error (*heif_init_fn)(void *params);
typedef void *(*heif_context_alloc_fn)(void);
typedef void (*heif_context_free_fn)(void *context);
typedef cic_heif_error (*heif_context_read_from_memory_without_copy_fn)(void *context, const void *memory, size_t size, const void *options);
typedef cic_heif_error (*heif_context_get_primary_image_handle_fn)(void *context, void **handle);
typedef void (*heif_image_handle_release_fn)(const void *handle);
typedef cic_heif_error (*heif_decode_image_fn)(const void *handle, void **image, int colorspace, int chroma, const void *options);
typedef const uint8_t *(*heif_image_get_plane_readonly_fn)(const void *image, int channel, int *stride);
typedef int (*heif_image_get_dimension_fn)(const void *image, int channel);
typedef void (*heif_image_release_fn)(const void *image);
typedef cic_heif_error (*heif_context_get_encoder_for_format_fn)(void *context, int format, void **encoder);
typedef void (*heif_encoder_release_fn)(void *encoder);
typedef cic_heif_error (*heif_encoder_set_int_fn)(void *encoder, int value);
typedef cic_heif_error (*heif_encoder_set_parameter_fn)(void *encoder, const char *name, const char *value);
typedef cic_heif_error (*heif_image_create_fn)(int width, int height, int colorspace, int chroma, void **image);
typedef cic_heif_error (*heif_image_add_plane_fn)(void *image, int channel, int width, int height, int bit_depth);
typedef uint8_t *(*heif_image_get_plane_fn)(void *image, int channel, int *stride);
typedef cic_heif_error (*heif_context_encode_image_fn)(void *context, const void *image, void *encoder, const void *options, void **handle);
typedef cic_heif_error (*heif_context_add_exif_metadata_fn)(void *context, const void *handle, const void *data, int size);
typedef cic_heif_error (*heif_context_write_fn)(void *context, cic_heif_writer *writer, void *userdata);

static struct {
    int status;
    char message[1400];
    cic_library library;
    /* Decoding (required). */
    heif_context_alloc_fn context_alloc;
    heif_context_free_fn context_free;
    heif_context_read_from_memory_without_copy_fn read_from_memory;
    heif_context_get_primary_image_handle_fn primary_image_handle;
    heif_image_handle_release_fn handle_release;
    heif_decode_image_fn decode_image;
    heif_image_get_plane_readonly_fn plane_readonly;
    heif_image_get_dimension_fn image_width;
    heif_image_get_dimension_fn image_height;
    heif_image_release_fn image_release;
    /* Encoding (optional: only used to build test fixtures). */
    heif_context_get_encoder_for_format_fn encoder_for_format;
    heif_encoder_release_fn encoder_release;
    heif_encoder_set_int_fn set_lossy_quality;
    heif_encoder_set_int_fn set_lossless;
    heif_encoder_set_parameter_fn set_parameter;
    heif_image_create_fn image_create;
    heif_image_add_plane_fn add_plane;
    heif_image_get_plane_fn plane;
    heif_context_encode_image_fn encode_image;
    heif_context_add_exif_metadata_fn add_exif_metadata;
    heif_context_write_fn context_write;
} heif;

static const char *const heif_candidates[] = {
#if defined(__APPLE__)
    "libheif.1.dylib",
    "/opt/homebrew/lib/libheif.1.dylib", /* Homebrew, Apple silicon */
    "/usr/local/lib/libheif.1.dylib",    /* Homebrew, Intel */
    "/opt/local/lib/libheif.1.dylib",    /* MacPorts */
    "libheif.dylib",
#else
    "libheif.so.1",
    "/home/linuxbrew/.linuxbrew/lib/libheif.so.1",
    "libheif.so",
#endif
    NULL
};

static void heif_load_once(void) {
    char reason[1100];
    if (!cic_open_library(&heif.library, "libheif", "FORENSICLENS_LIBHEIF_PATH", heif_candidates, reason, sizeof reason)) {
        heif.status = CIC_ERR_UNAVAILABLE;
        cic_copy_message(heif.message, sizeof heif.message, reason);
        return;
    }

    const cic_library *lib = &heif.library;
    heif.context_alloc = (heif_context_alloc_fn)cic_symbol(lib, "heif_context_alloc");
    heif.context_free = (heif_context_free_fn)cic_symbol(lib, "heif_context_free");
    heif.read_from_memory = (heif_context_read_from_memory_without_copy_fn)cic_symbol(lib, "heif_context_read_from_memory_without_copy");
    heif.primary_image_handle = (heif_context_get_primary_image_handle_fn)cic_symbol(lib, "heif_context_get_primary_image_handle");
    heif.handle_release = (heif_image_handle_release_fn)cic_symbol(lib, "heif_image_handle_release");
    heif.decode_image = (heif_decode_image_fn)cic_symbol(lib, "heif_decode_image");
    heif.plane_readonly = (heif_image_get_plane_readonly_fn)cic_symbol(lib, "heif_image_get_plane_readonly");
    heif.image_width = (heif_image_get_dimension_fn)cic_symbol(lib, "heif_image_get_width");
    heif.image_height = (heif_image_get_dimension_fn)cic_symbol(lib, "heif_image_get_height");
    heif.image_release = (heif_image_release_fn)cic_symbol(lib, "heif_image_release");

    heif.encoder_for_format = (heif_context_get_encoder_for_format_fn)cic_symbol(lib, "heif_context_get_encoder_for_format");
    heif.encoder_release = (heif_encoder_release_fn)cic_symbol(lib, "heif_encoder_release");
    heif.set_lossy_quality = (heif_encoder_set_int_fn)cic_symbol(lib, "heif_encoder_set_lossy_quality");
    heif.set_lossless = (heif_encoder_set_int_fn)cic_symbol(lib, "heif_encoder_set_lossless");
    heif.set_parameter = (heif_encoder_set_parameter_fn)cic_symbol(lib, "heif_encoder_set_parameter");
    heif.image_create = (heif_image_create_fn)cic_symbol(lib, "heif_image_create");
    heif.add_plane = (heif_image_add_plane_fn)cic_symbol(lib, "heif_image_add_plane");
    heif.plane = (heif_image_get_plane_fn)cic_symbol(lib, "heif_image_get_plane");
    heif.encode_image = (heif_context_encode_image_fn)cic_symbol(lib, "heif_context_encode_image");
    heif.add_exif_metadata = (heif_context_add_exif_metadata_fn)cic_symbol(lib, "heif_context_add_exif_metadata");
    heif.context_write = (heif_context_write_fn)cic_symbol(lib, "heif_context_write");

    if (heif.context_alloc == NULL || heif.context_free == NULL || heif.read_from_memory == NULL
        || heif.primary_image_handle == NULL || heif.handle_release == NULL || heif.decode_image == NULL
        || heif.plane_readonly == NULL || heif.image_width == NULL || heif.image_height == NULL
        || heif.image_release == NULL) {
        heif.status = CIC_ERR_UNAVAILABLE;
        cic_message(heif.message, sizeof heif.message, "%s was loaded but is missing functions this decoder needs (libheif 1.4 or newer is required)", heif.library.path);
        return;
    }

    /* libheif 1.14+ loads its codec plugins in heif_init(); older versions don't have it. */
    heif_init_fn init = (heif_init_fn)cic_symbol(lib, "heif_init");
    if (init != NULL) {
        (void)init(NULL);
    }

    cic_resolve_path(&heif.library, (void *)heif.context_alloc);
    heif_get_version_fn version = (heif_get_version_fn)cic_symbol(lib, "heif_get_version");
    const char *version_text = version != NULL ? version() : NULL;
    cic_message(heif.message, sizeof heif.message, "libheif %s (%s)", version_text != NULL ? version_text : "(unknown version)", heif.library.path);
    heif.status = CIC_OK;
}

/* "...: <libheif's message>", plus a hint when the cause is a missing codec plugin. */
static void heif_error_message(char *message, size_t message_size, const char *what, cic_heif_error error) {
    const char *hint = "";
    if (error.code == CIC_HEIF_ERROR_UNSUPPORTED_FEATURE || error.code == CIC_HEIF_ERROR_DECODER_PLUGIN) {
        hint = " (libheif may be missing its HEVC decoder, e.g. the libheif-plugin-libde265 package)";
    }
    cic_message(message, message_size, "%s: %s%s", what, error.message != NULL ? error.message : "unknown error", hint);
}

typedef struct {
    unsigned char *data;
    size_t size;
    size_t capacity;
} heif_output;

static cic_heif_error heif_write_to_memory(void *context, const void *data, size_t size, void *userdata) {
    (void)context;
    heif_output *output = (heif_output *)userdata;
    cic_heif_error ok = { CIC_HEIF_ERROR_OK, 0, "Success" };
    if (size == 0) {
        return ok;
    }
    if (output->size + size > output->capacity) {
        size_t capacity = output->capacity == 0 ? 4096 : output->capacity;
        while (capacity < output->size + size) {
            capacity *= 2;
        }
        unsigned char *grown = (unsigned char *)realloc(output->data, capacity);
        if (grown == NULL) {
            cic_heif_error failed = { CIC_HEIF_ERROR_MEMORY, 0, "out of memory" };
            return failed;
        }
        output->data = grown;
        output->capacity = capacity;
    }
    memcpy(output->data + output->size, data, size);
    output->size += size;
    return ok;
}

#endif /* CIC_DYNAMIC_LOADING */

int cic_heif_load(char *message, size_t message_size) {
#if CIC_DYNAMIC_LOADING
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, heif_load_once);
    cic_copy_message(message, message_size, heif.message);
    return heif.status;
#else
    cic_message(message, message_size, "libheif can't be loaded on this platform (no run-time library loading)");
    return CIC_ERR_UNAVAILABLE;
#endif
}

int cic_heif_decode_rgb(const unsigned char *data, size_t length,
                        int *width, int *height, unsigned char **out_pixels,
                        char *message, size_t message_size) {
    if (data == NULL || width == NULL || height == NULL || out_pixels == NULL) {
        cic_message(message, message_size, "invalid argument");
        return CIC_ERR_INVALID_ARGUMENT;
    }
    *width = 0;
    *height = 0;
    *out_pixels = NULL;

    int status = cic_heif_load(message, message_size);
    if (status != CIC_OK) {
        return status;
    }

#if CIC_DYNAMIC_LOADING
    void *context = heif.context_alloc();
    if (context == NULL) {
        cic_message(message, message_size, "out of memory");
        return CIC_ERR_ALLOC;
    }

    void *handle = NULL;
    void *image = NULL;
    unsigned char *pixels = NULL;
    int result = CIC_ERR_DECODE;

    cic_heif_error error = heif.read_from_memory(context, data, length, NULL);
    if (error.code != CIC_HEIF_ERROR_OK) {
        heif_error_message(message, message_size, "libheif could not read the file", error);
        goto done;
    }
    error = heif.primary_image_handle(context, &handle);
    if (error.code != CIC_HEIF_ERROR_OK || handle == NULL) {
        heif_error_message(message, message_size, "the file has no usable primary image", error);
        goto done;
    }
    error = heif.decode_image(handle, &image, CIC_HEIF_COLORSPACE_RGB, CIC_HEIF_CHROMA_INTERLEAVED_RGB, NULL);
    if (error.code != CIC_HEIF_ERROR_OK || image == NULL) {
        heif_error_message(message, message_size, "libheif could not decode the image", error);
        goto done;
    }

    int stride = 0;
    const uint8_t *plane = heif.plane_readonly(image, CIC_HEIF_CHANNEL_INTERLEAVED, &stride);
    int w = heif.image_width(image, CIC_HEIF_CHANNEL_INTERLEAVED);
    int h = heif.image_height(image, CIC_HEIF_CHANNEL_INTERLEAVED);
    if (w <= 0 || h <= 0 || (long long)w * (long long)h > CIC_MAX_PIXELS) {
        cic_message(message, message_size, "unsupported image size %dx%d", w, h);
        result = CIC_ERR_DIMENSIONS;
        goto done;
    }
    if (plane == NULL || stride < w * 3) {
        cic_message(message, message_size, "libheif returned no usable RGB pixel data");
        goto done;
    }

    size_t row_bytes = (size_t)w * 3;
    pixels = (unsigned char *)malloc(row_bytes * (size_t)h);
    if (pixels == NULL) {
        cic_message(message, message_size, "out of memory");
        result = CIC_ERR_ALLOC;
        goto done;
    }
    for (int y = 0; y < h; y++) {
        memcpy(pixels + (size_t)y * row_bytes, plane + (size_t)y * (size_t)stride, row_bytes);
    }

    *width = w;
    *height = h;
    *out_pixels = pixels;
    pixels = NULL;
    result = CIC_OK;

done:
    free(pixels);
    if (image != NULL) {
        heif.image_release(image);
    }
    if (handle != NULL) {
        heif.handle_release(handle);
    }
    heif.context_free(context);
    return result;
#else
    return CIC_ERR_UNAVAILABLE;
#endif
}

int cic_heif_encode_rgb(const unsigned char *rgb, int width, int height, int quality,
                        const unsigned char *exif, size_t exif_size,
                        unsigned char **out_data, size_t *out_size,
                        char *message, size_t message_size) {
    if (rgb == NULL || out_data == NULL || out_size == NULL || width <= 0 || height <= 0
        || (long long)width * (long long)height > CIC_MAX_PIXELS || exif_size > (size_t)0x7FFFFFFF) {
        cic_message(message, message_size, "invalid argument");
        return CIC_ERR_INVALID_ARGUMENT;
    }
    *out_data = NULL;
    *out_size = 0;

    int status = cic_heif_load(message, message_size);
    if (status != CIC_OK) {
        return status;
    }

#if CIC_DYNAMIC_LOADING
    if (heif.encoder_for_format == NULL || heif.encoder_release == NULL || heif.set_lossy_quality == NULL
        || heif.set_lossless == NULL || heif.image_create == NULL || heif.add_plane == NULL || heif.plane == NULL
        || heif.encode_image == NULL || heif.context_write == NULL) {
        cic_message(message, message_size, "%s doesn't export libheif's encoding API", heif.library.path);
        return CIC_ERR_NO_ENCODER;
    }

    void *context = heif.context_alloc();
    if (context == NULL) {
        cic_message(message, message_size, "out of memory");
        return CIC_ERR_ALLOC;
    }

    void *encoder = NULL;
    void *image = NULL;
    void *handle = NULL;
    heif_output output = { NULL, 0, 0 };
    int result = CIC_ERR_ENCODE;

    cic_heif_error error = heif.encoder_for_format(context, CIC_HEIF_COMPRESSION_HEVC, &encoder);
    if (error.code != CIC_HEIF_ERROR_OK || encoder == NULL) {
        cic_message(message, message_size, "libheif has no HEVC encoder (e.g. the libheif-plugin-x265 package): %s",
                    error.message != NULL ? error.message : "unknown error");
        result = CIC_ERR_NO_ENCODER;
        goto done;
    }
    if (quality < 0) {
        (void)heif.set_lossless(encoder, 1);
    } else {
        (void)heif.set_lossy_quality(encoder, quality > 100 ? 100 : quality);
    }
    if (heif.set_parameter != NULL) {
        /* Best effort: keep full-resolution chroma where the encoder supports it. */
        (void)heif.set_parameter(encoder, "chroma", "444");
    }

    error = heif.image_create(width, height, CIC_HEIF_COLORSPACE_RGB, CIC_HEIF_CHROMA_INTERLEAVED_RGB, &image);
    if (error.code != CIC_HEIF_ERROR_OK || image == NULL) {
        heif_error_message(message, message_size, "libheif could not create an image", error);
        goto done;
    }
    error = heif.add_plane(image, CIC_HEIF_CHANNEL_INTERLEAVED, width, height, 8);
    if (error.code != CIC_HEIF_ERROR_OK) {
        heif_error_message(message, message_size, "libheif could not allocate the image plane", error);
        goto done;
    }
    int stride = 0;
    uint8_t *plane = heif.plane(image, CIC_HEIF_CHANNEL_INTERLEAVED, &stride);
    if (plane == NULL || stride < width * 3) {
        cic_message(message, message_size, "libheif returned no writable image plane");
        goto done;
    }
    size_t row_bytes = (size_t)width * 3;
    for (int y = 0; y < height; y++) {
        memcpy(plane + (size_t)y * (size_t)stride, rgb + (size_t)y * row_bytes, row_bytes);
    }

    error = heif.encode_image(context, image, encoder, NULL, &handle);
    if (error.code != CIC_HEIF_ERROR_OK) {
        heif_error_message(message, message_size, "libheif could not encode the image", error);
        goto done;
    }
    if (exif != NULL && exif_size > 0) {
        if (heif.add_exif_metadata == NULL) {
            cic_message(message, message_size, "%s can't store EXIF metadata", heif.library.path);
            goto done;
        }
        error = heif.add_exif_metadata(context, handle, exif, (int)exif_size);
        if (error.code != CIC_HEIF_ERROR_OK) {
            heif_error_message(message, message_size, "libheif could not add the EXIF metadata", error);
            goto done;
        }
    }

    cic_heif_writer writer = { 1, heif_write_to_memory };
    error = heif.context_write(context, &writer, &output);
    if (error.code != CIC_HEIF_ERROR_OK || output.size == 0) {
        heif_error_message(message, message_size, "libheif could not write the file", error);
        goto done;
    }

    *out_data = output.data;
    *out_size = output.size;
    output.data = NULL;
    result = CIC_OK;

done:
    free(output.data);
    if (handle != NULL) {
        heif.handle_release(handle);
    }
    if (image != NULL) {
        heif.image_release(image);
    }
    if (encoder != NULL) {
        heif.encoder_release(encoder);
    }
    heif.context_free(context);
    return result;
#else
    (void)quality;
    (void)exif;
    (void)exif_size;
    return CIC_ERR_UNAVAILABLE;
#endif
}
