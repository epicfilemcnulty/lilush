-- SPDX-FileCopyrightText: © 2023 Vladimir Zorin <vladimir@deviant.guru>
-- SPDX-License-Identifier: GPL-3.0-or-later
local core = require("std.core")

local function symlink(src, dst)
	return core.symlink(src, dst)
end

local function cwd()
	return core.cwd()
end

local function stat(path)
	return core.stat(path)
end

local function readlink(pathname)
	return core.readlink(pathname)
end

local split_path_by_dir = function(pathname)
	local dirs = {}
	local path, last_dir = pathname:match("^(.-)/?([^/]-)$")
	repeat
		table.insert(dirs, last_dir)
		path, last_dir = path:match("^(.-)/?([^/]-)$")
	until path == ""
	table.insert(dirs, last_dir)
	local reversed = {}
	for i = #dirs, 1, -1 do
		table.insert(reversed, dirs[i])
	end
	return reversed
end

local function mkdir(pathname, mode, recursive)
	if recursive then
		local dirs = split_path_by_dir(pathname)
		local prefix = ""
		if pathname:match("^/") then
			prefix = "/"
		end
		for i, _ in ipairs(dirs) do
			local dir = prefix .. table.concat(dirs, "/", 1, i)
			local st = stat(dir)
			if not st then
				local s, err = core.mkdir(dir, mode)
				if not s then
					return nil, err
				end
			end
		end
		return true
	end
	return core.mkdir(pathname, mode)
end

local function list_dir(path)
	return core.list_dir(path)
end

local function fast_list_dir(path)
	return core.fast_list_dir(path)
end

local function symlink(src, dst)
	return core.symlink(src, dst)
end

local function empty_dir(path)
	local st = core.stat(path)
	if st and st.mode == "d" then
		local items = list_dir(path)
		if not items then
			return nil, "failed to get dir items"
		end
		if #items == 2 then
			return true
		end
		return false
	end
	return nil, "not a dir"
end

local function non_empty_dir(path)
	local r, err = empty_dir(path)
	if err then
		return nil, err
	end
	return not r
end

local function remove(path, recursive)
	if recursive then
		local st = core.stat(path)
		if st and st.mode == "d" then
			local items, err = list_dir(path)
			if not items then
				return nil, err
			end
			for _, f in ipairs(items) do
				if f ~= "." and f ~= ".." then
					local s, err = remove(path .. "/" .. f, true)
					if not s then
						return nil, err
					end
				end
			end
			return core.remove(path)
		end
	end
	return core.remove(path)
end

local function list_files(dir, pattern, mode, resolve_links)
	local resolve_links = resolve_links or false
	local files = {}
	local mode = mode or "f"
	local items, err = list_dir(dir)
	if items then
		local pattern = pattern or "^.*"
		for _, f in ipairs(items) do
			if f ~= "." and f ~= ".." then
				if f:match(pattern) then
					local st = core.stat(dir .. "/" .. f)
					if st and st.mode:match(mode) then
						local target
						if st.mode == "l" and resolve_links then
							target = readlink(dir .. "/" .. f)
						end
						files[f] = {
							mode = st.mode,
							size = st.size,
							perms = st.perms,
							uid = st.uid,
							gid = st.gid,
							target = target,
							atime = st.atime,
						}
					end
				end
			end
		end
		return files
	end
	return nil, err
end

local function dir_exists(filename)
	local st = core.stat(filename)
	if st and st.mode == "d" then
		return true
	end
	return false
end

local function file_exists(filename, mode)
	local mode = mode or "f"
	local st = core.stat(filename)
	if st and st.mode:match(mode) then
		return true
	end
	return false
end

local function read_file(filename)
	local f, err = io.open(filename, "r")
	if f then
		local lines = f:read("*a")
		f:close()
		return lines
	end
	return nil, err
end

local function write_file(filename, text)
	local f, err = io.open(filename, "w+")
	if f then
		f:write(text)
		f:close()
		return true
	end
	return nil, err
end

local fs = {
	cwd = cwd,
	stat = stat,
	read_file = read_file,
	write_file = write_file,
	dir_exists = dir_exists,
	empty_dir = empty_dir,
	mkdir = mkdir,
	chdir = core.chdir,
	non_empty_dir = non_empty_dir,
	symlink = symlink,
	remove = remove,
	file_exists = file_exists,
	list_files = list_files,
	list_dir = list_dir,
	fast_list_dir = fast_list_dir,
	split_path_by_dir = split_path_by_dir,
}
return fs
