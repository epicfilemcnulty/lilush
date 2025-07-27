// SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
// SPDX-License-Identifier: GPL-3.0-or-later

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <lauxlib.h>
#include <lua.h>

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
    // Get arguments from Lua stack
    const char *name = luaL_checkstring(L, 1);
    size_t data_len;
    const char *data = luaL_checklstring(L, 2, &data_len);

    // Create shared memory object
    int fd = shm_open(name, O_CREAT | O_RDWR, 0666);
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

    if (pipe(pipefd) == -1) {
        RETURN_ERR(L);
    }

    lua_newtable(L);
    lua_pushinteger(L, pipefd[0]);
    lua_setfield(L, -2, "out");
    lua_pushinteger(L, pipefd[1]);
    lua_setfield(L, -2, "inn");

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

        size_t total_bytes_read = 0;
        while ((bytes_read = read(fd, buffer + total_bytes_read, buffer_size - total_bytes_read)) > 0) {
            total_bytes_read += bytes_read;

            if (total_bytes_read == buffer_size) {
                buffer_size *= 2;
                buffer = (char *)realloc(buffer, buffer_size);
            }
        }

        if (bytes_read < 0) {
            RETURN_ERR(L);
        }
        lua_pushlstring(L, buffer, total_bytes_read);
    } else {
        buffer     = (char *)malloc(count);
        bytes_read = read(fd, buffer, count);
        if (bytes_read < 0) {
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

int deviant_open(lua_State *L) {

    int fd;
    const char *pathname = luaL_checkstring(L, 1);
    int mode             = luaL_optinteger(L, 2, 0);
    switch (mode) {
    case 0:
        fd = open(pathname, O_RDONLY, 0);
        break;
    case 1:
        fd = open(pathname, O_WRONLY | O_CREAT, 0644);
        break;
    case 2:
        fd = open(pathname, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        break;
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
        if WIFEXITED (status) {
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
    fd = open(path, O_RDONLY | O_DIRECTORY);
    if (fd == -1) {
        RETURN_ERR(L);
    }
    /* create result table */
    lua_newtable(L);
    for (;;) {
        nread = syscall(SYS_getdents, fd, buf, FLSD_BUF_SIZE);
        if (nread == -1) {
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
        char target[1024];
        ssize_t len = readlink(filename, target, sizeof(target) - 1);
        if (len == -1) {
            len = 0;
        }
        target[len] = '\0';
        lua_pushstring(L, target);
        return 1;
    }
    RETURN_CUSTOM_ERR(L, "not a link");
}

static luaL_Reg funcs[] = {
    {"clockticks",      deviant_clockticks             },
    {"kill",            deviant_kill                   },
    {"fork",            deviant_fork                   },
    {"dup",             deviant_dup                    },
    {"dup2",            deviant_dup2                   },
    {"pipe",            deviant_pipe                   },
    {"close",           deviant_close                  },
    {"open",            deviant_open                   },
    {"create_shm",      deviant_create_shm             },
    {"read",            deviant_read                   },
    {"write",           deviant_write                  },
    {"getpid",          deviant_getpid                 },
    {"getpgid",         deviant_getpgid                },
    {"setpgid",         deviant_setpgid                },
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
    {"symlink",         deviant_symlink                },
    {NULL,              NULL                           }
};

int luaopen_deviant_core(lua_State *L) {

    /* Return the module */
    luaL_newlib(L, funcs);
    return 1;
}
