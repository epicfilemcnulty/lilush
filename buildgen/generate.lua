#!/usr/bin/lilush

local std = require("std")

local show_output = function(out, msg)
	print("==========================================")
	print(msg)
	print("==========================================")
	print("STDOUT:")
	print("-------")
	print(table.concat(out.stdout, "\n"))
	print("STDERR:")
	print("-------")
	print(table.concat(out.stderr, "\n"))
	print("-------")
	print("STATUS: " .. out.status)
end

std.ps.unsetenv("LUA_PATH")
package.path =
	"./?.lua;/usr/share/luajit-2.1/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua"

local regular_main = [[
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
]]

local mod_to_header = function(filepath, rel_path)
	-- Convert relative path to module name format: shell/theme.lua -> shell.theme
	local mod_base = rel_path:gsub("%.lua$", ""):gsub("/", ".")
	local mod_name = "mod_lua_" .. mod_base .. ".h"
	-- For C identifiers, dots become underscores: shell.theme -> shell_theme
	local c_ident = mod_base:gsub("%.", "_")

	std.ps.exec_simple("luajit -b -n " .. c_ident .. " " .. filepath .. " " .. mod_name)
	local content = std.fs.read_file(mod_name)
	content = content:gsub("#define luaJIT_BC_" .. c_ident, "const size_t mod_lua_" .. c_ident)
	content = content:gsub("_SIZE (%d+)", "_SIZE=%1;")
	content = content:gsub("static const unsigned char luaJIT_BC_" .. c_ident, "static const char mod_lua_" .. c_ident)
	std.fs.write_file(mod_name, content)
end

local list_lua_files_recursive
list_lua_files_recursive = function(dir, base_dir)
	local results = {}
	local items = std.fs.list_dir(dir)
	if not items then
		return results
	end

	for _, item in ipairs(items) do
		if item ~= "." and item ~= ".." then
			local full_path = dir .. "/" .. item
			local st = std.fs.stat(full_path)
			if st then
				if st.mode == "d" then
					-- Recurse into subdirectory
					local sub_results = list_lua_files_recursive(full_path, base_dir)
					for rel_path, _ in pairs(sub_results) do
						results[rel_path] = true
					end
				elseif st.mode == "f" and item:match("%.lua$") then
					-- Calculate relative path from base_dir
					local rel_path = full_path:gsub("^" .. base_dir:gsub("%-", "%%-") .. "/", "")
					results[rel_path] = true
				elseif st.mode == "l" then
					-- Skip symlinks (they'll be removed)
				end
			end
		end
	end
	return results
end

local app_config_file = arg[1] or ""
if not std.fs.file_exists(app_config_file) then
	print("Can't read app config file")
	os.exit(-1)
end

local app_config, err = dofile(app_config_file)
if err then
	print("Can't parse app config: " .. err)
	os.exit(-1)
end

local modinfo = dofile("modinfo.lua")
local tmpl = std.fs.read_file("c_tmpl")

if app_config.custom_main then
	tmpl = tmpl .. app_config.custom_main
else
	tmpl = tmpl .. regular_main
end

local ver = std.fs.read_file("apps/version") or "unknown"
ver = ver:gsub("\n", "")

local tmpl_vars = {
	VERSION = ver,
	APP_NAME = app_config.binary,
	START_CODE = app_config.start_code,
	LUAMODS = "",
	CLIBS = "",
}

local pwd = std.fs.cwd()
pwd = pwd:gsub("/buildgen$", "")

local ar_args = ""

for _, lib in ipairs(app_config.c_libs) do
	std.fs.chdir(pwd .. "/src/" .. lib)
	show_output(std.ps.exec_simple("make"), "Building module: " .. lib .. "...")
	show_output(
		std.ps.exec_simple("sh -c 'strip --strip-debug --strip-unneeded *.o'"),
		"Stripping object files: " .. lib .. "..."
	)

	local obj_files = std.fs.list_files(".", "%.o$")
	for obj, _ in pairs(obj_files) do
		ar_args = ar_args .. " " .. pwd .. "/src/" .. lib .. "/" .. obj
	end
	std.fs.chdir(pwd)
end

std.fs.mkdir("build")

for _, luamod in ipairs(app_config.luamods) do
	std.fs.chdir(pwd .. "/build")
	std.fs.mkdir(luamod)
	std.fs.chdir(luamod)

	-- Recursively find all .lua files
	local lua_files = list_lua_files_recursive(pwd .. "/src/" .. luamod, pwd .. "/src/" .. luamod)

	for lua_file_rel_path, _ in pairs(lua_files) do
		-- lua_file_rel_path is like "shell.lua" or "shell/theme.lua"
		mod_to_header(pwd .. "/src/" .. luamod .. "/" .. lua_file_rel_path, lua_file_rel_path)
	end
	for __, entry in ipairs(modinfo.luamods[luamod]) do
		local mod_file_name
		if type(entry) == "table" then
			mod_file_name = entry[2] .. ".h"
		else
			mod_file_name = "mod_lua_" .. entry .. ".h"
		end
		tmpl_vars.LUAMODS = tmpl_vars.LUAMODS
			.. '#include "'
			.. pwd
			.. "/build/"
			.. luamod
			.. "/"
			.. mod_file_name
			.. '"\n'
	end
end

tmpl_vars.LUAMODS = tmpl_vars.LUAMODS .. "\n\nconst mod_lua__t lua_preload[] = {\n"
for _, luamod in ipairs(app_config.luamods) do
	for __, entry in ipairs(modinfo.luamods[luamod]) do
		local mod_name, mod_file_name
		if type(entry) == "table" then
			mod_name = entry[1]
			mod_file_name = entry[2]
		else
			mod_name = entry
			mod_file_name = "mod_lua_" .. entry
		end

		tmpl_vars.LUAMODS = tmpl_vars.LUAMODS
			.. '{"'
			.. mod_name
			.. '", '
			.. mod_file_name:gsub("%.", "_")
			.. ", &"
			.. mod_file_name:gsub("%.", "_")
			.. "_SIZE },\n"
	end
end
tmpl_vars.LUAMODS = tmpl_vars.LUAMODS .. "{NULL, NULL, NULL } };\n"

for _, lib in ipairs(app_config.c_libs) do
	for __, entry in ipairs(modinfo.c_libs[lib]) do
		tmpl_vars.CLIBS = tmpl_vars.CLIBS .. "extern int " .. entry[2] .. "(lua_State *L);\n"
	end
end

tmpl_vars.CLIBS = tmpl_vars.CLIBS .. "const luaL_Reg c_preload[] = {\n"

for _, lib in ipairs(app_config.c_libs) do
	for __, entry in ipairs(modinfo.c_libs[lib]) do
		tmpl_vars.CLIBS = tmpl_vars.CLIBS .. '{"' .. entry[1] .. '", ' .. entry[2] .. "},\n"
	end
end
tmpl_vars.CLIBS = tmpl_vars.CLIBS .. "{NULL, NULL }\n};\n"

tmpl = tmpl:gsub("{{([%w_]+)}}", tmpl_vars)
std.fs.write_file(pwd .. "/src/" .. app_config.binary .. ".c", tmpl)

std.fs.chdir(pwd .. "/src")
local ar_cmd = "ar rcs liblilush.a" .. ar_args
show_output(std.ps.exec_simple(ar_cmd), "Building static lib: " .. ar_cmd)

std.fs.mkdir("/build")

local clang_cmd = "clang -Os -s -O3 -Wall -Wl,-E -o "
	.. "/build/"
	.. app_config.binary
	.. " "
	.. pwd
	.. "/src/"
	.. app_config.binary
	.. ".c -I/usr/local/include/luajit-2.1 -I/usr/local/include/wolfssl -L/usr/local/lib -lluajit-5.1 -Wl,--whole-archive -lwolfssl liblilush.a -Wl,--no-whole-archive -static"

show_output(std.ps.exec_simple(clang_cmd), "Building the app...")

std.ps.exec_simple("cp /build/" .. app_config.binary .. " " .. app_config.install_path)
