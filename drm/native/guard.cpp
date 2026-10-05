/*
 * guard.cpp — C++ exception barrier for calls into the Android FairPlay
 * libraries.  SVError (and friends) propagate as C++ exceptions through our C
 * frames; without a catch they reach the Go runtime and abort the process.
 */
#include <cstdio>
#include <exception>

extern "C" {
#include "drm_lib.h"
}

extern "C" void *aml_open_kd_ctx_guarded(const char *adam, const char *uri)
{
    try {
        return drm_lib_open_kd_ctx(adam, uri);
    } catch (const std::exception &e) {
        fprintf(stderr, "[guard] key context exception: %s\n", e.what());
    } catch (...) {
        fprintf(stderr, "[guard] key context: unknown C++ exception\n");
    }
    return nullptr;
}

extern "C" int aml_lib_init_guarded(const drm_lib_config_t *cfg)
{
    try {
        return drm_lib_init(cfg);
    } catch (const std::exception &e) {
        fprintf(stderr, "[guard] drm_lib_init exception: %s\n", e.what());
    } catch (...) {
        fprintf(stderr, "[guard] drm_lib_init: unknown C++ exception\n");
    }
    return -1;
}
