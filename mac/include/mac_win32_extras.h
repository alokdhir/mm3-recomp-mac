/*
 * Win32/CRT calls the MM3 game layer uses beyond xboxrecomp's compat set,
 * for the macOS build. Implementations in mac/src/mac_win32_extras.c.
 */
#ifndef MM3_MAC_WIN32_EXTRAS_H
#define MM3_MAC_WIN32_EXTRAS_H

#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <wchar.h>

#define ERROR_INVALID_NAME 123u
#ifndef SYNCHRONIZE
#define SYNCHRONIZE 0x00100000L
#endif

/* MSVC's bounds-checked string copies: 0 on success, truncation is an error
 * and leaves an empty destination, as the MSVC CRT does (minus the handler). */
static inline int strcpy_s(char *dst, size_t size, const char *src)
{
    size_t n;
    if (!dst || !size) return 22;
    if (!src) { dst[0] = '\0'; return 22; }
    n = strlen(src);
    if (n >= size) { dst[0] = '\0'; return 34; }
    memcpy(dst, src, n + 1);
    return 0;
}

static inline int wcscpy_s(wchar_t *dst, size_t size, const wchar_t *src)
{
    size_t n;
    if (!dst || !size) return 22;
    if (!src) { dst[0] = L'\0'; return 22; }
    n = wcslen(src);
    if (n >= size) { dst[0] = L'\0'; return 34; }
    wmemcpy(dst, src, n + 1);
    return 0;
}

static inline int _putenv_s(const char *name, const char *value)
{
    return setenv(name, value, 1) == 0 ? 0 : 22;
}

static inline int _wcsicmp(const wchar_t *a, const wchar_t *b)
{
    return wcscasecmp(a, b);
}

/* Fault-free read of this process's memory (diagnostics probing pages a
 * concurrent free may have released). hProcess must be the current process. */
int ReadProcessMemory(void *process, const void *address, void *buffer,
                      size_t size, size_t *read);

#endif
