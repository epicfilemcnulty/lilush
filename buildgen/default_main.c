int main(int argc, char **argv) {
    int error;
    lua_State *L = luaL_newstate();
    preload_modules(L);

    if (argc > 1) {
        if (strcmp(argv[1], "-v") == 0) {
            fprintf(stdout, "version {{VERSION}}\n");
            return 0;
        }
        fprintf(stderr, "Unknown argument\n");
        return 1;
    }

    error = luaL_dostring(L, START_CODE);
    if (error) {
        fprintf(stderr, "Error: %s\n", lua_tostring(L, -1));
        return 1;
    }
    return 0;
}
