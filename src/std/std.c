// SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
// SPDX-License-Identifier: GPL-3.0-or-later

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>

extern char **environ;

#define RETURN_ERR(L)                       \
    do {                                    \
        lua_pushnil(L);                     \
        lua_pushstring(L, strerror(errno)); \
        return 2;                           \
    } while (0)
#define RETURN_CUSTOM_ERR(L, msg) \
    do {                          \
        lua_pushnil(L);           \
        lua_pushstring(L, msg);   \
        return 2;                 \
    } while (0)

static void handle_signal(int signum) {
    /* We could do something
       here, but who has the time?..
    */
}

// Lua function to register a signal handler
static int deviant_register_signal_handler(lua_State *L) {
    int signum = luaL_checkinteger(L, 1);
    signal(signum, handle_signal);
    return 0;
}

static int deviant_remove_signal_handler(lua_State *L) {
    int signum = luaL_checkinteger(L, 1);
    // Remove the signal handler for the given signal
    signal(signum, SIG_DFL);
    return 0;
}

int deviant_clockticks(lua_State *L) {
    int clk_tck = sysconf(_SC_CLK_TCK);
    lua_pushinteger(L, clk_tck);
    return 1;
}

int deviant_sleep(lua_State *L) {

    int seconds = luaL_checkint(L, 1);
    sleep(seconds);
    return 0;
}

static int deviant_create_shm(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    size_t data_len;
    const char *data = luaL_checklstring(L, 2, &data_len);

    // Create shared memory object
    int fd = shm_open(name, O_CREAT | O_RDWR | O_CLOEXEC, 0666);
    if (fd == -1) {
        RETURN_ERR(L);
    }
    // Set size
    if (ftruncate(fd, data_len) == -1) {
        close(fd);
        shm_unlink(name);
        RETURN_ERR(L);
    }

    // Map memory
    void *ptr = mmap(NULL, data_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (ptr == MAP_FAILED) {
        close(fd);
        shm_unlink(name);
        RETURN_ERR(L);
    }

    // Copy data
    memcpy(ptr, data, data_len);

    // Cleanup
    munmap(ptr, data_len);
    close(fd);

    // Return success
    lua_pushinteger(L, 0);
    return 1;
}

int deviant_sleep_ms(lua_State *L) {

    int milliseconds = luaL_checkint(L, 1);
    struct timespec ts;
    int res;

    ts.tv_sec  = milliseconds / 1000;
    ts.tv_nsec = (milliseconds % 1000) * 1000000;

    do {
        res = nanosleep(&ts, &ts);
    } while (res && errno == EINTR);
    return 0;
}

int deviant_kill(lua_State *L) {

    pid_t pid = luaL_checkint(L, 1);
    int sig   = luaL_checkint(L, 2);

    int ret = kill(pid, sig);
    if (ret == 0) {
        lua_pushboolean(L, 1);
        return 1;
    } else {
        RETURN_ERR(L);
    }
}

int deviant_getpid(lua_State *L) {
    pid_t pid = getpid();
    lua_pushinteger(L, pid);
    return 1;
}

int deviant_fork(lua_State *L) {

    pid_t pid = fork();
    lua_pushinteger(L, pid);
    return 1;
}

int deviant_pipe(lua_State *L) {

    int pipefd[2];

    if (pipe2(pipefd, O_CLOEXEC) == -1) {
        RETURN_ERR(L);
    }

    lua_newtable(L);
    lua_pushinteger(L, pipefd[0]);
    lua_setfield(L, -2, "out");
    lua_pushinteger(L, pipefd[1]);
    lua_setfield(L, -2, "inn");

    return 1;
}

/*

LuaJIT does not expose the Lua 5.2+ `luaL_Stream` helpers or the `UDTYPE_IO_FILE` constructor
that the standard `io` library uses internally.

Creating a userdata and filling a FILE* via `fdopen` produces a userdata without the expected metatable/type,
so Lua-side `:write`/`:read` reject it as “FILE* expected, got userdata”.

The standard LuaJIT `io` library is the only code that can produce FILE* userdata
with the proper metatable (`LUA_FILEHANDLE` == "FILE*") and builtin methods.
We therefore need to route fd → io handle through the `io` module.

Reopening an existing fd through `/proc/self/fd/<n>` with `io.open(path, mode)` yields a
genuine Lua file handle while keeping buffering and mode consistent. Immediately closing
the original fd avoids leaks; the reopened handle owns the duplicated
descriptor created by `io.open`.

Another way to do this is via `io.tmpfile` + `dup2`.
It works, but creates a temporary file and extra syscalls, and can fail
if TMPDIR is not writable.
*/

// Push a Lua FILE* (via io.open) for an existing fd using /proc/self/fd
// Returns 1 on success (file userdata on stack), 0 on failure
static int push_fd_handle(lua_State *L, int fd, const char *mode) {
    char path[64];
    int len = snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
    if (len < 0 || (size_t)len >= sizeof(path)) {
        close(fd);
        return 0;
    }

    lua_getglobal(L, "io");
    lua_getfield(L, -1, "open");
    lua_remove(L, -2); // remove io table

    lua_pushlstring(L, path, (size_t)len);
    lua_pushstring(L, mode);

    if (lua_pcall(L, 2, 1, 0) != 0) {
        // call failed, pop error message
        lua_pop(L, 1);
        close(fd);
        return 0;
    }

    // io.open returns nil+err on failure
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        close(fd);
        return 0;
    }

    // io.open created a new fd; close the original to avoid leaks
    close(fd);
    return 1;
}

// Function to create a pipe with FILE*-based interface for
// pipe's ends
int deviant_pipe_file(lua_State *L) {
    int pipefd[2];

    if (pipe2(pipefd, O_CLOEXEC) == -1) {
        RETURN_ERR(L);
    }

    // Create table to hold both file handles
    lua_newtable(L);

    // Create read end as FILE* in "r" mode
    if (!push_fd_handle(L, pipefd[0], "r")) {
        close(pipefd[1]);
        lua_pop(L, 1); // pop the table
        RETURN_CUSTOM_ERR(L, "failed to create read end FILE* object");
    }
    lua_setfield(L, -2, "out");

    // Create write end as FILE* in "w" mode
    if (!push_fd_handle(L, pipefd[1], "w")) {
        // Note: pipefd[0] will be cleaned up by Lua GC
        lua_pop(L, 1); // pop the table
        RETURN_CUSTOM_ERR(L, "failed to create write end FILE* object");
    }
    lua_setfield(L, -2, "inn");

    return 1;
}

// Transforms a raw file descriptor into a Lua FILE* object
// Usage: file = core.fdopen(fd, mode)
// mode: "r" for read, "w" for write, "a" for append
// Returns FILE* object on success, nil + error message on failure
int deviant_fdopen(lua_State *L) {
    int fd           = luaL_checkinteger(L, 1);
    const char *mode = luaL_checkstring(L, 2);

    // Validate mode
    if (mode[0] != 'r' && mode[0] != 'w' && mode[0] != 'a') {
        lua_pushnil(L);
        lua_pushstring(L, "mode must be 'r', 'w', or 'a'");
        return 2;
    }

    if (!push_fd_handle(L, fd, mode)) {
        lua_pushnil(L);
        lua_pushstring(L, "failed to create FILE* from fd");
        return 2;
    }

    return 1;
}

int deviant_write(lua_State *L) {

    int fd             = luaL_checkinteger(L, 1);
    const char *buffer = luaL_checkstring(L, 2);
    size_t count       = luaL_optinteger(L, 3, strlen(buffer));

    ssize_t result = write(fd, buffer, count);

    if (result == -1) {
        RETURN_ERR(L);
    } else {
        lua_pushinteger(L, result);
        return 1;
    }
}

int deviant_read(lua_State *L) {

    int fd       = luaL_checkinteger(L, 1);
    size_t count = luaL_optinteger(L, 2, 0);

    char *buffer       = NULL;
    ssize_t bytes_read = 0;

    if (count == 0) {
        size_t buffer_size = 1024;
        buffer             = (char *)malloc(buffer_size);
        if (buffer == NULL) {
            RETURN_CUSTOM_ERR(L, "out of memory");
        }

        size_t total_bytes_read = 0;
        while ((bytes_read = read(fd, buffer + total_bytes_read, buffer_size - total_bytes_read)) > 0) {
            total_bytes_read += bytes_read;

            if (total_bytes_read >= buffer_size) {
                buffer_size *= 2;
                char *new_buffer = (char *)realloc(buffer, buffer_size);
                if (new_buffer == NULL) {
                    free(buffer);
                    RETURN_CUSTOM_ERR(L, "out of memory");
                }
                buffer = new_buffer;
            }
        }

        if (bytes_read < 0) {
            free(buffer);
            RETURN_ERR(L);
        }
        lua_pushlstring(L, buffer, total_bytes_read);
    } else {
        buffer = (char *)malloc(count);
        if (buffer == NULL) {
            RETURN_CUSTOM_ERR(L, "out of memory");
        }
        bytes_read = read(fd, buffer, count);
        if (bytes_read < 0) {
            free(buffer);
            RETURN_ERR(L);
        }
        lua_pushlstring(L, buffer, bytes_read);
    }

    free(buffer);
    return 1;
}

int deviant_cwd(lua_State *L) {

    char *buf = getcwd(NULL, 0);
    if (buf == NULL) {
        RETURN_ERR(L);
    }
    lua_pushstring(L, buf);
    free(buf);
    return 1;
}

int deviant_dup(lua_State *L) {

    int oldfd = luaL_checkint(L, 1);

    int fd = dup(oldfd);
    if (fd >= 0) {
        lua_pushinteger(L, fd);
        return 1;
    } else {
        RETURN_ERR(L);
    }
}

int deviant_dup2(lua_State *L) {

    int oldfd = luaL_checkint(L, 1);
    int newfd = luaL_checkint(L, 2);

    int fd = dup2(oldfd, newfd);
    if (fd >= 0) {
        lua_pushinteger(L, fd);
        return 1;
    } else {
        RETURN_ERR(L);
    }
}

int deviant_close(lua_State *L) {
    int fd  = luaL_checkint(L, 1);
    int ret = close(fd);
    if (ret >= 0) {
        lua_pushboolean(L, 1);
        return 1;
    } else {
        RETURN_ERR(L);
    }
}

int deviant_setpgid(lua_State *L) {

    pid_t pid  = luaL_optinteger(L, 1, 0);
    pid_t pgid = luaL_optinteger(L, 2, 0);
    int ret    = setpgid(pid, pgid);
    if (ret == -1) {
        RETURN_ERR(L);
    }
    lua_pushboolean(L, 1);
    return 1;
}

int deviant_getpgid(lua_State *L) {

    pid_t pid  = luaL_optinteger(L, 1, 0);
    pid_t pgid = getpgid(pid);
    if (pgid == -1) {
        RETURN_ERR(L);
    }
    lua_pushinteger(L, pgid);
    return 1;
}

int deviant_setsid(lua_State *L) {
    pid_t sid = setsid();
    if (sid == -1) {
        RETURN_ERR(L);
    }
    lua_pushinteger(L, sid);
    return 1;
}

int deviant_tcsetpgrp(lua_State *L) {
    int fd     = luaL_checkint(L, 1);
    pid_t pgid = luaL_checkint(L, 2);
    int ret    = tcsetpgrp(fd, pgid);
    if (ret == -1) {
        RETURN_ERR(L);
    }
    lua_pushboolean(L, 1);
    return 1;
}

int deviant_tcgetpgrp(lua_State *L) {
    int fd     = luaL_checkint(L, 1);
    pid_t pgid = tcgetpgrp(fd);
    if (pgid == -1) {
        RETURN_ERR(L);
    }
    lua_pushinteger(L, pgid);
    return 1;
}

int deviant_tiocstty(lua_State *L) {
    int fd  = luaL_checkint(L, 1);
    int ret = ioctl(fd, TIOCSCTTY, 0);
    if (ret == -1) {
        RETURN_ERR(L);
    }
    lua_pushboolean(L, 1);
    return 1;
}

// Allocate a new PTY master and return { master = fd, slave = "/dev/pts/N" }.
// Caller opens the slave path to create a controlling terminal for a child.
int deviant_pty_open(lua_State *L) {
    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master == -1) {
        RETURN_ERR(L);
    }
    if (grantpt(master) == -1) {
        close(master);
        RETURN_ERR(L);
    }
    if (unlockpt(master) == -1) {
        close(master);
        RETURN_ERR(L);
    }
    char *slave = ptsname(master);
    if (slave == NULL) {
        close(master);
        RETURN_ERR(L);
    }
    lua_newtable(L);
    lua_pushinteger(L, master);
    lua_setfield(L, -2, "master");
    lua_pushstring(L, slave);
    lua_setfield(L, -2, "slave");
    return 1;
}

// Pump I/O between STDIN/STDOUT and a PTY master fd until EOF or detach key.
// Returns true if detached via key, false on normal EOF.
int deviant_pty_attach(lua_State *L) {
    int master     = luaL_checkint(L, 1);
    int detach_key = luaL_optint(L, 2, 29);
    int detached   = 0;
    struct pollfd fds[2];
    char buf[4096];

    fds[0].fd     = STDIN_FILENO;
    fds[0].events = POLLIN;
    fds[1].fd     = master;
    fds[1].events = POLLIN;

    for (;;) {
        int ret = poll(fds, 2, -1);
        if (ret < 0) {
            if (errno == EINTR) {
                continue;
            }
            RETURN_ERR(L);
        }

        if (fds[0].revents & POLLIN) {
            ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
            if (n <= 0) {
                break;
            }
            for (ssize_t i = 0; i < n; i++) {
                if ((unsigned char)buf[i] == (unsigned char)detach_key) {
                    if (i > 0) {
                        if (write(master, buf, (size_t)i) < 0) {
                            RETURN_ERR(L);
                        }
                    }
                    detached = 1;
                    goto done;
                }
            }
            if (write(master, buf, (size_t)n) < 0) {
                if (errno == EIO) {
                    break;
                }
                RETURN_ERR(L);
            }
        }

        if (fds[1].revents & POLLIN) {
            ssize_t n = read(master, buf, sizeof(buf));
            if (n <= 0) {
                break;
            }
            if (write(STDOUT_FILENO, buf, (size_t)n) < 0) {
                RETURN_ERR(L);
            }
        }

        if (fds[1].revents & (POLLHUP | POLLERR)) {
            break;
        }
    }

done:
    lua_pushboolean(L, detached);
    return 1;
}

int deviant_open(lua_State *L) {

    int fd;
    const char *pathname = luaL_checkstring(L, 1);
    int mode             = luaL_optinteger(L, 2, 0);
    switch (mode) {
    case 0:
        fd = open(pathname, O_RDONLY | O_CLOEXEC, 0);
        break;
    case 1:
        fd = open(pathname, O_WRONLY | O_CREAT | O_CLOEXEC, 0644);
        break;
    case 2:
        fd = open(pathname, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        break;
    case 3:
        fd = open(pathname, O_RDWR | O_CLOEXEC, 0);
        break;
    case 4:
        fd = open(pathname, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
        break;
    case 5:
        fd = open(pathname, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
        break;
    case 6:
        fd = open(pathname, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
        break;
    default:
        RETURN_CUSTOM_ERR(L, "invalid mode (expected 0-6)");
    }
    if (fd == -1) {
        RETURN_ERR(L);
    }
    lua_pushinteger(L, fd);
    return 1;
}

int deviant_wait(lua_State *L) {

    pid_t pid, ret;
    pid = luaL_checkint(L, 1);
    int status;
    ret = waitpid(pid, &status, 0);
    if (ret >= 0) {
        lua_pushinteger(L, ret);
        if WIFEXITED (status) {
            lua_pushinteger(L, WEXITSTATUS(status));
            return 2;
        }
        return 1;
    } else {
        RETURN_ERR(L);
    }
}

int deviant_waitpid(lua_State *L) {

    pid_t pid, ret;
    pid = luaL_checkint(L, 1);
    int status;
    ret = waitpid(pid, &status, WNOHANG);
    if (ret >= 0) {
        lua_pushinteger(L, ret);
        if (WIFEXITED(status)) {
            lua_pushinteger(L, WEXITSTATUS(status));
            return 2;
        }
        return 1;
    } else {
        RETURN_ERR(L);
    }
}

int deviant_environ(lua_State *L) {

    lua_newtable(L);
    int i    = 0;
    char **s = environ;
    for (; *s; s++) {
        lua_pushstring(L, *s);
        lua_rawseti(L, -2, i + 1);
        i++;
    }
    return 1;
}

int deviant_setenv(lua_State *L) {

    const char *var_name = luaL_checkstring(L, 1);
    const char *value    = luaL_checkstring(L, 2);
    int ret;
    ret = setenv(var_name, value, 1);
    if (ret == 0) {
        lua_pushboolean(L, 1);
        return 1;
    } else {
        RETURN_ERR(L);
    }
}

int deviant_unsetenv(lua_State *L) {

    const char *var_name = luaL_checkstring(L, 1);
    int ret;
    ret = unsetenv(var_name);
    if (ret == 0) {
        lua_pushboolean(L, 1);
        return 1;
    } else {
        RETURN_ERR(L);
    }
}

int deviant_chdir(lua_State *L) {

    const char *pathname = luaL_checkstring(L, 1);
    int ret;
    ret = chdir(pathname);
    if (ret == 0) {
        lua_pushboolean(L, 1);
        return 1;
    } else {
        RETURN_ERR(L);
    }
}

int deviant_mkdir(lua_State *L) {
    const char *pathname = luaL_checkstring(L, 1);
    const char *mode_str = luaL_optstring(L, 2, "0777"); // Use "0777" as default mode if mode_str is not provided
    mode_t mode          = strtol(mode_str, NULL, 8);    // Convert mode string to octal integer
    if (mkdir(pathname, mode) == -1) {
        RETURN_ERR(L);
    }
    lua_pushboolean(L, 1);
    return 1;
}

int deviant_symlink(lua_State *L) {
    const char *source = luaL_checkstring(L, 1);
    const char *dest   = luaL_checkstring(L, 2);
    int result         = symlink(source, dest);
    if (result == -1) {
        RETURN_ERR(L);
    }
    lua_pushboolean(L, 1);
    return 1;
}

int deviant_file_remove(lua_State *L) {

    const char *pathname = luaL_checkstring(L, 1);
    int ret;
    ret = remove(pathname);
    if (ret == 0) {
        lua_pushboolean(L, 1);
        return 1;
    } else {
        RETURN_ERR(L);
    }
}

int deviant_file_rename(lua_State *L) {
    const char *src = luaL_checkstring(L, 1);
    const char *dst = luaL_checkstring(L, 2);
    int ret;
    ret = rename(src, dst);
    if (ret == 0) {
        lua_pushboolean(L, 1);
        return 1;
    } else {
        RETURN_ERR(L);
    }
}

int deviant_exec(lua_State *L) {

    int n = lua_gettop(L); /* number of arguments */
    int ret;

    if (n >= 1) {
        const char *pathname = luaL_checkstring(L, 1);
        char *args[n];
        if (n > 1) {
            for (int i = 1; i < n; i++) {
                args[i - 1] = (char *)luaL_checkstring(L, i + 1);
            }
            args[n - 1] = (char *)NULL;
        } else {
            args[0] = (char *)NULL;
        }

        ret = execvp(pathname, args);
        if (ret == -1) {
            RETURN_ERR(L);
        }

    } else {
        RETURN_CUSTOM_ERR(L, "no command given");
    }
    lua_pushboolean(L, 1);
    return 1;
}

/* See `Programming in Lua` :-)
 * https://www.lua.org/pil/26.1.html
 */
static int deviant_list_dir(lua_State *L) {

    const char *path = luaL_checkstring(L, 1);

    /* open directory */
    DIR *dir;
    dir = opendir(path);
    if (dir == NULL) { /* error opening the directory? */
        RETURN_ERR(L);
    }

    /* create result table */
    lua_newtable(L);
    struct dirent *entry;
    int i = 1;
    while ((entry = readdir(dir)) != NULL) {
        lua_pushnumber(L, i++);           /* push key */
        lua_pushstring(L, entry->d_name); /* push value */
        lua_settable(L, -3);
    }
    closedir(dir);
    return 1; /* table is already on top */
}

/*
 The code below, so called `fast_list_dir` is
 taken from https://github.com/aidenbell/getdents, mutatis mutandis.

 I did not see any significant difference in performance
 time between this code and the regular `list_dir` above
 when tested on a dir with 30k files, but maybe we need more
 files to actually notice it.

 For now I'm gonna stash the code here just in case...
*/
struct linux_dirent {
    long d_ino;
    off_t d_off;
    unsigned short d_reclen;
    char d_name[];
};

#define FLSD_BUF_SIZE 1024 * 1024 * 5

static int deviant_fast_list_dir(lua_State *L) {

    const char *path = luaL_checkstring(L, 1);
    int fd, nread;
    char buf[FLSD_BUF_SIZE];
    struct linux_dirent *d;
    int bpos;
    char d_type;

    /* open directory */
    fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd == -1) {
        RETURN_ERR(L);
    }
    /* create result table */
    lua_newtable(L);
    for (;;) {
        nread = syscall(SYS_getdents, fd, buf, FLSD_BUF_SIZE);
        if (nread == -1) {
            close(fd);
            RETURN_ERR(L);
        }
        if (nread == 0)
            break;

        for (bpos = 0; bpos < nread;) {
            d      = (struct linux_dirent *)(buf + bpos);
            d_type = *(buf + bpos + d->d_reclen - 1);
            if (d->d_ino != 0) {
                lua_pushstring(L, d->d_name); /* push key */
                lua_pushnumber(L, d_type);    /* push value */
                lua_settable(L, -3);
            }
            bpos += d->d_reclen;
        }
    }
    close(fd);
    return 1; /* table is already on top */
}

static int deviant_stat(lua_State *L) {

    const char *filename = luaL_checkstring(L, 1);

    struct stat st;
    if (lstat(filename, &st) == -1) {
        RETURN_ERR(L);
    }
    char *mode = "u";
    switch (st.st_mode & S_IFMT) {
    case S_IFREG:
        mode = "f";
        break;
    case S_IFDIR:
        mode = "d";
        break;
    case S_IFLNK:
        mode = "l";
        break;
    case S_IFSOCK:
        mode = "s";
        break;
    case S_IFBLK:
        mode = "b";
        break;
    case S_IFCHR:
        mode = "c";
        break;
    case S_IFIFO:
        mode = "p";
        break;
    }

    char perm_str[5];
    sprintf(perm_str, "%o",
            (st.st_mode & 0777)); // 0777 is an octal mask to get the file permissions

    lua_newtable(L);
    lua_pushstring(L, "mode");
    lua_pushstring(L, mode);
    lua_settable(L, -3);
    lua_pushstring(L, "size");
    lua_pushnumber(L, st.st_size);
    lua_settable(L, -3);
    lua_pushstring(L, "perms");
    lua_pushstring(L, perm_str);
    lua_settable(L, -3);
    lua_pushstring(L, "atime");
    lua_pushnumber(L, st.st_atime);
    lua_settable(L, -3);
    lua_pushstring(L, "uid");
    lua_pushnumber(L, st.st_uid);
    lua_settable(L, -3);
    lua_pushstring(L, "gid");
    lua_pushnumber(L, st.st_gid);
    lua_settable(L, -3);
    return 1;
}

static int deviant_readlink(lua_State *L) {

    const char *filename = luaL_checkstring(L, 1);
    struct stat file_stat;
    if (lstat(filename, &file_stat) == -1) {
        RETURN_ERR(L);
    }
    if (S_ISLNK(file_stat.st_mode)) {
        char *target = malloc(file_stat.st_size + 1);
        if (target == NULL) {
            RETURN_CUSTOM_ERR(L, "out of memory");
        }
        ssize_t len = readlink(filename, target, file_stat.st_size);
        if (len == -1) {
            free(target);
            RETURN_ERR(L);
        }
        target[len] = '\0';
        lua_pushstring(L, target);
        free(target);
        return 1;
    }
    RETURN_CUSTOM_ERR(L, "not a link");
}

// Helper function to serialize a float32 as raw bytes (little-endian)
static void write_float32_le(float value, uint8_t *out) {
    union {
        float f;
        uint32_t u;
    } v;

    v.f = value;

    out[0] = (uint8_t)(v.u & 0xFF);
    out[1] = (uint8_t)((v.u >> 8) & 0xFF);
    out[2] = (uint8_t)((v.u >> 16) & 0xFF);
    out[3] = (uint8_t)((v.u >> 24) & 0xFF);
}

// Serialize a 3D point coordinates x, y, z as a 12-byte binary string,
// essentially making it a vector, ready to be stored and searched using
// vector search
int deviant_packvec(lua_State *L) {
    float x = (float)luaL_checknumber(L, 1);
    float y = (float)luaL_checknumber(L, 2);
    float z = (float)luaL_checknumber(L, 3);

    uint8_t buf[12];

    write_float32_le(x, buf);
    write_float32_le(y, buf + 4);
    write_float32_le(z, buf + 8);

    lua_pushlstring(L, (const char *)buf, 12);
    return 1;
}

// Unserialize a vector of 3D point coordinates back into x, y, z
int deviant_unpackvec(lua_State *L) {
    size_t len;
    const uint8_t *buf = (const uint8_t *)luaL_checklstring(L, 1, &len);

    if (len != 12) {
        return luaL_error(L, "unpackvec: expected 12 bytes, got %zu", len);
    }

    union {
        uint32_t u;
        float f;
    } v;

    // x
    v.u     = (uint32_t)buf[0] | ((uint32_t)buf[1] << 8) | ((uint32_t)buf[2] << 16) | ((uint32_t)buf[3] << 24);
    float x = v.f;

    // y
    v.u     = (uint32_t)buf[4] | ((uint32_t)buf[5] << 8) | ((uint32_t)buf[6] << 16) | ((uint32_t)buf[7] << 24);
    float y = v.f;

    // z
    v.u     = (uint32_t)buf[8] | ((uint32_t)buf[9] << 8) | ((uint32_t)buf[10] << 16) | ((uint32_t)buf[11] << 24);
    float z = v.f;

    lua_pushnumber(L, x);
    lua_pushnumber(L, y);
    lua_pushnumber(L, z);
    return 3;
}

static luaL_Reg funcs[] = {
    {"clockticks",      deviant_clockticks             },
    {"kill",            deviant_kill                   },
    {"fork",            deviant_fork                   },
    {"dup",             deviant_dup                    },
    {"dup2",            deviant_dup2                   },
    {"pipe",            deviant_pipe                   },
    {"pipe_file",       deviant_pipe_file              },
    {"fdopen",          deviant_fdopen                 },
    {"close",           deviant_close                  },
    {"open",            deviant_open                   },
    {"create_shm",      deviant_create_shm             },
    {"read",            deviant_read                   },
    {"write",           deviant_write                  },
    {"getpid",          deviant_getpid                 },
    {"getpgid",         deviant_getpgid                },
    {"setpgid",         deviant_setpgid                },
    {"setsid",          deviant_setsid                 },
    {"tcsetpgrp",       deviant_tcsetpgrp              },
    {"tcgetpgrp",       deviant_tcgetpgrp              },
    {"tiocstty",        deviant_tiocstty               },
    {"pty_open",        deviant_pty_open               },
    {"pty_attach",      deviant_pty_attach             },
    {"waitpid",         deviant_waitpid                },
    {"register_signal", deviant_register_signal_handler},
    {"remove_signal",   deviant_remove_signal_handler  },
    {"wait",            deviant_wait                   },
    {"exec",            deviant_exec                   },
    {"sleep",           deviant_sleep                  },
    {"sleep_ms",        deviant_sleep_ms               },
    {"setenv",          deviant_setenv                 },
    {"unsetenv",        deviant_unsetenv               },
    {"environ",         deviant_environ                },
    {"chdir",           deviant_chdir                  },
    {"mkdir",           deviant_mkdir                  },
    {"cwd",             deviant_cwd                    },
    {"list_dir",        deviant_list_dir               },
    {"fast_list_dir",   deviant_fast_list_dir          },
    {"stat",            deviant_stat                   },
    {"readlink",        deviant_readlink               },
    {"remove",          deviant_file_remove            },
    {"rename",          deviant_file_rename            },
    {"symlink",         deviant_symlink                },
    {"pack3d",          deviant_packvec                },
    {"unpack3d",        deviant_unpackvec              },
    {NULL,              NULL                           }
};

int luaopen_deviant_core(lua_State *L) {
    /* Return the module */
    luaL_newlib(L, funcs);
    return 1;
}
