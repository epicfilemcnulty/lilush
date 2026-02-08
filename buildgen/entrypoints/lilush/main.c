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
    if (strcmp(argv[1], "-e") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Error: -e flag requires a Lua code argument\n");
            fprintf(stderr, "Usage: %s -e '<lua-code>'\n", argv[0]);
            return 1;
        }
        // Set lilush package path first
        error = luaL_dostring(L, PRELOAD_INIT);
        if (error) {
            fprintf(stderr, "Error: %s\n", lua_tostring(L, -1));
            return 1;
        }
        // Execute the Lua code from argv[2]
        error = luaL_dostring(L, argv[2]);
        if (error) {
            fprintf(stderr, "Error: %s\n", lua_tostring(L, -1));
            return 1;
        }
        return 0;
    }
    if (strcmp(argv[1], "-v") == 0) {
        fprintf(stdout, "version {{VERSION}}\n");
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
