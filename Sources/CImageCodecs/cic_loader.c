#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE /* dladdr() */
#endif

#include "cic_loader.h"
#include "cimagecodecs.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if CIC_DYNAMIC_LOADING
#include <dlfcn.h>
#endif

void cic_message(char *message, size_t message_size, const char *format, ...) {
    if (message == NULL || message_size == 0) {
        return;
    }
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(message, message_size, format, arguments);
    va_end(arguments);
}

void cic_copy_message(char *message, size_t message_size, const char *source) {
    cic_message(message, message_size, "%s", source != NULL ? source : "");
}

void cic_free(void *pointer) {
    free(pointer);
}

#if CIC_DYNAMIC_LOADING

int cic_open_library(cic_library *library, const char *display_name, const char *env_variable,
                     const char *const *candidates, char *message, size_t message_size) {
    library->handle = NULL;
    library->path[0] = '\0';

    const char *override = getenv(env_variable);
    if (override != NULL && override[0] != '\0') {
        library->handle = dlopen(override, RTLD_NOW | RTLD_LOCAL);
        if (library->handle == NULL) {
            const char *reason = dlerror();
            cic_message(message, message_size, "%s could not be loaded from %s=%s (%s)",
                        display_name, env_variable, override, reason != NULL ? reason : "unknown error");
            return 0;
        }
        snprintf(library->path, sizeof library->path, "%s", override);
        return 1;
    }

    for (size_t i = 0; candidates[i] != NULL; i++) {
        library->handle = dlopen(candidates[i], RTLD_NOW | RTLD_LOCAL);
        if (library->handle != NULL) {
            snprintf(library->path, sizeof library->path, "%s", candidates[i]);
            return 1;
        }
    }
    cic_message(message, message_size, "%s is not installed (or not on the library search path)", display_name);
    return 0;
}

void *cic_symbol(const cic_library *library, const char *name) {
    if (library->handle == NULL) {
        return NULL;
    }
    return dlsym(library->handle, name);
}

void cic_resolve_path(cic_library *library, void *symbol) {
    Dl_info info;
    if (symbol != NULL && dladdr(symbol, &info) != 0 && info.dli_fname != NULL) {
        snprintf(library->path, sizeof library->path, "%s", info.dli_fname);
    }
}

#else /* !CIC_DYNAMIC_LOADING */

int cic_open_library(cic_library *library, const char *display_name, const char *env_variable,
                     const char *const *candidates, char *message, size_t message_size) {
    (void)env_variable;
    (void)candidates;
    library->handle = NULL;
    library->path[0] = '\0';
    cic_message(message, message_size, "%s can't be loaded on this platform (no run-time library loading)", display_name);
    return 0;
}

void *cic_symbol(const cic_library *library, const char *name) {
    (void)library;
    (void)name;
    return NULL;
}

void cic_resolve_path(cic_library *library, void *symbol) {
    (void)library;
    (void)symbol;
}

#endif /* CIC_DYNAMIC_LOADING */
