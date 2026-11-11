#ifndef CIC_LOADER_H
#define CIC_LOADER_H

/*
 * Private helpers shared by heif_codec.c and webp_codec.c: finding and
 * opening a shared library at run time, resolving its functions, and
 * writing status messages. Not part of the module's public header.
 */

#include <stddef.h>

/*
 * Run-time loading needs dlopen(). WebAssembly (WASI) has no dynamic
 * loading at all, and Windows would need LoadLibrary and different library
 * names, which nothing here is tested against -- on those platforms both
 * codecs simply report themselves as unavailable.
 */
#if defined(_WIN32) || defined(__wasi__) || defined(__EMSCRIPTEN__)
#define CIC_DYNAMIC_LOADING 0
#else
#define CIC_DYNAMIC_LOADING 1
#endif

typedef struct {
    void *handle;
    /* The file actually opened, resolved to a full path where possible. */
    char path[1024];
} cic_library;

/*
 * Opens the library named by the environment variable `env_variable` if
 * it's set (and fails if that path can't be opened), otherwise the first of
 * `candidates` (NULL-terminated) that opens. Returns 1 on success; on
 * failure writes the reason to `message` and returns 0.
 */
int cic_open_library(cic_library *library, const char *display_name, const char *env_variable,
                     const char *const *candidates, char *message, size_t message_size);

/* The address of `name` in `library`, or NULL if it isn't exported. */
void *cic_symbol(const cic_library *library, const char *name);

/* Records the full path of the opened library, found through `symbol`. */
void cic_resolve_path(cic_library *library, void *symbol);

/* snprintf into `message` (a no-op if it's NULL or empty). */
void cic_message(char *message, size_t message_size, const char *format, ...);

/* Copies `source` (may be NULL) into `message`. */
void cic_copy_message(char *message, size_t message_size, const char *source);

#endif /* CIC_LOADER_H */
