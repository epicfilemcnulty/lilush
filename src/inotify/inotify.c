// SPDX-FileCopyrightText: © 2022—2026 Vladimir Zorin <vladimir@deviant.guru>
// SPDX-License-Identifier: LicenseRef-OWL-1.0-or-later OR GPL-3.0-or-later
// Dual-licensed under OWL v1.0+ and GPLv3+. See LICENSE and LICENSE-GPL3.

#include <lauxlib.h>
#include <lua.h>

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <unistd.h>

#define INOTIFY_MT "inotify.handle"

struct inotify_handle {
    int fd;
};

static struct inotify_handle *check_handle(lua_State *L) {
    struct inotify_handle *h = (struct inotify_handle *)luaL_checkudata(L, 1, INOTIFY_MT);
    if (h->fd < 0)
        luaL_error(L, "inotify handle is closed");
    return h;
}

/* inotify.new([nonblock:boolean]) */
static int l_inotify_new(lua_State *L) {
    int nonblock = lua_toboolean(L, 1);
    int fd       = inotify_init();
    if (fd < 0) {
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        lua_pushinteger(L, errno);
        return 3;
    }

    if (nonblock) {
        int flags = fcntl(fd, F_GETFL, 0);
        if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
            int err = errno;
            close(fd);
            lua_pushnil(L);
            lua_pushstring(L, strerror(err));
            lua_pushinteger(L, err);
            return 3;
        }
    }

    struct inotify_handle *h = (struct inotify_handle *)lua_newuserdata(L, sizeof(*h));
    h->fd                    = fd;

    luaL_getmetatable(L, INOTIFY_MT);
    lua_setmetatable(L, -2);
    return 1;
}

/* handle:close() */
static int l_inotify_close(lua_State *L) {
    struct inotify_handle *h = (struct inotify_handle *)luaL_checkudata(L, 1, INOTIFY_MT);
    if (h->fd >= 0) {
        close(h->fd);
        h->fd = -1;
    }
    return 0;
}

/* __gc metamethod: same as close() */
static int l_inotify_gc(lua_State *L) {
    return l_inotify_close(L);
}

/* handle:addwatch(path, mask) -> wd */
static int l_inotify_addwatch(lua_State *L) {
    struct inotify_handle *h = check_handle(L);
    const char *path         = luaL_checkstring(L, 2);
    uint32_t mask;

    if (lua_isnoneornil(L, 3))
        mask = IN_ALL_EVENTS;
    else
        mask = (uint32_t)luaL_checkinteger(L, 3);

    int wd = inotify_add_watch(h->fd, path, mask);
    if (wd < 0) {
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        lua_pushinteger(L, errno);
        return 3;
    }

    lua_pushinteger(L, wd);
    return 1;
}

/* handle:rmwatch(wd) */
static int l_inotify_rmwatch(lua_State *L) {
    struct inotify_handle *h = check_handle(L);
    int wd                   = luaL_checkinteger(L, 2);

    if (inotify_rm_watch(h->fd, wd) < 0) {
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        lua_pushinteger(L, errno);
        return 3;
    }

    lua_pushboolean(L, 1);
    return 1;
}

/* handle:fileno() -> fd */
static int l_inotify_fileno(lua_State *L) {
    struct inotify_handle *h = check_handle(L);
    lua_pushinteger(L, h->fd);
    return 1;
}

/* handle:read() -> { {wd=..., mask=..., cookie=..., name=..., is_dir=...}, ...
 * }
 *
 * If fd is blocking (default), this blocks until at least one event.
 * If fd is non-blocking and no events are available:
 *   - returns empty table {}
 *   - on EAGAIN / EWOULDBLOCK
 *
 * On other errors: returns nil, err, errno.
 */
static int l_inotify_read(lua_State *L) {
    struct inotify_handle *h = check_handle(L);

    char buf[4096] __attribute__((aligned(__alignof__(struct inotify_event))));
    ssize_t len = read(h->fd, buf, sizeof(buf));

    if (len < 0) {
        int err = errno;
        if (err == EAGAIN || err == EWOULDBLOCK) {
            lua_newtable(L); // no events
            return 1;
        }
        lua_pushnil(L);
        lua_pushstring(L, strerror(err));
        lua_pushinteger(L, err);
        return 3;
    }

    if (len == 0) {
        // Should not really happen, but treat as "no events"
        lua_newtable(L);
        return 1;
    }

    lua_newtable(L);
    int idx = 1;

    for (char *ptr = buf; ptr < buf + len;) {
        struct inotify_event *ev = (struct inotify_event *)ptr;

        lua_pushinteger(L, idx++); // key on result table
        lua_newtable(L);           // event table

        lua_pushinteger(L, ev->wd);
        lua_setfield(L, -2, "wd");

        lua_pushinteger(L, ev->mask);
        lua_setfield(L, -2, "mask");

        lua_pushinteger(L, ev->cookie);
        lua_setfield(L, -2, "cookie");

        if (ev->len > 0 && ev->name[0] != '\0')
            lua_pushstring(L, ev->name);
        else
            lua_pushstring(L, "");
        lua_setfield(L, -2, "name");

        lua_pushboolean(L, (ev->mask & IN_ISDIR) != 0);
        lua_setfield(L, -2, "is_dir");

        lua_settable(L, -3); // result[key] = event

        ptr += sizeof(struct inotify_event) + ev->len;
    }

    return 1;
}

/* Register IN_* constants on module table (top of stack) */
static void set_constants(lua_State *L) {
    struct {
        const char *name;
        uint32_t value;
    } c[] = {
        {"IN_ACCESS",        IN_ACCESS       },
        {"IN_MODIFY",        IN_MODIFY       },
        {"IN_ATTRIB",        IN_ATTRIB       },
        {"IN_CLOSE_WRITE",   IN_CLOSE_WRITE  },
        {"IN_CLOSE_NOWRITE", IN_CLOSE_NOWRITE},
        {"IN_OPEN",          IN_OPEN         },
        {"IN_MOVED_FROM",    IN_MOVED_FROM   },
        {"IN_MOVED_TO",      IN_MOVED_TO     },
        {"IN_CREATE",        IN_CREATE       },
        {"IN_DELETE",        IN_DELETE       },
        {"IN_DELETE_SELF",   IN_DELETE_SELF  },
        {"IN_MOVE_SELF",     IN_MOVE_SELF    },
        {"IN_UNMOUNT",       IN_UNMOUNT      },
        {"IN_Q_OVERFLOW",    IN_Q_OVERFLOW   },
        {"IN_IGNORED",       IN_IGNORED      },
        {"IN_ONLYDIR",       IN_ONLYDIR      },
        {"IN_DONT_FOLLOW",   IN_DONT_FOLLOW  },
        {"IN_EXCL_UNLINK",   IN_EXCL_UNLINK  },
        {"IN_MASK_ADD",      IN_MASK_ADD     },
        {"IN_ISDIR",         IN_ISDIR        },
        {"IN_ONESHOT",       IN_ONESHOT      },
        {"IN_ALL_EVENTS",    IN_ALL_EVENTS   },
    };
    size_t n = sizeof(c) / sizeof(c[0]);
    for (size_t i = 0; i < n; i++) {
        lua_pushinteger(L, c[i].value);
        lua_setfield(L, -2, c[i].name);
    }
}

static const luaL_Reg inotify_methods[] = {
    {"addwatch", l_inotify_addwatch},
    {"rmwatch",  l_inotify_rmwatch },
    {"read",     l_inotify_read    },
    {"close",    l_inotify_close   },
    {"fileno",   l_inotify_fileno  },
    {NULL,       NULL              }
};

static const luaL_Reg inotify_functions[] = {
    {"new", l_inotify_new},
    {NULL,  NULL         }
};

int luaopen_inotify(lua_State *L) {
    /* metatable for handle */
    luaL_newmetatable(L, INOTIFY_MT);

    /* mt.__index = methods table */
    lua_newtable(L);
    luaL_register(L, NULL, inotify_methods);
    lua_setfield(L, -2, "__index");

    /* mt.__gc = gc */
    lua_pushcfunction(L, l_inotify_gc);
    lua_setfield(L, -2, "__gc");

    lua_pop(L, 1); // pop metatable

    /* module table */
    luaL_register(L, "inotify", inotify_functions);

    /* add constants to module table */
    set_constants(L);

    return 1;
}
