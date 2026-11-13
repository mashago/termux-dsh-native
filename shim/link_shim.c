/*
 * link_shim.c — Termux/Android `link(2)` compatibility shim for dsh.
 *
 * Android SELinux denies hard links in app-private storage with EACCES.  dsh
 * uses link(2) for atomic no-clobber publication (session logs, write tool,
 * attachment store).  This shim interposes libc link() and, only when the real
 * call fails with a platform link denial, publishes a copy instead.
 *
 * Semantics preserved:
 *   - EEXIST when newpath already exists (lstat arbitration; SELinux may return
 *     EACCES before link(2) checks the target);
 *   - source remains (copy, never rename);
 *   - atomic target publication (same-directory temp + fsync + renameat2
 *     RENAME_NOREPLACE);
 *   - EXDEV across filesystems;
 *   - directory source -> EPERM; symlink source -> copied as a symlink;
 *   - other errors propagate unchanged.
 *
 * Scope: the constructor removes LD_PRELOAD from the environment after the
 * loader has mapped this library.  The shim stays active in the current
 * process, but child processes (notably bionic Termux tools such as bash, git
 * and coreutils) never inherit a glibc-built preload.
 *
 * Build: aarch64-unknown-linux-gnu-gcc -shared -fPIC -O2 ...
 * Debug: DSH_LINK_SHIM_DEBUG=1 logs fallback decisions to stderr.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1 << 0)
#endif

#ifndef SYS_renameat2
/* aarch64 uses the generic syscall table: renameat2 is 276. */
#define SYS_renameat2 276
#endif

#ifndef SYS_copy_file_range
/* Not all headers expose it; read/write fallback is used when absent. */
#endif

typedef int (*real_link_fn)(const char *, const char *);

static real_link_fn real_link;
static int debug_enabled = -1;

static int shim_debug(void) {
    if (debug_enabled < 0) {
        const char *v = getenv("DSH_LINK_SHIM_DEBUG");
        debug_enabled = (v != NULL && v[0] != '\0' && v[0] != '0') ? 1 : 0;
    }
    return debug_enabled;
}

#define SHIM_LOG(...)                                                          \
    do {                                                                       \
        if (shim_debug()) {                                                    \
            dprintf(STDERR_FILENO, "dsh-link-shim: " __VA_ARGS__);             \
            dprintf(STDERR_FILENO, "\n");                                      \
        }                                                                      \
    } while (0)

static void init_real_link(void) {
    if (real_link != NULL) return;
    int saved = errno;
    void *sym = dlsym(RTLD_NEXT, "link");
    real_link = (real_link_fn)sym;
    errno = saved;
    if (real_link == NULL) {
        SHIM_LOG("dlsym(RTLD_NEXT, \"link\") failed: %s", dlerror());
    }
}

__attribute__((constructor)) static void dsh_link_shim_init(void) {
    init_real_link();
    /* Loader has already mapped us; this only affects future exec() children. */
    unsetenv("LD_PRELOAD");
    SHIM_LOG("loaded (real_link=%p)", (void *)real_link);
}

static int is_link_denial(int err) {
    return err == EACCES || err == EPERM || err == ENOTSUP || err == EOPNOTSUPP;
}

/* Return a heap-allocated directory containing path; caller frees. */
static char *dir_of(const char *path) {
    char *copy = strdup(path);
    if (copy == NULL) return NULL;
    char *slash = strrchr(copy, '/');
    if (slash == NULL) {
        free(copy);
        return strdup(".");
    }
    if (slash == copy) {
        slash[1] = '\0';
        return copy;
    }
    *slash = '\0';
    return copy;
}

/* Build "<dir>/.dsh-link-XXXXXX" and create a unique temp file. */
static char *make_temp(const char *dir, int *fd_out) {
    static const char suffix[] = "/.dsh-link-XXXXXX";
    size_t len = strlen(dir) + sizeof(suffix) + 1;
    char *tmpl = malloc(len);
    if (tmpl == NULL) return NULL;
    snprintf(tmpl, len, "%s%s", dir, suffix);
    int fd = mkstemp(tmpl);
    if (fd < 0) {
        int err = errno;
        free(tmpl);
        errno = err;
        return NULL;
    }
    *fd_out = fd;
    return tmpl;
}

static int copy_fd_read_write(int in, int out) {
    char buf[64 * 1024];
    for (;;) {
        ssize_t n = read(in, buf, sizeof(buf));
        if (n == 0) return 0;
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(out, buf + off, (size_t)(n - off));
            if (w < 0) {
                if (errno == EINTR) continue;
                return -1;
            }
            off += w;
        }
    }
}

static int copy_fd(int in, int out) {
#ifdef SYS_copy_file_range
    for (;;) {
        errno = 0;
        long n = syscall(SYS_copy_file_range, in, NULL, out, NULL,
                         (size_t)(1024 * 1024), 0u);
        if (n == 0) return 0;
        if (n > 0) continue;
        if (errno == EINTR) continue;
        /* Unsupported or not applicable: fall back to portable copy. */
        if (errno == ENOSYS || errno == EINVAL || errno == EXDEV ||
            errno == EOPNOTSUPP || errno == ENOTSUP || errno == EPERM) {
            break;
        }
        return -1;
    }
#endif
    return copy_fd_read_write(in, out);
}

static int copy_regular(const char *oldpath, const struct stat *st,
                        const char *tmp, int tmp_fd) {
    int src = open(oldpath, O_RDONLY | O_CLOEXEC);
    if (src < 0) return -1;
    int rc = copy_fd(src, tmp_fd);
    if (rc == 0) rc = fchmod(tmp_fd, st->st_mode & 07777);
    if (rc == 0) {
        struct timespec times[2];
        times[0] = st->st_atim;
        times[1] = st->st_mtim;
        /* Best effort: timestamp preservation is not required for correctness. */
        (void)futimens(tmp_fd, times);
    }
    if (rc == 0) rc = fsync(tmp_fd);
    int saved = errno;
    if (close(src) != 0 && rc == 0) {
        saved = errno;
        rc = -1;
    }
    if (rc != 0) errno = saved;
    return rc;
}

static int copy_symlink(const char *oldpath, const struct stat *st,
                        const char *tmp) {
    size_t cap = st->st_size > 0 ? (size_t)st->st_size + 1 : PATH_MAX;
    char *target = malloc(cap);
    if (target == NULL) return -1;
    ssize_t n = readlink(oldpath, target, cap - 1);
    if (n < 0) {
        int err = errno;
        free(target);
        errno = err;
        return -1;
    }
    target[n] = '\0';
    if (unlink(tmp) != 0) {
        int err = errno;
        free(target);
        errno = err;
        return -1;
    }
    int rc = symlink(target, tmp);
    int saved = errno;
    free(target);
    if (rc != 0) errno = saved;
    return rc;
}

/* Publish temp at newpath; never replace an existing name. */
static int publish_temp(const char *tmp, const char *newpath) {
    long rc = syscall(SYS_renameat2, AT_FDCWD, tmp, AT_FDCWD, newpath,
                      (unsigned int)RENAME_NOREPLACE);
    if (rc == 0) return 0;
    int err = errno;
    (void)unlink(tmp);
    if (err == EEXIST) {
        errno = EEXIST;
    } else if (err == ENOSYS || err == EINVAL) {
        /* Fail closed: a blind rename() would clobber a concurrent creator. */
        errno = EOPNOTSUPP;
    } else {
        errno = err;
    }
    return -1;
}

static int fallback_copy(const char *oldpath, const char *newpath,
                         const struct stat *st, int original_errno) {
    struct stat target;
    if (lstat(newpath, &target) == 0) {
        errno = EEXIST;
        return -1;
    }
    if (errno != ENOENT) {
        errno = original_errno;
        return -1;
    }

    char *dir = dir_of(newpath);
    if (dir == NULL) {
        errno = ENOMEM;
        return -1;
    }
    struct stat dir_st;
    if (stat(dir, &dir_st) != 0) {
        int err = errno;
        free(dir);
        errno = err;
        return -1;
    }
    if (dir_st.st_dev != st->st_dev) {
        free(dir);
        errno = EXDEV;
        return -1;
    }

    int tmp_fd = -1;
    char *tmp = make_temp(dir, &tmp_fd);
    free(dir);
    if (tmp == NULL) return -1;

    int rc;
    if (S_ISLNK(st->st_mode)) {
        if (close(tmp_fd) != 0) {
            int err = errno;
            (void)unlink(tmp);
            free(tmp);
            errno = err;
            return -1;
        }
        rc = copy_symlink(oldpath, st, tmp);
    } else {
        rc = copy_regular(oldpath, st, tmp, tmp_fd);
        int close_err = errno;
        if (close(tmp_fd) != 0 && rc == 0) {
            close_err = errno;
            rc = -1;
        }
        if (rc != 0) errno = close_err;
    }
    int saved = errno;
    if (rc == 0) {
        rc = publish_temp(tmp, newpath);
        saved = errno;
        free(tmp);
        if (rc != 0) errno = saved;
        return rc;
    }
    (void)unlink(tmp);
    free(tmp);
    errno = saved;
    return -1;
}

int link(const char *oldpath, const char *newpath) {
    init_real_link();
    if (real_link == NULL) {
        errno = ENOSYS;
        return -1;
    }

    int rc = real_link(oldpath, newpath);
    if (rc == 0) return 0;

    int original_errno = errno;
    if (!is_link_denial(original_errno)) {
        errno = original_errno;
        return -1;
    }

    struct stat st;
    if (lstat(oldpath, &st) != 0) {
        errno = original_errno;
        return -1;
    }
    if (S_ISDIR(st.st_mode)) {
        errno = EPERM;
        return -1;
    }
    if (!S_ISREG(st.st_mode) && !S_ISLNK(st.st_mode)) {
        errno = original_errno;
        return -1;
    }

    SHIM_LOG("link(%s, %s) denied (%d); fallback copy", oldpath, newpath,
             original_errno);
    rc = fallback_copy(oldpath, newpath, &st, original_errno);
    if (rc == 0) {
        SHIM_LOG("link(%s, %s) published copy", oldpath, newpath);
    } else {
        SHIM_LOG("link(%s, %s) copy failed: errno=%d", oldpath, newpath, errno);
    }
    return rc;
}