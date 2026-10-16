/*
 * mm3_asset_cache_posix.c -- mm3_asset_cache_refresh for POSIX hosts.
 *
 * The same check as the Win32 original (mm3_asset_cache.c): the game keeps a
 * copy of D:\Data\Data_hd.zip on its utility drive (Z:) and trusts it by
 * creation time. A stale copy -- different bytes, or a creation time in a
 * different two-second bucket from the source's -- is deleted so the game
 * rebuilds it. Symlinks are refused at every path component, the analogue of
 * the original's reparse-point check, and any I/O error leaves the cache
 * alone.
 *
 * The bucket is taken from st_ctime because that is what the POSIX kernel
 * layer reports to the guest as CreationTime (kernel_file.c).
 */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <windows.h>
#include "kernel.h"
#include "mm3_asset_cache.h"

#define MM3_CACHE_BLOCK_SIZE (64u * 1024u)

static void cache_error(const char *operation)
{
    fprintf(stderr, "[MM3_ASSET_CACHE] %s; cache unchanged (errno=%d)\n",
            operation, errno);
}

/* 0 if missing (*missing set), 1 if every component is a plain directory and
 * the leaf a regular file, -1 otherwise. */
static int ordinary_path(const char *path, int *missing)
{
    char component[PATH_MAX];
    struct stat st;
    int leaf = 1;

    *missing = 0;
    if (strlen(path) >= sizeof component || path[0] != '/') {
        errno = EINVAL;
        cache_error("archive path is not absolute");
        return -1;
    }
    strcpy(component, path);
    while (component[0] && strcmp(component, "/") != 0) {
        char *slash;
        if (lstat(component, &st) != 0) {
            if (leaf && errno == ENOENT) {
                *missing = 1;
                return 0;
            }
            cache_error("cannot inspect archive path");
            return -1;
        }
        if (S_ISLNK(st.st_mode) || (leaf && !S_ISREG(st.st_mode))) {
            errno = EINVAL;
            cache_error("archive path is not an ordinary file");
            return -1;
        }
        slash = strrchr(component, '/');
        if (slash == component) slash[1] = '\0';
        else *slash = '\0';
        leaf = 0;
    }
    return 1;
}

static int read_block(int fd, unsigned char *data, size_t *length)
{
    *length = 0;
    while (*length < MM3_CACHE_BLOCK_SIZE) {
        ssize_t n = read(fd, data + *length, MM3_CACHE_BLOCK_SIZE - *length);
        if (n < 0) {
            if (errno == EINTR) continue;
            return 0;
        }
        if (!n) break;
        *length += (size_t)n;
    }
    return 1;
}

/* The whole stream is read even after a mismatch, so a late read error is
 * not taken as proof of staleness. */
static int compare_archives(int source, int cache)
{
    static unsigned char source_data[MM3_CACHE_BLOCK_SIZE];
    static unsigned char cache_data[MM3_CACHE_BLOCK_SIZE];
    int different = 0;

    for (;;) {
        size_t source_length, cache_length;
        if (!read_block(source, source_data, &source_length) ||
            !read_block(cache, cache_data, &cache_length)) {
            cache_error("cannot read archives");
            return -1;
        }
        if (source_length != cache_length ||
            memcmp(source_data, cache_data,
                   source_length < cache_length ? source_length : cache_length))
            different = 1;
        if (!source_length && !cache_length) return different;
    }
}

void mm3_asset_cache_refresh(void)
{
    char translated_source[PATH_MAX], translated_cache[PATH_MAX];
    char source_path[PATH_MAX], cache_path[PATH_MAX];
    struct stat source_info, cache_info;
    int missing, source = -1, cache = -1, different = -1, metadata_different = 0;

    if (!xbox_translate_path("D:\\Data\\Data_hd.zip", translated_source, PATH_MAX) ||
        !xbox_translate_path("Z:\\Data\\Data_hd.zip", translated_cache, PATH_MAX)) {
        errno = EINVAL;
        cache_error("cannot resolve archive paths");
        return;
    }
    /* realpath resolves symlinks; the lstat walk below is over the
     * absolute, unresolved form, so a link anywhere is still refused. */
    if (!realpath(translated_source, source_path)) {
        if (errno == ENOENT) cache_error("source archive is missing");
        else cache_error("cannot resolve source archive path");
        return;
    }
    if (translated_cache[0] != '/') {
        char cwd[PATH_MAX];
        if (!getcwd(cwd, sizeof cwd) ||
            snprintf(cache_path, sizeof cache_path, "%s/%s", cwd,
                     translated_cache) >= (int)sizeof cache_path) {
            cache_error("cannot resolve cache archive path");
            return;
        }
    } else {
        snprintf(cache_path, sizeof cache_path, "%s", translated_cache);
    }
    if (strcmp(source_path, cache_path) == 0) {
        errno = EINVAL;
        cache_error("source and cache resolve to the same path");
        return;
    }
    if (ordinary_path(cache_path, &missing) <= 0) return;
    if (ordinary_path(source_path, &missing) <= 0) {
        if (missing) cache_error("source archive is missing");
        return;
    }
    source = open(source_path, O_RDONLY | O_NOFOLLOW);
    if (source < 0) {
        cache_error("cannot open source archive");
        return;
    }
    cache = open(cache_path, O_RDONLY | O_NOFOLLOW);
    if (cache < 0) {
        cache_error("cannot open cached archive");
        goto close_files;
    }
    if (fstat(source, &source_info) != 0 || fstat(cache, &cache_info) != 0) {
        cache_error("cannot inspect open archives");
        goto close_files;
    }
    if (!S_ISREG(source_info.st_mode) || !S_ISREG(cache_info.st_mode)) {
        errno = EINVAL;
        cache_error("open archive is not an ordinary file");
        goto close_files;
    }
    if (source_info.st_dev == cache_info.st_dev &&
        source_info.st_ino == cache_info.st_ino) {
        errno = EINVAL;
        cache_error("source and cache refer to the same file");
        goto close_files;
    }
    different = compare_archives(source, cache);
    /* FILETIME ticks / 20,000,000 is whole seconds / 2. */
    if (different == 0 && source_info.st_ctime / 2 != cache_info.st_ctime / 2) {
        different = 1;
        metadata_different = 1;
    }

close_files:
    if (cache >= 0 && close(cache) != 0) {
        cache_error("cannot close cached archive");
        different = -1;
    }
    if (close(source) != 0) {
        cache_error("cannot close source archive");
        different = -1;
    }
    if (different == 1) {
        if (unlink(cache_path) == 0)
            fprintf(stderr, "[MM3_ASSET_CACHE] stale Data_hd.zip invalidated (%s); retail startup will rebuild it\n",
                    metadata_different ? "creation-time metadata" : "archive contents");
        else
            cache_error("cannot invalidate stale cached archive");
    }
}
