local start_code = [[
static const char EXEC_BUILTIN[] = "math.randomseed(os.time())\n"
                                   "local builtins = require('shell.builtins')\n"
                                   "local builtin = builtins.get(cmd)\n"
                                   "if builtin then\n"
                                   "  return builtin.func(builtin.name, arg)\n"
                                   "end\n"
                                   "print('no such builtin:' .. tostring(cmd))\n"
                                   "return -1";
 
static const char START_SHELL[] = "math.randomseed(os.time())\n"
                                  "local sh = require('shell')\n"
                                  "local core = require('std.core')\n"
                                  "core.register_signal(2)\n"
                                  "local shell = sh.new() shell:run()";
 
static const char RUN_SHELL_CMD[] = "math.randomseed(os.time())\n"
                                    "local sh = require('shell')\n"
                                    "local shell = sh.new_mini() shell:run()";
 
static const char PRELOAD_INIT[] = "local std = require('std')\n"
                                   "local home = os.getenv('HOME') or '/tmp'\n"
                                   "local lilush_modules_path = './?.lua;' .. home .. "
                                   "'/.local/share/lilush/packages/?.lua;' .. home .. "
                                   "'/.local/share/lilush/packages/?/init.lua;/usr/local/share/lilush/?.lua;/"
                                   "usr/local/share/lilush/?/init.lua'\n"
                                   "std.ps.setenv('LUA_PATH', lilush_modules_path)\n"
                                   "package.path = lilush_modules_path\n";
]]

local custom_main = [[
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
]]

return {
	binary = "lilush",
	luamods = {
		"luasocket",
		"std",
		"crypto",
		"term",
		"text",
		"djot",
		"redis",
		"shell",
		"vault",
		"dns",
		"argparser",
		"acme",
	},
	c_libs = {
		"cjson",
		"inotify",
		"luasocket",
		"std",
		"crypto",
		"term",
		"wireguard",
	},
	install_path = "/usr/bin/lilush",
	start_code = start_code,
	custom_main = custom_main,
}
