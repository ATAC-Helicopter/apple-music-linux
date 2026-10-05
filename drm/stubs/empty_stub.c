/*
 * Placeholder for libandroid.so and libOpenSLES.so.
 *
 * Apple's Android libraries list both as dependencies (DT_NEEDED) but import no symbol from
 * either (checked with readelf --dyn-syms: zero undefined symbols resolve to them). The real
 * libraries are the NDK's window/input/sensor/asset API and OpenSL ES audio; they pull in the
 * whole Android graphics, binder and media stack (74 more libraries, ~50 MiB) just to satisfy
 * the loader. A host-side DRM client uses none of it, so the dynamic linker only needs to find
 * a library of that name. This one has no code and no dependencies.
 *
 * If a future Apple library starts importing a symbol from either one, loading it will fail
 * with "cannot locate symbol" and the real library has to come back.
 */
int aml_empty_stub;
