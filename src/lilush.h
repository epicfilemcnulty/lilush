#define LILUSH_VERSION "0.5.6-27-gf01061b"

static const char EXEC_BUILTIN[] = "local builtins = require('shell.builtins')\n"
                                   "local builtin = builtins.get(cmd)\n"
                                   "if builtin then\n"
                                   "  return builtin.func(builtin.name, arg)\n"
                                   "end\n"
                                   "print('no such builtin:' .. tostring(cmd))\n"
                                   "return -1";

static const char START_SHELL[] = "local sh = require('shell')\n"
                                  "local core = require('std.core')\n"
                                  "core.register_signal(2)\n"
                                  "local shell = sh.new() shell:run()";

static const char RUN_SHELL_CMD[] = "local sh = require('shell')\n"
                                    "local shell = sh.new_mini() shell:run()";

static const char PRELOAD_INIT[] = "local std = require('std')\n"
                                   "local home = os.getenv('HOME') or '/tmp'\n"
                                   "local lilush_modules_path = './?.lua;' .. home .. "
                                   "'/.local/share/lilush/packages/?.lua;' .. home .. "
                                   "'/.local/share/lilush/packages/?/init.lua;/usr/local/share/lilush/?.lua;/"
                                   "usr/local/share/lilush/?/init.lua'\n"
                                   "std.ps.setenv('LUA_PATH', lilush_modules_path)\n"
                                   "package.path = lilush_modules_path\n";
