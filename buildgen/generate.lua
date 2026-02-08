#!/usr/local/bin/luajit

package.path =
	"./?.lua;/usr/share/luajit-2.1/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua"

local function read_file(path)
	local f, err = io.open(path, "r")
	if not f then
		return nil, err
	end
	local content = f:read("*a")
	f:close()
	return content
end

local function write_file(path, content)
	local f, err = io.open(path, "w")
	if not f then
		return nil, err
	end
	f:write(content)
	f:close()
	return true
end

local function file_exists(path)
	local f = io.open(path, "r")
	if f then
		f:close()
		return true
	end
	return false
end

local function run(cmd, msg)
	print("==========================================")
	print(msg)
	print("==========================================")
	local ok, _, status = os.execute(cmd)
	if not ok then
		print("FAILED with status: " .. tostring(status))
		os.exit(-1)
	end
end

local function mkdir(path)
	os.execute("mkdir -p " .. path)
end

local function find_lua_files(dir)
	local results = {}
	local p = io.popen('find "' .. dir .. '" -name "*.lua" -type f')
	for line in p:lines() do
		results[line:sub(#dir + 2)] = true
	end
	p:close()
	return results
end

local function lua_file_to_c_const(name, filepath)
	local content = read_file(filepath)
	if not content then
		print("Can't read Lua entrypoint file: " .. filepath)
		os.exit(-1)
	end
	content = content:gsub("\\", "\\\\")
	content = content:gsub('"', '\\"')
	content = content:gsub("\n", "\\n")
	return "static const char " .. name .. '[] = "' .. content .. '";\n'
end

local function get_root()
	local p = io.popen("pwd")
	local cwd = p:read("*l")
	p:close()
	return cwd:gsub("/buildgen$", "")
end

local root = get_root()
local entrypoints_dir = root .. "/buildgen/entrypoints"

local app_config_file = arg[1] or ""
if not file_exists(app_config_file) then
	print("Can't read app config file")
	os.exit(-1)
end

local app_config = dofile(app_config_file)

local modinfo = dofile("modinfo.lua")
local tmpl = read_file("c_tmpl")

local ver = read_file("apps/version") or "unknown"
ver = ver:gsub("\n", "")

-- Build start_code C constants from Lua files
local start_code_c = ""
for const_name, lua_path in pairs(app_config.start_code) do
	start_code_c = start_code_c .. lua_file_to_c_const(const_name, entrypoints_dir .. "/" .. lua_path)
end

local tmpl_vars = {
	VERSION = ver,
	APP_NAME = app_config.binary,
	START_CODE = start_code_c,
	LUAMODS = "",
	CLIBS = "",
}

local ar_args = ""

for _, lib in ipairs(app_config.c_libs) do
	local lib_dir = root .. "/src/" .. lib
	run("make -C " .. lib_dir, "Building module: " .. lib .. "...")
	run(
		"sh -c 'strip --strip-debug --strip-unneeded " .. lib_dir .. "/*.o'",
		"Stripping object files: " .. lib .. "..."
	)

	local p = io.popen('find "' .. lib_dir .. '" -maxdepth 1 -name "*.o" -type f')
	for line in p:lines() do
		ar_args = ar_args .. " " .. line
	end
	p:close()
end

mkdir(root .. "/build")

local mod_to_header = function(filepath, rel_path, out_dir)
	local mod_base = rel_path:gsub("%.lua$", ""):gsub("/", ".")
	local mod_name = "mod_lua_" .. mod_base .. ".h"
	local c_ident = mod_base:gsub("%.", "_")
	local out_path = out_dir .. "/" .. mod_name

	os.execute("luajit -b -n " .. c_ident .. " " .. filepath .. " " .. out_path)
	local content = read_file(out_path)
	content = content:gsub("#define luaJIT_BC_" .. c_ident, "const size_t mod_lua_" .. c_ident)
	content = content:gsub("_SIZE (%d+)", "_SIZE=%1;")
	content = content:gsub("static const unsigned char luaJIT_BC_" .. c_ident, "static const char mod_lua_" .. c_ident)
	write_file(out_path, content)
end

for _, luamod in ipairs(app_config.luamods) do
	local build_dir = root .. "/build/" .. luamod
	mkdir(build_dir)

	local lua_files = find_lua_files(root .. "/src/" .. luamod)

	for lua_file_rel_path, _ in pairs(lua_files) do
		mod_to_header(root .. "/src/" .. luamod .. "/" .. lua_file_rel_path, lua_file_rel_path, build_dir)
	end
	for _, entry in ipairs(modinfo.luamods[luamod]) do
		local mod_file_name
		if type(entry) == "table" then
			mod_file_name = entry[2] .. ".h"
		else
			mod_file_name = "mod_lua_" .. entry .. ".h"
		end
		tmpl_vars.LUAMODS = tmpl_vars.LUAMODS .. '#include "' .. build_dir .. "/" .. mod_file_name .. '"\n'
	end
end

tmpl_vars.LUAMODS = tmpl_vars.LUAMODS .. "\n\nconst mod_lua__t lua_preload[] = {\n"
for _, luamod in ipairs(app_config.luamods) do
	for _, entry in ipairs(modinfo.luamods[luamod]) do
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
	for _, entry in ipairs(modinfo.c_libs[lib]) do
		tmpl_vars.CLIBS = tmpl_vars.CLIBS .. "extern int " .. entry[2] .. "(lua_State *L);\n"
	end
end

tmpl_vars.CLIBS = tmpl_vars.CLIBS .. "const luaL_Reg c_preload[] = {\n"

for _, lib in ipairs(app_config.c_libs) do
	for _, entry in ipairs(modinfo.c_libs[lib]) do
		tmpl_vars.CLIBS = tmpl_vars.CLIBS .. '{"' .. entry[1] .. '", ' .. entry[2] .. "},\n"
	end
end
tmpl_vars.CLIBS = tmpl_vars.CLIBS .. "{NULL, NULL }\n};\n"

-- Append custom_main or default_main
if app_config.custom_main then
	tmpl = tmpl .. read_file(entrypoints_dir .. "/" .. app_config.custom_main)
else
	tmpl = tmpl .. read_file(root .. "/buildgen/default_main.c")
end

tmpl = tmpl:gsub("{{([%w_]+)}}", tmpl_vars)
write_file(root .. "/src/" .. app_config.binary .. ".c", tmpl)

local ar_cmd = "ar rcs " .. root .. "/src/liblilush.a" .. ar_args
run(ar_cmd, "Building static lib...")

mkdir("/build")

local clang_cmd = "clang -Os -s -O3 -Wall -Wl,-E -o "
	.. "/build/"
	.. app_config.binary
	.. " "
	.. root
	.. "/src/"
	.. app_config.binary
	.. ".c -I/usr/local/include/luajit-2.1 -I/usr/local/include/wolfssl -L/usr/local/lib -lluajit-5.1 -Wl,--whole-archive -lwolfssl "
	.. root
	.. "/src/liblilush.a -Wl,--no-whole-archive -static"

run(clang_cmd, "Building the app...")
