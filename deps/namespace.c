/* SPDX-License-Identifier: MIT
 * Loaded only inside SCIP.jl's private glibc namespace, never via LD_PRELOAD.
 * glibc cannot promote dlopen dependencies to RTLD_GLOBAL in a new namespace.
 * oneTBB requests that flag when opening its allocator. Keep dynamically loaded
 * plugins local to their load group instead; returned handles still support
 * dlsym. No allocator, solver parameter, or arithmetic function is replaced.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>

void *dlopen(const char *name, int flags)
{
    void *(*open_library)(const char *, int) = dlsym(RTLD_NEXT, "dlopen");
    if (!open_library)
        abort();
    return open_library(name, flags & ~RTLD_GLOBAL);
}
