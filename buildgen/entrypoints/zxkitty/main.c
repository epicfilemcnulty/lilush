int main(int argc, char **argv) {
    int error;
    lua_State *L = luaL_newstate();
    preload_modules(L);

    if (argc > 1) {
        if (strcmp(argv[1], "-v") == 0) {
            fprintf(stdout, "version {{VERSION}}\n");
            return 0;
        }
        int args = argc - 1;
        lua_createtable(L, args, args);
        int i;
        for (i = 1; i < argc; i++) {
            lua_pushstring(L, argv[i]);
            lua_rawseti(L, -2, i);
        }
        lua_setglobal(L, "arg");
        error = luaL_dostring(L, START_CODE);
        if (error) {
            fprintf(stderr, "Error: %s\n", lua_tostring(L, -1));
            return 1;
        }
        return 0;
    }
    fprintf(stderr, "Provide a path to TZX/TAP/Z80 file\n");
    return 1;
}
