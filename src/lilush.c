// SPDX-FileCopyrightText: © 2024 Vladimir Zorin <vladimir@deviant.guru>
// SPDX-License-Identifier: GPL-3.0-or-later
#include <assert.h>
#include <libgen.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "lilush.h"
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>

#include "full.h"

void preload_modules(lua_State *const L) {
    assert(L != NULL);

    lua_gc(L, LUA_GCSTOP, 0);
    luaL_openlibs(L);
    lua_gc(L, LUA_GCRESTART, 0);

    lua_getglobal(L, "package");
    lua_getfield(L, -1, "preload");

    luaL_register(L, NULL, c_preload);

    for (size_t i = 0; lua_preload[i].name != NULL; i++) {
        int rc = luaL_loadbuffer(L, lua_preload[i].code, *lua_preload[i].size, lua_preload[i].name);
        if (rc != 0) {
            const char *err;

            switch (rc) {
            case LUA_ERRRUN:
                err = "runtime error";
                break;
            case LUA_ERRSYNTAX:
                err = "syntax error";
                break;
            case LUA_ERRMEM:
                err = "memory error";
                break;
            case LUA_ERRERR:
                err = "generic error";
                break;
            case LUA_ERRFILE:
                err = "file error";
                break;
            default:
                err = "unknown error";
                break;
            }

            fprintf(stderr, "%s: %s\n", lua_preload[i].name, err);
            exit(EXIT_FAILURE);
        }
        lua_setfield(L, -2, lua_preload[i].name);
    }
}

int main(int argc, char **argv) {
    int error;
    lua_State *L = luaL_newstate();
    preload_modules(L);

    char *cmd = basename(argv[0]);
    if (strcmp(cmd, "lilush") != 0 && strcmp(cmd, "-lilush") != 0) {
        lua_pushstring(L, cmd);
        lua_setglobal(L, "cmd");
        int args = argc - 1;
        lua_createtable(L, args, args);
        int i;
        for (i = 1; i < argc; i++) {
            lua_pushstring(L, argv[i]);
            lua_rawseti(L, -2, i);
        }
        lua_setglobal(L, "arg");
        error = luaL_dostring(L, EXEC_BUILTIN);
        if (error) {
            fprintf(stderr, "Error: %s\n", lua_tostring(L, -1));
            return 1;
        }
        return 0;
    }
    if (argc < 2) {
        error = luaL_dostring(L, START_SHELL);
        if (error) {
            fprintf(stderr, "Error: %s\n", lua_tostring(L, -1));
            return 1;
        }
        return 0;
    }

    if (strcmp(argv[1], "-c") == 0) {
        int args = argc - 2;
        lua_createtable(L, args, args);
        int i;
        for (i = 2; i < argc; i++) {
            lua_pushstring(L, argv[i]);
            lua_rawseti(L, -2, i - 1);
        }
        lua_setglobal(L, "arg");
        error = luaL_dostring(L, RUN_SHELL_CMD);
        if (error) {
            fprintf(stderr, "Error: %s\n", lua_tostring(L, -1));
            return 1;
        }
        return 0;
    }
    if (strcmp(argv[1], "-v") == 0) {
        fprintf(stdout, "version %s\n", LILUSH_VERSION);
        return 0;
    }

    if (!(access(argv[1], F_OK) == 0)) {
        fprintf(stderr, "File %s does not exist!\n", argv[1]);
        fprintf(stderr, "Usage: %s /path/to/a/script.lua\n", argv[0]);
        return 1;
    }

    // Set lilush package path first
    error = luaL_dostring(L, PRELOAD_INIT);
    if (error) {
        fprintf(stderr, "Error: %s\n", lua_tostring(L, -1));
        return 1;
    }

    int args = argc - 2;
    lua_createtable(L, args, args);
    int i;
    for (i = 2; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i - 1);
    }
    lua_setglobal(L, "arg");

    // And run the provided script
    error = luaL_dofile(L, argv[1]);
    if (error) {
        fprintf(stderr, "Error: %s\n", lua_tostring(L, -1));
        return 1;
    }
    return 0;
}
