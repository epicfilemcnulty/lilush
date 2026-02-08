local std = require("std")
local home = os.getenv("HOME") or "/tmp"
local lilush_modules_path = "./?.lua;"
	.. home
	.. "/.local/share/lilush/packages/?.lua;"
	.. home
	.. "/.local/share/lilush/packages/?/init.lua;/usr/local/share/lilush/?.lua;/usr/local/share/lilush/?/init.lua"
std.ps.setenv("LUA_PATH", lilush_modules_path)
package.path = lilush_modules_path
